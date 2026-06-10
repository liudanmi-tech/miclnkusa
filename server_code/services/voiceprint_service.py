"""
声纹服务：双语言 speaker embedding 计算与比对 + VAD 静音剥离。

模型：
  英文/通用：ECAPA-TDNN（speechbrain/spkrec-ecapa-voxceleb，192维）
  中文专用：CAM++（wespeaker 中文模型，192维）
安装：pip install speechbrain silero-vad
      pip install git+https://github.com/wenet-e2e/wespeaker.git  # CAM++

公开 API：
  detect_language(text)                 → "zh" | "en" | "unknown"
  strip_silence_vad(pcm_bytes)          → (voiced_pcm, speech_ratio)
  compute_embedding_from_bytes(pcm_bytes)          → Optional[List[float]]  # ECAPA
  compute_embedding_zh(pcm_bytes)                  → Optional[List[float]]  # CAM++
  compute_enrollment_embedding(pcm_bytes)          → Optional[List[float]]  # ECAPA 多窗口
  compute_enrollment_embedding_zh(pcm_bytes)       → Optional[List[float]]  # CAM++ 多窗口
  compute_embedding_from_url(audio_url)            → Optional[List[float]]
  cosine_similarity(a, b)                          → float

降级：speechbrain / silero-vad / wespeaker 未安装时返回 None / 原始 PCM，不抛异常。
"""
import logging
import os
import subprocess
import tempfile
from typing import List, Optional, Tuple

import numpy as np

logger = logging.getLogger(__name__)

SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 2          # 16-bit
BYTES_PER_SEC = SAMPLE_RATE * BYTES_PER_SAMPLE   # 32000

MODEL_HF_ID = "speechbrain/spkrec-ecapa-voxceleb"
# 模型缓存目录（服务器上固定路径，避免重复下载）
MODEL_SAVE_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "pretrained_models", "ecapa-tdnn"
)

# ──────────────────────────────────────────────────────────────────────────────
# VAD (silero-vad) 懒加载
# ──────────────────────────────────────────────────────────────────────────────

_vad_model = None
_vad_available: Optional[bool] = None

# VAD 配置
VAD_THRESHOLD        = 0.50   # silero 语音判断置信阈值（0-1）
VAD_MIN_SPEECH_MS    = 250    # 最短语音片段：250ms
VAD_MIN_SILENCE_MS   = 100    # 最短静音间隔：100ms（短停顿不切断）
VAD_WINDOW_SIZE_MS   = 32     # silero 分析窗口：32ms（512 samples @16kHz）
VAD_MIN_SPEECH_RATIO = 0.20   # 语音占比低于 20% 视为"全静音"，退回原始 PCM


def _get_vad_model():
    """懒加载 silero-vad 模型（第一次调用时下载 ~1.5MB）"""
    global _vad_model, _vad_available
    if _vad_available is False:
        return None
    if _vad_model is not None:
        return _vad_model
    try:
        from silero_vad import load_silero_vad
        _vad_model = load_silero_vad()
        _vad_available = True
        logger.info("[VAD] silero-vad 加载成功")
    except Exception as e:
        _vad_available = False
        logger.warning(f"[VAD] silero-vad 加载失败: {e}，VAD 功能已禁用（使用原始 PCM）")
    return _vad_model


