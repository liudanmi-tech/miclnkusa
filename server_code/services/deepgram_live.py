"""
DeepgramSession — Deepgram Nova-3 实时转录代理

职责：
  - 管理与 Deepgram 的 WebSocket 连接
  - 持续转发 iOS PCM 音频帧到 Deepgram
  - 将 Deepgram 响应解析为 TranscribedTurn（含 Speaker_N 标签）放入队列
  - Keepalive 防止 10s 超时断连
"""
import asyncio
import json
import logging
import os
from typing import AsyncIterator, NamedTuple, Optional

import websockets

logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────────────────────────────────────
# 常量
# ──────────────────────────────────────────────────────────────────────────────
DEEPGRAM_API_KEY = os.getenv("DEEPGRAM_API_KEY", "")
DEEPGRAM_WS_URL = (
    "wss://api.deepgram.com/v1/listen"
    "?model=nova-3"
    "&diarize=true"
    "&punctuate=true"
    "&encoding=linear16"
    "&sample_rate=16000"
    "&channels=1"
    "&interim_results=true"
    "&endpointing=500"
    "&language=zh-CN"
)
KEEPALIVE_INTERVAL = 8  # 秒，Deepgram 10s 超时前发送


# ──────────────────────────────────────────────────────────────────────────────
# 数据结构（与 gemini_live.py 接口保持一致）
# ──────────────────────────────────────────────────────────────────────────────
class TranscribedTurn(NamedTuple):
    speaker_label: str   # "Speaker_1" / "Speaker_2"
    text: str
    turn_index: int      # session 内全局递增
    start_sec: float = 0.0   # 该 turn 第一个 word 的 stream 绝对时间戳（秒）
    end_sec: float = 0.0     # 该 turn 最后一个 word 的 stream 绝对时间戳（秒）


