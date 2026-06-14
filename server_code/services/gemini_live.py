"""
GeminiProxySession — Gemini Live 会话代理

职责：
  - 管理与 Gemini Live 的 WebSocket 连接
  - 持续转发 iOS PCM 音频帧到 Gemini Live
  - 将 Gemini 转录结果解析为结构化 Turn 放入队列
  - H-4：接近 15 分钟时原子切换新 Session，期间 buffer 音频防丢帧
"""
import asyncio
import json
import logging
import os
from collections import deque
from typing import AsyncIterator, NamedTuple, Optional

from google import genai
from google.genai import types

logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────────────────────────────────────
# 常量
# ──────────────────────────────────────────────────────────────────────────────
GEMINI_MODEL = "gemini-3.1-flash-live-preview"
GEMINI_AUDIO_MIME = "audio/pcm;rate=16000"
SESSION_RENEW_SECONDS = 14 * 60     # 14 分钟触发续期（Gemini Live 上限 15 分钟）
AUDIO_BUFFER_MAXLEN = 200           # 约 96 KB PCM，应对 1-3s 建连延迟

# TEXT 输出模型：每段发言以 JSON 格式返回，含 speaker 标签
# 用于区分多个说话人（Speaker_1 = 用户，Speaker_2/3... = 其他人）
TRANSCRIPTION_SYSTEM_PROMPT = """你是一个实时对话转录助手。

规则：
1. 只转录，不分析，不发言
2. 每段发言严格按以下 JSON 格式输出（单行，不要其他内容）：
   {"speaker":"Speaker_1","text":"转录文字"}
3. 说话人标签规则：
   - Speaker_1：距离麦克风最近的声音（戴眼镜的用户）
   - Speaker_2、Speaker_3...：其他说话人，按首次出现顺序编号
   - 保持说话人标签在整场对话中一致（同一把声音始终用同一个标签）
4. 若只有一个人说话，统一用 Speaker_1
5. 中文和英文混合时，按实际发言语言转录"""


# ──────────────────────────────────────────────────────────────────────────────
# 数据结构
# ──────────────────────────────────────────────────────────────────────────────
class TranscribedTurn(NamedTuple):
    speaker_label: str   # "Speaker_1" / "Speaker_2"
    text: str
    turn_index: int      # session 内全局递增，续期后不重置