def strip_silence_vad(
    pcm_bytes: bytes,
    sample_rate: int = SAMPLE_RATE,
) -> Tuple[bytes, float]:
    """
    用 silero-vad 剥离非语音帧，只保留有声片段（帧间静音被移除）。

    Args:
        pcm_bytes:   16kHz 16-bit mono PCM bytes
        sample_rate: 采样率（默认 16000）

    Returns:
        voiced_pcm:   只含语音帧的 PCM bytes
        speech_ratio: 语音帧占总帧数的比例 (0.0–1.0)
                      若比例 < VAD_MIN_SPEECH_RATIO，返回原始 PCM 并标记 ratio

    Fallback（silero 未安装 / 出错 / 音频过短）:
        返回 (原始 pcm_bytes, 1.0)

    日志:
        [VAD] raw=Xs voiced=Ys ratio=ZZ%  ← 正常
        [VAD] ⚠ ratio=X% < 20%，退回原始 PCM  ← 静音过多
        [VAD] ⚠ silero 未安装，跳过          ← 降级
    """
    model = _get_vad_model()
    if model is None:
        logger.debug("[VAD] silero 未安装，跳过 VAD")
        return pcm_bytes, 1.0

    raw_secs = len(pcm_bytes) / BYTES_PER_SEC
    if raw_secs < 0.3:
        logger.debug(f"[VAD] 音频过短 ({raw_secs:.2f}s)，跳过 VAD")
        return pcm_bytes, 1.0

    try:
        import torch
        from silero_vad import get_speech_timestamps

        # 16-bit PCM 每 sample 2 bytes，长度必须是偶数
        if len(pcm_bytes) % 2 != 0:
            pcm_bytes = pcm_bytes[:-1]

        # PCM bytes → float32 tensor (1D, range [-1, 1])
        wav_np = np.frombuffer(pcm_bytes, dtype=np.int16).astype(np.float32) / 32768.0
        wav_tensor = torch.from_numpy(wav_np)

        # 获取语音时间戳（返回 sample 级别的 start/end 列表）
        speech_timestamps = get_speech_timestamps(
            wav_tensor,
            model,
            threshold=VAD_THRESHOLD,
            sampling_rate=sample_rate,
            min_speech_duration_ms=VAD_MIN_SPEECH_MS,
            min_silence_duration_ms=VAD_MIN_SILENCE_MS,
            window_size_samples=int(sample_rate * VAD_WINDOW_SIZE_MS / 1000),
            return_seconds=False,
        )

        if not speech_timestamps:
            logger.warning(
                f"[VAD] 未检测到语音 raw={raw_secs:.2f}s，退回原始 PCM"
            )
            return pcm_bytes, 0.0

        # 拼接所有语音片段（移除帧间静音）
        voiced_chunks = []
        total_voiced_samples = 0
        for seg in speech_timestamps:
            s, e = seg["start"], seg["end"]
            # 转回 bytes（每 sample 2 bytes）
            voiced_chunks.append(pcm_bytes[s * 2: e * 2])
            total_voiced_samples += (e - s)

        voiced_pcm = b"".join(voiced_chunks)
        total_samples = len(pcm_bytes) // 2
        speech_ratio = total_voiced_samples / max(total_samples, 1)
        voiced_secs = total_voiced_samples / sample_rate

        logger.info(
            f"[VAD] raw={raw_secs:.2f}s voiced={voiced_secs:.2f}s "
            f"ratio={speech_ratio*100:.0f}% segments={len(speech_timestamps)}"
        )

        # 语音比例过低：退回原始（避免极短 voiced_pcm 让 embedding 不稳）
        if speech_ratio < VAD_MIN_SPEECH_RATIO:
            logger.warning(
                f"[VAD] ⚠ ratio={speech_ratio*100:.0f}% < "
                f"{VAD_MIN_SPEECH_RATIO*100:.0f}%，退回原始 PCM"
            )
            return pcm_bytes, speech_ratio

        return voiced_pcm, speech_ratio

    except Exception as e:
        logger.warning(f"[VAD] 处理异常: {e}，退回原始 PCM")
        return pcm_bytes, 1.0


# ──────────────────────────────────────────────────────────────────────────────
# 语言检测（基于 transcript 文本，无需额外库）
# ──────────────────────────────────────────────────────────────────────────────

def detect_language(text: str) -> str:
    """
    基于 turn transcript 文本快速判断语言。

    规则：
      - CJK 字符（\\u4e00-\\u9fff）占比 ≥ 0.40 → "zh"
      - ASCII 字母占比 ≥ 0.60 → "en"
      - 其他 → "unknown"（fallback 到 ECAPA-TDNN）

    Returns:
        "zh" | "en" | "unknown"
    """
    if not text or not text.strip():
        return "unknown"
    cjk_count   = sum(1 for c in text if '\u4e00' <= c <= '\u9fff')
    ascii_alpha  = sum(1 for c in text if c.isascii() and c.isalpha())
    total        = len(text)
    cjk_ratio    = cjk_count / total
    ascii_ratio  = ascii_alpha / total
    if cjk_ratio >= 0.40:
        return "zh"
    if ascii_ratio >= 0.60:
        return "en"
    return "unknown"


