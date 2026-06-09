"""
声纹服务：Resemblyzer d-vector embedding 计算与比对。

职责：
  - compute_embedding_from_bytes(pcm_bytes) → List[float]  从原始 16kHz 16-bit mono PCM 计算 256维 d-vector
  - compute_embedding_from_url(audio_url) → List[float]    下载档案音频并计算 embedding
  - cosine_similarity(a, b) → float                        计算两个 embedding 的余弦相似度

降级：Resemblyzer 未安装时模块内所有函数返回 None/0.0，不抛异常，调用方 skip。
"""
import io
import logging
import os
import subprocess
import tempfile
from typing import List, Optional

import numpy as np

logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────────────────────────────────────
# Resemblyzer 懒加载（避免服务启动因未安装而失败）
# ──────────────────────────────────────────────────────────────────────────────
_encoder = None
_resemblyzer_available = None


def _get_encoder():
    global _encoder, _resemblyzer_available
    if _resemblyzer_available is False:
        return None
    if _encoder is not None:
        return _encoder
    try:
        from resemblyzer import VoiceEncoder
        _encoder = VoiceEncoder()
        _resemblyzer_available = True
        logger.info("[voiceprint] Resemblyzer VoiceEncoder 加载成功")
    except ImportError:
        _resemblyzer_available = False
        logger.warning("[voiceprint] resemblyzer 未安装，声纹功能已禁用。安装: pip install resemblyzer")
    except Exception as e:
        _resemblyzer_available = False
        logger.warning(f"[voiceprint] Resemblyzer 加载失败: {e}，声纹功能已禁用")
    return _encoder


# ──────────────────────────────────────────────────────────────────────────────
# 工具：PCM bytes → numpy float32 array
# ──────────────────────────────────────────────────────────────────────────────

def _pcm_to_numpy(pcm_bytes: bytes) -> np.ndarray:
    """16kHz 16-bit mono PCM bytes → float32 numpy array（范围 [-1, 1]）"""
    arr = np.frombuffer(pcm_bytes, dtype=np.int16)
    return arr.astype(np.float32) / 32768.0


def _audio_url_to_pcm(audio_url: str) -> Optional[bytes]:
    """
    下载档案音频（任意格式），用 ffmpeg 转成 16kHz 16-bit mono PCM。
    返回 PCM bytes；失败返回 None。
    """
    import urllib.request

    # 下载到临时文件
    suffix = ".m4a" if ".m4a" in audio_url else ".mp3" if ".mp3" in audio_url else ".wav"
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp_path = tmp.name
        urllib.request.urlretrieve(audio_url, tmp_path)
    except Exception as e:
        logger.error(f"[voiceprint] 下载音频失败 url={audio_url[:80]}: {e}")
        return None

    # ffmpeg 转 16kHz mono 16-bit PCM
    try:
        result = subprocess.run(
            [
                "ffmpeg", "-y", "-i", tmp_path,
                "-ar", "16000", "-ac", "1", "-f", "s16le", "pipe:1",
            ],
            capture_output=True, timeout=60, check=False,
        )
        if result.returncode != 0:
            err = (result.stderr or b"").decode("utf-8", errors="replace")
            logger.error(f"[voiceprint] ffmpeg 转换失败: {err[:200]}")
            return None
        return result.stdout
    except Exception as e:
        logger.error(f"[voiceprint] ffmpeg 转换异常: {e}")
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
    从 16kHz 16-bit mono PCM bytes 计算 256维 d-vector。
    pcm_bytes 需至少包含约 1s（32000 bytes）的有效语音。
    返回 List[float]（长度 256）；失败或 resemblyzer 未安装返回 None。
    """
    encoder = _get_encoder()
    if encoder is None:
        return None
    if len(pcm_bytes) < 16000:   # < 0.5s，太短
        logger.debug("[voiceprint] PCM 太短（< 0.5s），跳过 embedding 计算")
        return None
    try:
        wav = _pcm_to_numpy(pcm_bytes)
        embedding = encoder.embed_utterance(wav)
        return embedding.tolist()
    except Exception as e:
        logger.warning(f"[voiceprint] compute_embedding_from_bytes 失败: {e}")
        return None


def compute_embedding_from_url(audio_url: str) -> Optional[List[float]]:
    """
    下载档案音频 URL，计算 d-vector embedding。
    用于声纹注册（一次性，结果存 DB）。
    """
    encoder = _get_encoder()
    if encoder is None:
        return None
    pcm_bytes = _audio_url_to_pcm(audio_url)
    if not pcm_bytes:
        return None
    return compute_embedding_from_bytes(pcm_bytes)


def cosine_similarity(emb_a: List[float], emb_b: List[float]) -> float:
    """两个 256维 embedding 的余弦相似度，范围 [-1, 1]"""
    a = np.array(emb_a, dtype=np.float32)
    b = np.array(emb_b, dtype=np.float32)
    norm_a = np.linalg.norm(a)
    norm_b = np.linalg.norm(b)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return float(np.dot(a, b) / (norm_a * norm_b))
