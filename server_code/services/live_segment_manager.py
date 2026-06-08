"""
Live Mode Segment 管理器
对应架构文档 Module E

职责：
  Task A：每 10 turns 改写 running_context（Layer 2 摘要，≤300 token）
  - 输入：当前 Segment 全部 turns + 旧 running_context
  - 输出：≤300 token 新摘要 → 覆写 live_segments.running_context
  - 触发：(turn_index + 1) % 10 == 0（与异步分析路径同步触发）

注意：
  - 内存 speaker 集合仅做未来自动分段扩展用，暂不触发 Segment 切分
  - Task A 使用独立 DB session，不复用 WS handler session
  - 失败只记日志，不影响主链路
"""
import asyncio
import logging
import os
import uuid
from typing import Dict, Optional, Set

from google import genai as genai_sdk
from sqlalchemy import select, update

from database.connection import AsyncSessionLocal
from database.models import LiveEvent, LiveSegment, LiveTurn
from services import live_pubsub

logger = logging.getLogger(__name__)

# ── 常量 ──────────────────────────────────────────────────────────────────────

GEMINI_FLASH_MODEL = os.getenv("GEMINI_FLASH_MODEL", "gemini-2.0-flash")
GEMINI_API_KEY     = os.getenv("GEMINI_API_KEY", "")

_CONTEXT_REWRITE_PROMPT = """\
以下是一段对话记录（user=我，other=对方）：

{turns_text}

{old_context_section}\
请输出不超过 300 token 的摘要，重点保留：关键决策、未解决分歧、情绪转折点、人物立场变化。旧的细节可以归并压缩。

只输出摘要文本，不含其他内容。"""

# ── 内存状态（per session）──────────────────────────────────────────────────

_speaker_sets: Dict[str, Set[str]] = {}


def _get_speakers(session_id: str) -> Set[str]:
    if session_id not in _speaker_sets:
        _speaker_sets[session_id] = set()
    return _speaker_sets[session_id]


def clear_session(session_id: str) -> None:
    """Session 结束后清理内存（由 live_sessions.py end 调用）"""
    _speaker_sets.pop(session_id, None)


# ── 公共入口 ──────────────────────────────────────────────────────────────────

def on_turn_received(
    session_id: str,
    turn_index: int,
    speaker_label: Optional[str],
) -> None:
    """
    每条 turn 写 DB 并 commit 后调用（同步，fire-and-forget）。
    记录 speaker；每 10 turns 触发 running_context 改写。
    """
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return

    # 记录 speaker（为后续自动分段预留）
    if speaker_label:
        _get_speakers(session_id).add(speaker_label)

    # Task A：每 10 turns 触发 running_context 改写
    if (turn_index + 1) % 10 == 0:
        loop.create_task(
            _rewrite_running_context(session_id),
            name=f"seg_ctx_{session_id[:8]}_{turn_index}",
        )


# ── Task A：running_context 改写 ──────────────────────────────────────────────

async def _rewrite_running_context(session_id: str) -> None:
    """
    改写当前活跃 Segment 的 running_context（≤300 token）。
    覆写，不追加——无论对话多长，Layer 2 大小恒定。
    """
    try:
        async with AsyncSessionLocal() as db:
            # 1. 找活跃 Segment
            seg_result = await db.execute(
                select(LiveSegment)
                .where(
                    LiveSegment.session_id == uuid.UUID(session_id),
                    LiveSegment.status == "active",
                )
                .order_by(LiveSegment.segment_index.desc())
                .limit(1)
            )
            segment = seg_result.scalar_one_or_none()
            if segment is None:
                logger.warning(f"[SegmentMgr] 无活跃 Segment session={session_id[:8]}")
                return

            # 2. 取该 Segment 全部 turns（按时序）
            turns_result = await db.execute(
                select(LiveTurn)
                .where(LiveTurn.segment_id == segment.id)
                .order_by(LiveTurn.turn_index.asc())
            )
            turns = turns_result.scalars().all()
            if not turns:
                # Segment 尚无关联 turns（段刚建，还未写入）
                logger.debug(f"[SegmentMgr] Segment 暂无 turns session={session_id[:8]}")
                return

            # 3. 构建 prompt
            turns_text = "\n".join(f"{t.speaker}: {t.text}" for t in turns)
            old_ctx = segment.running_context or ""
            old_section = (
                f"当前已有摘要（可压缩）：\n{old_ctx}\n\n"
                if old_ctx else ""
            )
            prompt = _CONTEXT_REWRITE_PROMPT.format(
                turns_text=turns_text,
                old_context_section=old_section,
            )

            # 4. 调 Gemini Flash
            _client = genai_sdk.Client(api_key=GEMINI_API_KEY)
            resp = await asyncio.to_thread(
                _client.models.generate_content,
                model=GEMINI_FLASH_MODEL,
                contents=prompt,
            )
            new_context = (resp.text or "").strip()
            if not new_context:
                logger.debug(f"[SegmentMgr] 改写结果为空 session={session_id[:8]}")
                return

            # 5. 覆写（不追加）
            await db.execute(
                update(LiveSegment)
                .where(LiveSegment.id == segment.id)
                .values(running_context=new_context)
            )

            # 6. 写 live_events（供 SSE H-1 重放）
            ctx_payload = {"type": "segment_context", "text": new_context}
            live_event = LiveEvent(
                session_id=uuid.UUID(session_id),
                event_type="segment_context",
                payload=ctx_payload,
            )
            db.add(live_event)
            await db.flush()
            event_id = live_event.id
            await db.commit()

            # 7. 推送 SSE
            live_pubsub.push_event(
                session_id=session_id,
                event_id=event_id,
                event_type="segment_context",
                payload=ctx_payload,
            )
            logger.info(
                f"[SegmentMgr] running_context 改写完成 session={session_id[:8]} "
                f"segment_idx={segment.segment_index} turns={len(turns)} "
                f"chars={len(new_context)}"
            )

    except Exception as exc:
        logger.error(
            f"[SegmentMgr] running_context 改写异常 session={session_id[:8]}: {exc}",
            exc_info=True,
        )


# ── 供 live_turn_processor 查询 Layer 2 ────────────────────────────────────────

async def get_running_context(session_id: str, db) -> Optional[str]:
    """
    返回当前活跃 Segment 的 running_context（Layer 2）。
    供 live_turn_processor._run_quick_suggestion 注入到 prompt。
    """
    result = await db.execute(
        select(LiveSegment.running_context)
        .where(
            LiveSegment.session_id == uuid.UUID(session_id),
            LiveSegment.status == "active",
        )
        .order_by(LiveSegment.segment_index.desc())
        .limit(1)
    )
    return result.scalar_one_or_none()