# ──────────────────────────────────────────────────────────────────────────────
# CAM++（wespeaker 中文模型）懒加载
# ──────────────────────────────────────────────────────────────────────────────
_encoder_zh = None
_encoder_zh_available: Optional[bool] = None


def _get_encoder_zh():
    """
    懒加载 wespeaker CAM++ 中文模型。
    未安装 wespeaker 时 fallback 到 ECAPA-TDNN，不抛异常。
    安装方式：pip install git+https://github.com/wenet-e2e/wespeaker.git
    """
    global _encoder_zh, _encoder_zh_available
    if _encoder_zh_available is False:
        return None
    if _encoder_zh is not None:
        return _encoder_zh
    try:
        # torchaudio 2.0+ 移除了 set_audio_backend，wespeaker 代码里还用到，打补丁兼容
        import torchaudio as _ta
        if not hasattr(_ta, 'set_audio_backend'):
            _ta.set_audio_backend = lambda x: None
        import wespeaker
        _encoder_zh = wespeaker.load_model('chinese')
        _encoder_zh_available = True
        logger.info("[voiceprint] ✅ wespeaker CAM++ 中文模型加载成功")
    except ImportError:
        _encoder_zh_available = False
        logger.warning("[voiceprint] wespeaker 未安装，中文声纹将 fallback 到 ECAPA-TDNN")
    except Exception as e:
        _encoder_zh_available = False
        logger.warning(f"[voiceprint] wespeaker 中文模型加载失败: {e}，fallback 到 ECAPA-TDNN")
    return _encoder_zh


# ──────────────────────────────────────────────────────────────────────────────
# ECAPA-TDNN 懒加载
# ──────────────────────────────────────────────────────────────────────────────
_encoder = None
_encoder_available = None


def _get_encoder():
    global _encoder, _encoder_available
    if _encoder_available is False:
        return None
    if _encoder is not None:
        return _encoder
    try:
        from speechbrain.inference.speaker import EncoderClassifier

        logger.info(f"[voiceprint] 正在加载 ECAPA-TDNN model={MODEL_HF_ID} savedir={MODEL_SAVE_DIR}")
        os.makedirs(MODEL_SAVE_DIR, exist_ok=True)
        # speechbrain 1.x 用 from_hparams（支持 HuggingFace source）
        _encoder = EncoderClassifier.from_hparams(
            source=MODEL_HF_ID,
            savedir=MODEL_SAVE_DIR,
            run_opts={"device": "cpu"},
        )
        _encoder_available = True
        logger.info("[voiceprint] ✅ ECAPA-TDNN 加载成功")
    except ImportError:
        _encoder_available = False
        logger.warning(
            "[voiceprint] speechbrain 未安装，声纹功能已禁用。"
            "安装: pip install speechbrain"
        )
    except Exception as e:
        _encoder_available = False
        logger.warning(f"[voiceprint] ECAPA-TDNN 加载失败: {e}，声纹功能已禁用")
    return _encoder


# ──────────────────────────────────────────────────────────────────────────────
# 工具：PCM bytes → float32 numpy
# ──────────────────────────────────────────────────────────────────────────────

def _pcm_to_float32(pcm_bytes: bytes) -> np.ndarray:
    """16kHz 16-bit mono PCM bytes → float32 numpy array（范围 [-1, 1]）"""
    if len(pcm_bytes) % 2 != 0:
        pcm_bytes = pcm_bytes[:-1]
    arr = np.frombuffer(pcm_bytes, dtype=np.int16)
    return arr.astype(np.float32) / 32768.0


# ──────────────────────────────────────────────────────────────────────────────
# 工具：下载音频 URL → PCM bytes（档案注册用）
# ──────────────────────────────────────────────────────────────────────────────