# ──────────────────────────────────────────────────────────────────────────────
# GeminiProxySession
# ──────────────────────────────────────────────────────────────────────────────
class GeminiProxySession:
    """
    单个录音 Session 对应一个 GeminiProxySession 实例。
    跨越 WebSocket 断连后可复用（ws_disconnected_at 场景）。
    """

    def __init__(self, session_id: str):
        self.session_id = session_id
        self._client = genai.Client(
            api_key=os.getenv("GEMINI_API_KEY", ""),
            http_options=types.HttpOptions(api_version="v1alpha"),
        )
        self._session = None        # 当前 Gemini Live AsyncLiveSession
        self._session_ctx = None    # async context manager 对象
        self._recv_task: Optional[asyncio.Task] = None

        # H-4 原子切换
        self._is_switching = False
        self._switch_lock = asyncio.Lock()
        self._audio_buffer: deque[bytes] = deque(maxlen=AUDIO_BUFFER_MAXLEN)

        # Turn 计数（续期后不重置，保持全局连续）
        self._global_turn_index = 0

        # model_turn TEXT 流式累积缓冲（TEXT 输出模型使用）
        self._model_turn_buffer: str = ""

        # 会话计时（用于触发续期）
        self._session_start_mono: Optional[float] = None

        # 关闭标志
        self._closed = False

        # 供消费者读取的 turn 队列（None 表示流结束）
        self._turn_queue: asyncio.Queue[Optional[TranscribedTurn]] = asyncio.Queue()

    # ── 连接管理 ──────────────────────────────────────────────────────────────

    def _make_config(self) -> types.LiveConnectConfig:
        # TEXT 输出模式：模型直接输出转录 JSON，含说话人标签
        return types.LiveConnectConfig(
            response_modalities=["TEXT"],
            system_instruction=types.Content(
                parts=[types.Part(text=TRANSCRIPTION_SYSTEM_PROMPT)]
            ),
        )

    async def connect(self) -> None:
        """建立到 Gemini Live 的连接，启动后台接收任务"""
        self._closed = False
        self._session_ctx = self._client.aio.live.connect(
            model=GEMINI_MODEL,
            config=self._make_config(),
        )
        self._session = await self._session_ctx.__aenter__()
        self._session_start_mono = asyncio.get_event_loop().time()
        self._recv_task = asyncio.create_task(
            self._receive_loop(), name=f"gemini_recv_{self.session_id[:8]}"
        )
        logger.info(f"[GeminiProxy] 连接建立 session={self.session_id[:8]}")

    async def close(self) -> None:
        """关闭 Gemini Live 连接，通知 turn_queue 消费者"""
        self._closed = True
        if self._recv_task and not self._recv_task.done():
            self._recv_task.cancel()
        if self._session_ctx is not None:
            try:
                await self._session_ctx.__aexit__(None, None, None)
            except Exception:
                pass
        # 通知 receive_turns() 迭代器结束
        await self._turn_queue.put(None)
        logger.info(f"[GeminiProxy] 连接关闭 session={self.session_id[:8]}")

    # ── 发送音频 ──────────────────────────────────────────────────────────────

    async def send_audio(self, pcm_bytes: bytes) -> None:
        """
        发送 PCM 帧到 Gemini Live。
        switching 期间放入 buffer，不丢帧。
        接近 15 分钟时异步触发续期。
        """
        if self._closed:
            return

        if self._is_switching:
            self._audio_buffer.append(pcm_bytes)
            return

        await self._send_raw(pcm_bytes)

        # 检查是否需要触发续期
        if (
            self._session_start_mono is not None
            and not self._is_switching
            and (asyncio.get_event_loop().time() - self._session_start_mono) >= SESSION_RENEW_SECONDS
        ):
            asyncio.create_task(
                self._renew_session(), name=f"gemini_renew_{self.session_id[:8]}"
            )

    async def _send_raw(self, pcm_bytes: bytes) -> None:
        """直接发到当前 Gemini Live session"""
        if self._session is None or self._closed:
            return
        try:
            await self._session.send_realtime_input(
                audio=types.Blob(data=pcm_bytes, mime_type=GEMINI_AUDIO_MIME)
            )
        except Exception as e:
            logger.warning(f"[GeminiProxy] send_raw 失败: {e}")

    # ── 接收转录 ──────────────────────────────────────────────────────────────

    async def _receive_loop(self) -> None:
        """后台任务：从 Gemini Live 读取响应，解析 Turn，放入 _turn_queue"""
        try:
            # google-genai 2.0.1: receive() 在 turn_complete 后自动结束（单轮迭代器）
            # 外层 while 保证持续接收多轮对话
            while not self._closed:
                async for response in self._session.receive():
                    if self._closed:
                        break
                    turn = self._parse_response(response)
                    if turn:
                        await self._turn_queue.put(turn)
        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"[GeminiProxy] receive_loop 异常: {e}")
        finally:
            if not self._closed:
                # 非主动关闭时（如 Gemini 断连），通知上层
                await self._turn_queue.put(None)

    def _parse_response(self, response) -> Optional[TranscribedTurn]:
        """
        解析 Gemini Live 响应（TEXT 输出模式）。
        模型将每段发言输出为单行 JSON：{"speaker":"Speaker_1","text":"..."}
          - server_content.model_turn.parts[].text → 流式累积到 _model_turn_buffer
          - server_content.turn_complete = True → flush buffer，解析 JSON，发出 Turn
        """
        try:
            sc = getattr(response, "server_content", None)
            if sc is None:
                return None

            tc = getattr(sc, "turn_complete", False)

            # ── 累积 model_turn TEXT 流式输出 ─────────────────────────────────
            model_turn = getattr(sc, "model_turn", None)
            if model_turn is not None:
                parts = getattr(model_turn, "parts", None) or []
                chunk = "".join(getattr(p, "text", "") or "" for p in parts)
                if chunk:
                    self._model_turn_buffer += chunk

            # ── turn_complete → flush buffer，解析 JSON ────────────────────────
            if tc and self._model_turn_buffer.strip():
                raw_text = self._model_turn_buffer.strip()
                self._model_turn_buffer = ""
                idx = self._global_turn_index
                self._global_turn_index += 1

                # 逐行尝试解析 JSON，取第一个有效行
                speaker_label = "Speaker_1"
                turn_text = raw_text
                for line in raw_text.splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        data = json.loads(line)
                        speaker_label = str(data.get("speaker", "Speaker_1"))
                        turn_text = str(data.get("text", "")).strip()
                        break
                    except (json.JSONDecodeError, AttributeError):
                        continue

                if not turn_text:
                    return None
                logger.info(
                    f"[GeminiProxy] 转录完成 idx={idx} speaker={speaker_label} text={turn_text[:40]}"
                )
                return TranscribedTurn(
                    speaker_label=speaker_label,
                    text=turn_text,
                    turn_index=idx,
                )

            return None
        except Exception as e:
            logger.warning(f"[GeminiProxy] _parse_response 异常: {e}")
            return None

    async def receive_turns(self) -> AsyncIterator[Optional[TranscribedTurn]]:
        """供 WebSocket handler 消费的异步迭代器"""
        while True:
            turn = await self._turn_queue.get()
            yield turn
            if turn is None:
                break

    # ── 15 分钟原子切换（H-4）────────────────────────────────────────────────

    async def _renew_session(self, retry: int = 0) -> None:
        """
        原子切换 Gemini Live Session（防止 15 分钟断连）

        步骤：
        1. is_switching=True → 新音频放入 buffer
        2. 建立新 Gemini Live 连接
        3. 原子替换 session 引用，is_switching=False
        4. 重放 buffer
        5. 关闭旧连接
        """
        async with self._switch_lock:
            if self._closed:
                return
            logger.info(
                f"[GeminiProxy] 开始续期 session={self.session_id[:8]} retry={retry}"
            )
            self._is_switching = True
            try:
                # Step 1: 建立新连接
                new_ctx = self._client.aio.live.connect(
                    model=GEMINI_MODEL,
                    config=self._make_config(),
                )
                new_session = await new_ctx.__aenter__()

                # Step 2: 保存旧引用
                old_ctx = self._session_ctx
                old_recv_task = self._recv_task

                # Step 3: 原子替换
                self._session = new_session
                self._session_ctx = new_ctx
                self._session_start_mono = asyncio.get_event_loop().time()
                self._is_switching = False
                self._recv_task = asyncio.create_task(self._receive_loop())

                # Step 4: 重放 buffer
                buffered = list(self._audio_buffer)
                self._audio_buffer.clear()
                for chunk in buffered:
                    await self._send_raw(chunk)
                logger.info(
                    f"[GeminiProxy] 续期成功，重放 {len(buffered)} 帧"
                    f" session={self.session_id[:8]}"
                )

                # Step 5: 关闭旧连接
                if old_recv_task and not old_recv_task.done():
                    old_recv_task.cancel()
                if old_ctx:
                    try:
                        await old_ctx.__aexit__(None, None, None)
                    except Exception:
                        pass

            except Exception as e:
                self._is_switching = False
                logger.error(
                    f"[GeminiProxy] 续期失败 retry={retry}: {e}"
                )
                if retry < 3:
                    await asyncio.sleep(2 ** retry)  # 指数退避
                    await self._renew_session(retry + 1)
                else:
                    logger.error(
                        f"[GeminiProxy] 续期失败超过最大重试次数，关闭 session"
                    )
                    await self.close()