# ──────────────────────────────────────────────────────────────────────────────
# DeepgramSession
# ──────────────────────────────────────────────────────────────────────────────
class DeepgramSession:
    """
    单个录音 Session 对应一个 DeepgramSession 实例。
    接口与 GeminiProxySession 完全一致，live_audio.py 无需改逻辑。
    """

    def __init__(self, session_id: str):
        self.session_id = session_id
        self._ws = None
        self._recv_task: Optional[asyncio.Task] = None
        self._keepalive_task: Optional[asyncio.Task] = None
        self._closed = False
        self._global_turn_index = 0
        self._turn_queue: asyncio.Queue[Optional[TranscribedTurn]] = asyncio.Queue()

    # ── 连接管理 ──────────────────────────────────────────────────────────────

    async def connect(self) -> None:
        """建立到 Deepgram 的 WebSocket 连接，启动后台接收和 keepalive 任务"""
        self._closed = False
        self._ws = await websockets.connect(
            DEEPGRAM_WS_URL,
            additional_headers={"Authorization": f"Token {DEEPGRAM_API_KEY}"},
            ping_interval=None,   # 由 keepalive_loop 自行管理
        )
        self._recv_task = asyncio.create_task(
            self._receive_loop(), name=f"dgram_recv_{self.session_id[:8]}"
        )
        self._keepalive_task = asyncio.create_task(
            self._keepalive_loop(), name=f"dgram_ka_{self.session_id[:8]}"
        )
        logger.info(f"[Deepgram] 连接建立 session={self.session_id[:8]}")

    async def close(self) -> None:
        """关闭连接，通知 turn_queue 消费者"""
        self._closed = True
        if self._keepalive_task and not self._keepalive_task.done():
            self._keepalive_task.cancel()
        if self._recv_task and not self._recv_task.done():
            self._recv_task.cancel()
        if self._ws:
            try:
                await self._ws.send(json.dumps({"type": "CloseStream"}))
                await asyncio.sleep(0.1)
                await self._ws.close()
            except Exception:
                pass
        await self._turn_queue.put(None)
        logger.info(f"[Deepgram] 连接关闭 session={self.session_id[:8]}")

    # ── 发送音频 ──────────────────────────────────────────────────────────────

    async def send_audio(self, pcm_bytes: bytes) -> None:
        """发送 PCM 帧到 Deepgram（binary 格式）"""
        if self._closed or self._ws is None:
            return
        try:
            await self._ws.send(pcm_bytes)
            self._audio_frames_sent = getattr(self, "_audio_frames_sent", 0) + 1
            if self._audio_frames_sent % 200 == 0:   # 每 200 帧（约 2.5s）打一次
                logger.debug(
                    f"[Deepgram] 已发送音频帧 n={self._audio_frames_sent} "
                    f"session={self.session_id[:8]}"
                )
        except Exception as e:
            logger.warning(f"[Deepgram] send_audio 失败: {e}")

    # ── Keepalive ────────────────────────────────────────────────────────────

    async def _keepalive_loop(self) -> None:
        """每 8s 发送 KeepAlive，防止 Deepgram 超时断连。单次失败继续循环。"""
        try:
            while not self._closed:
                await asyncio.sleep(KEEPALIVE_INTERVAL)
                if self._closed:
                    break
                if self._ws and not self._closed:
                    try:
                        await self._ws.send(json.dumps({"type": "KeepAlive"}))
                    except Exception as e:
                        logger.warning(f"[Deepgram] keepalive send 失败（继续）: {e}")
                        # 不 break，继续循环，等 _receive_loop 处理断连
        except asyncio.CancelledError:
            pass

    # ── 接收转录 ──────────────────────────────────────────────────────────────

    async def _receive_loop(self) -> None:
        """后台任务：从 Deepgram 读取 JSON 响应，解析 Turn，放入 _turn_queue。
        连接断开后自动重连（最多 3 次，指数退避）。
        """
        retry = 0
        while not self._closed:
            try:
                async for message in self._ws:
                    if self._closed:
                        break
                    try:
                        data = json.loads(message)
                    except json.JSONDecodeError:
                        continue
                    turns = self._parse_message(data)
                    for turn in turns:
                        await self._turn_queue.put(turn)
                # 正常结束（CloseStream 被服务端确认）
                break
            except asyncio.CancelledError:
                break
            except Exception as e:
                if self._closed:
                    break
                logger.warning(f"[Deepgram] 连接断开 retry={retry}: {e}")
                if retry >= 3:
                    logger.error("[Deepgram] 重连超过最大次数，放弃")
                    break
                wait = 2 ** retry
                await asyncio.sleep(wait)
                retry += 1
                try:
                    self._ws = await websockets.connect(
                        DEEPGRAM_WS_URL,
                        additional_headers={"Authorization": f"Token {DEEPGRAM_API_KEY}"},
                        ping_interval=None,
                    )
                    logger.info(f"[Deepgram] 重连成功 retry={retry} session={self.session_id[:8]}")
                    retry = 0  # 重连成功后重置计数
                except Exception as ce:
                    logger.error(f"[Deepgram] 重连失败 retry={retry}: {ce}")
                    continue

        if not self._closed:
            await self._turn_queue.put(None)

    def _parse_message(self, data: dict) -> list:
        """
        解析 Deepgram 流式响应。

        只处理 is_final=True 的 Results。
        按 speaker 整数分组 words → 生成 TranscribedTurn 列表。
        speaker=0 → Speaker_1，speaker=1 → Speaker_2，以此类推。
        """
        msg_type = data.get("type")

        # 记录所有非 Results 类型消息（Metadata/SpeechStarted/UtteranceEnd 等）
        if msg_type != "Results":
            if msg_type not in ("Metadata",):   # Metadata 太频繁，过滤掉
                logger.debug(f"[Deepgram] msg type={msg_type}")
            return []

        is_final = data.get("is_final", False)
        speech_final = data.get("speech_final", False)
        alternatives = data.get("channel", {}).get("alternatives", [])
        transcript = alternatives[0].get("transcript", "") if alternatives else ""

        # 记录所有 is_final 消息，方便排查漏句
        if is_final:
            logger.info(
                f"[Deepgram] is_final={is_final} speech_final={speech_final} "
                f"text={transcript[:60]!r}"
            )

        # is_final=True 代表该片段转录已确定不会再变，直接输出
        # speech_final 表示有停顿，连续对话中大多数句子 speech_final=False，不能依赖它
        if not is_final:
            return []

        alternatives = data.get("channel", {}).get("alternatives", [])
        if not alternatives:
            return []

        words = alternatives[0].get("words", [])
        if not words:
            return []

        # 按 speaker 分组（保持顺序）
        groups = []       # [(speaker_int, [word, ...])]
        cur_speaker = None
        cur_words = []

        for word in words:
            sp = word.get("speaker", 0)
            if cur_speaker is None:
                cur_speaker = sp
            if sp == cur_speaker:
                cur_words.append(word)
            else:
                groups.append((cur_speaker, cur_words))
                cur_speaker = sp
                cur_words = [word]
        if cur_words:
            groups.append((cur_speaker, cur_words))

        turns = []
        for speaker_int, wds in groups:
            turn = self._words_to_turn(speaker_int, wds)
            if turn:
                turns.append(turn)
        return turns

    def _words_to_turn(self, speaker_int: int, words: list) -> Optional[TranscribedTurn]:
        """将同一 speaker 的 words 列表合并为 TranscribedTurn"""
        # 优先用 punctuated_word（含标点），回退到 word
        parts = [w.get("punctuated_word") or w.get("word", "") for w in words]
        # 中文不加空格，英文加空格（按首字符判断）
        text = _smart_join(parts)
        if not text.strip():
            return None

        speaker_label = f"Speaker_{speaker_int + 1}"   # 0-indexed → 1-indexed
        idx = self._global_turn_index
        self._global_turn_index += 1

        start_sec = float(words[0].get("start", 0.0))
        end_sec = float(words[-1].get("end", 0.0))
        duration = end_sec - start_sec

        logger.info(
            f"[Deepgram] 转录完成 idx={idx} speaker={speaker_label} "
            f"dur={duration:.1f}s text={text[:40]}"
        )
        return TranscribedTurn(
            speaker_label=speaker_label,
            text=text,
            turn_index=idx,
            start_sec=start_sec,
            end_sec=end_sec,
        )

    async def receive_turns(self) -> AsyncIterator[Optional[TranscribedTurn]]:
        """供 live_audio.py 消费的异步迭代器"""
        while True:
            turn = await self._turn_queue.get()
            yield turn
            if turn is None:
                break


# ──────────────────────────────────────────────────────────────────────────────
# 工具函数
# ──────────────────────────────────────────────────────────────────────────────

def _smart_join(parts: list) -> str:
    """
    中文词之间不加空格，英文单词之间加空格。
    判断方式：若片段全部是 ASCII 则认为是英文。
    """
    if not parts:
        return ""
    # 若所有词都是 ASCII，按英文空格拼接
    if all(p.isascii() for p in parts if p):
        return " ".join(p for p in parts if p)
    # 否则（含中文），无空格拼接
    return "".join(parts)