def _download_audio_url(audio_url: str, tmp_path: str) -> bool:
    """
    下载音频到 tmp_path。
    优先 urllib（公开 URL），失败用 boto3 + R2 credentials fallback。
    """
    import urllib.request
    try:
        urllib.request.urlretrieve(audio_url, tmp_path)
        return True
    except Exception as e:
        logger.debug(f"[voiceprint] urllib 下载失败({e})，尝试 R2 boto3 fallback")

    try:
        r2_public  = os.getenv("R2_PUBLIC_URL", "").rstrip("/")
        r2_endpoint = os.getenv("R2_ENDPOINT_URL", "")
        r2_bucket  = os.getenv("R2_BUCKET_NAME", "")
        r2_key_id  = os.getenv("R2_ACCESS_KEY_ID", "")
        r2_secret  = os.getenv("R2_SECRET_ACCESS_KEY", "")

        if not all([r2_public, r2_endpoint, r2_bucket, r2_key_id, r2_secret]):
            logger.warning("[voiceprint] R2 环境变量不完整，无法 fallback")
            return False
        if not audio_url.startswith(r2_public):
            logger.warning(f"[voiceprint] URL 不属于已知 R2 域名: {audio_url[:80]}")
            return False

        r2_key = audio_url[len(r2_public):].lstrip("/")
        import boto3
        s3 = boto3.client(
            "s3",
            endpoint_url=r2_endpoint,
            aws_access_key_id=r2_key_id,
            aws_secret_access_key=r2_secret,
            region_name="auto",
        )
        s3.download_file(r2_bucket, r2_key, tmp_path)
        logger.info(f"[voiceprint] R2 boto3 fallback 成功 key={r2_key[:60]}")
        return True
    except Exception as e:
        logger.error(f"[voiceprint] R2 boto3 fallback 失败: {e}")
        return False


def _audio_url_to_pcm(audio_url: str) -> Optional[bytes]:
    """
    下载任意格式音频 URL，用 ffmpeg 转成 16kHz 16-bit mono PCM。
    返回 PCM bytes；失败返回 None。
    """
    suffix = ".m4a" if ".m4a" in audio_url else ".mp3" if ".mp3" in audio_url else ".wav"
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp_path = tmp.name
    except Exception as e:
        logger.error(f"[voiceprint] 创建临时文件失败: {e}")
        return None

    if not _download_audio_url(audio_url, tmp_path):
        try:
            os.unlink(tmp_path)
        except Exception:
            pass
        logger.error(f"[voiceprint] 下载失败 url={audio_url[:80]}")
        return None

    try:
        result = subprocess.run(
            ["ffmpeg", "-y", "-i", tmp_path,
             "-ar", "16000", "-ac", "1", "-f", "s16le", "pipe:1"],
            capture_output=True, timeout=60, check=False,
        )
        if result.returncode != 0:
            err = (result.stderr or b"").decode("utf-8", errors="replace")
            logger.error(f"[voiceprint] ffmpeg 失败: {err[:200]}")
            return None
        return result.stdout
    except Exception as e:
        logger.error(f"[voiceprint] ffmpeg 异常: {e}")
        return None
    finally:
        try:
            os.unlink(tmp_path)
        except Exception:
            pass


# ──────────────────────────────────────────────────────────────────────────────
# 公开 API
# ──────────────────────────────────────────────────────────────────────────────

def compute_embedding_from_bytes(pcm_bytes: bytes) -> Optional[List[float]]:
    """
    从 16kHz 16-bit mono PCM bytes 计算 192维 ECAPA-TDNN speaker embedding。
    返回 List[float]（长度 192）；失败或 speechbrain 未安装返回 None。

    推荐最短时长：0.5s（16000 bytes），建议 1s 以上效果更稳定。
    """
    encoder = _get_encoder()
    if encoder is None:
        logger.warning("[voiceprint][DIAG-VP-6] ❌ ECAPA-TDNN encoder 不可用")
        return None

    pcm_secs = len(pcm_bytes) / BYTES_PER_SEC
    if pcm_secs < 0.5:
        logger.warning(f"[voiceprint][DIAG-VP-6] ❌ PCM 太短 ({pcm_secs:.2f}s < 0.5s)")
        return None

    logger.info(
        f"[voiceprint][DIAG-VP-6] ECAPA-TDNN 开始计算 "
        f"pcm={len(pcm_bytes)}bytes ({pcm_secs:.2f}s)"
    )

    try:
        import torch
        wav_np = _pcm_to_float32(pcm_bytes)
        # ECAPA-TDNN 期望 (batch, time) 的 float32 tensor，16kHz 归一化音频
        wav_tensor = torch.FloatTensor(wav_np).unsqueeze(0)   # (1, T)
        with torch.no_grad():
            emb = encoder.encode_batch(wav_tensor)             # (1, 1, 192)
        emb_np = emb.squeeze().cpu().numpy()                   # (192,)

        # L2 归一化（保险起见，SpeechBrain 输出通常已归一化）
        norm = np.linalg.norm(emb_np)
        if norm > 0:
            emb_np = emb_np / norm

        nonzero = int(np.count_nonzero(emb_np))
        logger.info(
            f"[voiceprint][DIAG-VP-6] ✅ ECAPA-TDNN 完成 "
            f"dim={len(emb_np)} nonzero={nonzero} mean={float(np.mean(np.abs(emb_np))):.4f}"
        )
        return emb_np.tolist()

    except Exception as e:
        logger.warning(f"[voiceprint][DIAG-VP-6] ❌ ECAPA-TDNN 计算异常: {e}")
        return None


