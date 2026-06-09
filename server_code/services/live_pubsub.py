"""
Live Mode 内存 Pub/Sub 注册表

职责：
  - 维护每个 session_id 的活跃 SSE 订阅者队列列表
  - 提供 push_event() 把事件推到所有活跃订阅者
  - subscribe() / unsubscribe() 管理订阅者生命周期

注意：
  - 内存状态，服务重启后清空（SSE 客户端会用 Last-Event-ID 从 DB 重放）
  - 不做 DB 写入，只做内存分发；DB 写入在调用方（live_audio.py）完成
"""
import asyncio
import logging
from typing import Dict, List

logger = logging.getLogger(__name__)

# session_id → 该 session 所有活跃 SSE 连接的队列列表
_subscribers: Dict[str, List[asyncio.Queue]] = {}


def push_event(
    session_id: str,
    event_id: int,
    event_type: str,
    payload: dict,
) -> None:
    """
    向该 session 所有活跃 SSE 订阅者推送一条事件。
    调用方需确保 DB commit 已完成再调用此函数（保证 replay 一致性）。
    """
    queues = _subscribers.get(session_id, [])
    if not queues:
        return
    msg = {"id": event_id, "event": event_type, "data": payload}
    for q in queues:
        try:
            q.put_nowait(msg)
        except asyncio.QueueFull:
            logger.warning(
                f"[PubSub] session={session_id[:8]} 订阅者队列已满，丢弃事件 id={event_id}"
            )


def push_session_end(session_id: str) -> None:
    """Session 结束时通知所有 SSE 连接关闭（发送 None 哨兵）"""
    for q in _subscribers.get(session_id, []):
        q.put_nowait(None)


def subscribe(session_id: str, maxsize: int = 200) -> asyncio.Queue:
    """
    注册一个新的 SSE 订阅者，返回其专属队列。
    调用方需在连接关闭时调用 unsubscribe()。
    """
    q: asyncio.Queue = asyncio.Queue(maxsize=maxsize)
    _subscribers.setdefault(session_id, []).append(q)
    logger.debug(
        f"[PubSub] subscribe session={session_id[:8]} "
        f"total={len(_subscribers[session_id])}"
    )
    return q


def unsubscribe(session_id: str, queue: asyncio.Queue) -> None:
    """注销 SSE 订阅者"""
    lst = _subscribers.get(session_id, [])
    try:
        lst.remove(queue)
    except ValueError:
        pass
    if not lst:
        _subscribers.pop(session_id, None)
    logger.debug(f"[PubSub] unsubscribe session={session_id[:8]}")
