"""
Live Mode — SSE 事件流
对应架构文档 Module C（H-1 replay）

端点：
  GET /api/v1/live/sessions/{session_id}/events?token={JWT}

行为：
  1. 用 Last-Event-ID 重放断连期间错过的事件（10 分钟窗口）
  2. 实时推送新事件（via live_pubsub）
  3. 每 30 秒发送 SSE comment 心跳，防止连接超时

鉴权（M-4）：
  JWT 通过 ?token= query param 传入
"""
import asyncio
import json
import logging
import uuid
from datetime import datetime, timezone, timedelta
from typing import AsyncIterator, Optional

from fastapi import APIRouter, Header, Request
from fastapi.responses import StreamingResponse
from sqlalchemy import select

from auth.jwt_handler import decode_token
from database.connection import AsyncSessionLocal
from database.models import Session as DbSession, LiveEvent
from services import live_pubsub

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/live", tags=["live-sse"])

# SSE 重放窗口（只重放最近 10 分钟的事件）
SSE_REPLAY_WINDOW_MINUTES = 10
# 心跳间隔（秒）
SSE_PING_INTERVAL = 30


def _format_sse(event_id: int, event_type: str, data: dict) -> str:
    """格式化单条 SSE 消息"""
    return (
        f"id: {event_id}\n"
        f"event: {event_type}\n"
        f"data: {json.dumps(data, ensure_ascii=False)}\n\n"
    )


async def _replay_missed_events(
    session_id: str,
    last_event_id: int,
) -> AsyncIterator[str]:
    """
    从 live_events 表重放断连期间错过的事件。
    只重放 id > last_event_id 且在最近 10 分钟内的事件。
    """
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=SSE_REPLAY_WINDOW_MINUTES)
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(LiveEvent)
            .where(
                LiveEvent.session_id == uuid.UUID(session_id),
                LiveEvent.id > last_event_id,
                LiveEvent.created_at > cutoff,
            )
            .order_by(LiveEvent.id.asc())
        )
        events = result.scalars().all()

    for ev in events:
        yield _format_sse(ev.id, ev.event_type, ev.payload)
    if events:
        logger.info(
            f"[SSE] replay session={session_id[:8]} "
            f"count={len(events)} from_id={last_event_id}"
        )


async def _sse_generator(
    session_id: str,
    last_event_id: int,
    request: Request,
) -> AsyncIterator[str]:
    """
    核心 SSE 生成器：
    1. 先重放错过的事件
    2. 订阅 live_pubsub
    3. 循环 wait：30s 超时发心跳，收到事件即推送，None 哨兵则关闭
    """
    # Step 1: 重放
    async for chunk in _replay_missed_events(session_id, last_event_id):
        yield chunk

    # Step 2: 订阅内存 pubsub
    queue = live_pubsub.subscribe(session_id)
    logger.info(f"[SSE] 客户端连接 session={session_id[:8]} last_id={last_event_id}")

    try:
        while True:
            try:
                msg = await asyncio.wait_for(queue.get(), timeout=SSE_PING_INTERVAL)
            except asyncio.TimeoutError:
                # 心跳 comment（不含 id:，不影响 Last-Event-ID）
                # 仅在 30s 超时后检测客户端断连，避免 is_disconnected() 在热路径阻塞事件循环
                if await request.is_disconnected():
                    logger.info(f"[SSE] 客户端断连（ping 检测）session={session_id[:8]}")
                    break
                yield ": ping\n\n"
                continue

            if msg is None:
                # Session 结束哨兵
                yield "event: session_end\ndata: {}\n\n"
                break

            yield _format_sse(msg["id"], msg["event"], msg["data"])
            logger.info(f"[SSE] 已发送 id={msg['id']} type={msg['event']} session={session_id[:8]}")

    except asyncio.CancelledError:
        pass
    finally:
        live_pubsub.unsubscribe(session_id, queue)
        logger.info(f"[SSE] 取消订阅 session={session_id[:8]}")


# ──────────────────────────────────────────────────────────────────────────────
# GET /api/v1/live/sessions/{session_id}/events
# ──────────────────────────────────────────────────────────────────────────────

@router.get("/sessions/{session_id}/events")
async def live_events_stream(
    session_id: str,
    token: str,               # JWT via ?token= query param（M-4）
    request: Request,
    last_event_id: Optional[str] = Header(None, alias="Last-Event-ID"),
):
    """
    SSE 事件流端点。

    客户端连接时：
    - 携带 Last-Event-ID header 触发 H-1 重放
    - 不携带则从当前时刻开始接收新事件

    返回 text/event-stream，格式：
      id: <bigserial>\\nevent: <type>\\ndata: <json>\\n\\n
    """
    # ── 鉴权 ──
    user_id = decode_token(token)
    if not user_id:
        # SSE 不能返回 HTTP 4xx 再 stream，直接返回 401 plaintext
        return StreamingResponse(
            iter(["event: error\ndata: {\"code\": 401}\n\n"]),
            media_type="text/event-stream",
            status_code=401,
        )

    # ── Session 归属校验 ──
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(DbSession).where(DbSession.id == uuid.UUID(session_id))
        )
        session = result.scalar_one_or_none()

    if session is None or str(session.user_id) != user_id:
        return StreamingResponse(
            iter(["event: error\ndata: {\"code\": 403}\n\n"]),
            media_type="text/event-stream",
            status_code=403,
        )

    # 解析 Last-Event-ID
    parsed_last_id: int = 0
    if last_event_id:
        try:
            parsed_last_id = int(last_event_id)
        except (ValueError, TypeError):
            parsed_last_id = 0

    return StreamingResponse(
        _sse_generator(session_id, parsed_last_id, request),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",          # 关闭 nginx 缓冲
            "Connection": "keep-alive",
        },
    )