def compute_embedding_from_url(audio_url: str) -> Optional[List[float]]:
    """
    下载档案音频 URL，计算 ECAPA-TDNN embedding。
    用于声纹注册（一次性，结果存 DB）。
    """
    if _get_encoder() is None:
        return None
    pcm_bytes = _audio_url_to_pcm(audio_url)
    if not pcm_bytes:
        return None
    return compute_embedding_from_bytes(pcm_bytes)


def compute_enrollment_embedding(pcm_bytes: bytes) -> Optional[List[float]]:
    """
    声纹注册专用：VAD 静音剥离 → 多窗口平均 embedding。

    流程：
      1. VAD 剥离静音，只保留有声帧
      2. 按 3s 窗口 / 1.5s 步长切分
      3. 每窗口独立计算 ECAPA-TDNN embedding
      4. 算术平均 + L2 归一化

    降级：不足 3s / VAD 失败 → 退化为单次计算。
    """
    raw_secs = len(pcm_bytes) / BYTES_PER_SEC

    # ── Step 1: VAD 剥离静音 ──────────────────────────────────────────────────
    voiced_pcm, speech_ratio = strip_silence_vad(pcm_bytes)
    voiced_secs = len(voiced_pcm) / BYTES_PER_SEC
    logger.info(
        f"[enrollment] VAD 完成: raw={raw_secs:.1f}s → voiced={voiced_secs:.1f}s "
        f"ratio={speech_ratio*100:.0f}%"
    )

    # ── Step 2-4: 多窗口切分 + 平均 ──────────────────────────────────────────
    WINDOW_BYTES = int(3.0 * BYTES_PER_SEC)   # 3s 窗口
    HOP_BYTES    = int(1.5 * BYTES_PER_SEC)   # 1.5s 步长（50% 重叠）
    MIN_BYTES    = int(0.8 * BYTES_PER_SEC)   # 窗口有效最短 0.8s

    if len(voiced_pcm) < WINDOW_BYTES:
        logger.info(f"[enrollment] voiced 不足 3s，退化为单次计算")
        return compute_embedding_from_bytes(voiced_pcm)

    embeddings = []
    offset = 0
    while offset + MIN_BYTES <= len(voiced_pcm):
        chunk = voiced_pcm[offset: offset + WINDOW_BYTES]
        if len(chunk) >= MIN_BYTES:
            emb = compute_embedding_from_bytes(chunk)
            if emb is not None:
                embeddings.append(np.array(emb, dtype=np.float32))
        offset += HOP_BYTES

    if not embeddings:
        return compute_embedding_from_bytes(voiced_pcm)

    avg = np.mean(embeddings, axis=0)
    norm = np.linalg.norm(avg)
    if norm > 0:
        avg = avg / norm

    logger.info(
        f"[enrollment] 完成: raw={raw_secs:.1f}s voiced={voiced_secs:.1f}s "
        f"windows={len(embeddings)} dim={len(avg)}"
    )
    return avg.tolist()


def compute_embedding_zh(pcm_bytes: bytes) -> Optional[List[float]]:
    """
    用 wespeaker CAM++ 计算中文 speaker embedding（192维）。
    需要 WAV 临时文件；未安装 wespeaker 时 fallback 到 ECAPA-TDNN。

    注意：CAM++ 与 ECAPA-TDNN 的 embedding 空间不同，不可混用。
    """
    import os, wave, tempfile

    encoder = _get_encoder_zh()
    if encoder is None:
        logger.warning("[voiceprint] CAM++ 不可用，fallback 到 ECAPA-TDNN（中文准确度会偏低）")
        return compute_embedding_from_bytes(pcm_bytes)

    pcm_secs = len(pcm_bytes) / BYTES_PER_SEC
    if pcm_secs < 0.5:
        logger.warning(f"[voiceprint] CAM++ PCM 太短 ({pcm_secs:.2f}s)")
        return None

    if len(pcm_bytes) % 2 != 0:
        pcm_bytes = pcm_bytes[:-1]

    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
            tmp_path = f.name
        with wave.open(tmp_path, 'wb') as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(pcm_bytes)

        emb = encoder.extract_embedding(tmp_path)   # numpy (192,) or (1,192)
        if emb is None:
            return None
        emb_np = np.array(emb, dtype=np.float32).flatten()
        norm = np.linalg.norm(emb_np)
        if norm > 0:
            emb_np = emb_np / norm
        logger.info(
            f"[voiceprint] CAM++ 完成 dim={len(emb_np)} "
            f"nonzero={int(np.count_nonzero(emb_np))} dur={pcm_secs:.2f}s"
        )
        return emb_np.tolist()
    except Exception as e:
        logger.warning(f"[voiceprint] CAM++ 计算异常: {e}")
        return None
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except Exception:
                pass


def compute_enrollment_embedding_zh(pcm_bytes: bytes) -> Optional[List[float]]:
    """
    声纹注册专用（CAM++ 中文）：VAD 静音剥离 → 多窗口平均 embedding。
    与 compute_enrollment_embedding() 完全对称，但使用 compute_embedding_zh。
    """
    raw_secs = len(pcm_bytes) / BYTES_PER_SEC

    voiced_pcm, speech_ratio = strip_silence_vad(pcm_bytes)
    voiced_secs = len(voiced_pcm) / BYTES_PER_SEC
    logger.info(
        f"[enrollment-zh] VAD 完成: raw={raw_secs:.1f}s → voiced={voiced_secs:.1f}s "
        f"ratio={speech_ratio*100:.0f}%"
    )

    WINDOW_BYTES = int(3.0 * BYTES_PER_SEC)
    HOP_BYTES    = int(1.5 * BYTES_PER_SEC)
    MIN_BYTES    = int(0.8 * BYTES_PER_SEC)

    if len(voiced_pcm) < WINDOW_BYTES:
        logger.info("[enrollment-zh] voiced 不足 3s，退化为单次计算")
        return compute_embedding_zh(voiced_pcm)

    embeddings = []
    offset = 0
    while offset + MIN_BYTES <= len(voiced_pcm):
        chunk = voiced_pcm[offset: offset + WINDOW_BYTES]
        if len(chunk) >= MIN_BYTES:
            emb = compute_embedding_zh(chunk)
            if emb is not None:
                embeddings.append(np.array(emb, dtype=np.float32))
        offset += HOP_BYTES

    if not embeddings:
        return compute_embedding_zh(voiced_pcm)

    avg = np.mean(embeddings, axis=0)
    norm = np.linalg.norm(avg)
    if norm > 0:
        avg = avg / norm

    logger.info(
        f"[enrollment-zh] 完成: raw={raw_secs:.1f}s voiced={voiced_secs:.1f}s "
        f"windows={len(embeddings)} dim={len(avg)}"
    )
    return avg.tolist()


def cosine_similarity(emb_a: List[float], emb_b: List[float]) -> float:
    """两个 192维 embedding 的余弦相似度，范围 [-1, 1]"""
    a = np.array(emb_a, dtype=np.float32)
    b = np.array(emb_b, dtype=np.float32)
    norm_a = np.linalg.norm(a)
    norm_b = np.linalg.norm(b)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return float(np.dot(a, b) / (norm_a * norm_b))
