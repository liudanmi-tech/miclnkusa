"""
Live Mode — 音频代理 WebSocket
对应架构文档 Module B

端点：
  WS /api/v1/live/sessions/{session_id}/audio-stream?token={JWT}

流向：
  iOS PCM 帧 → 本端点 → GeminiProxySession → Gemini Live
  Gemini Live 转录 → GeminiProxySession._turn_queue → 本端点 → iOS WS + live_turns + live_events

鉴权（M-4）：
  JWT 通过 query param ?token= 传入（WebSocket 不支持 Authorization header）
  WS close code 4001 = 鉴权失败，4003 = 无权操作该 Session
"""
import asyncio
import json
import logging
import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from auth.jwt_handler import decode_token
from database.connection import get_db
from database.models import (
    Session as DbSession,
    LiveTurn,
    LiveEvent,
    LiveSegment,
    LiveSpeakerMapping,
)
from services.deepgram_live import DeepgramSession, TranscribedTurn
from services import live_pubsub
from services import live_turn_processor
from services import live_segment_manager
from services import voiceprint_matcher

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/live", tags=["live-audio"])

# ──────────────────────────────────────────────────────────────────────────────
# 辅助：JWT query param 鉴权
# ──────────────────────────────────────────────────────────────────────────────

def _user_id_from_token(token: str) -> Optional[str]:
    """从 JWT 字符串提取 user_id，无效则返回 None"""
    return decode_token(token)


async def _get_live_session(
    session_id: str,
    user_id: str,
    db: AsyncSession,
) -> Optional[DbSession]:
    result = await db.execute(
        select(DbSession).where(DbSession.id == uuid.UUID(session_id))
    )
    session = result.scalar_one_or_none()
    if session is None or str(session.user_id) != user_id:
        return None
    return session


# ──────────────────────────────────────────────────────────────────────────────
# 辅助：恢复 SpeakerMapping（WS 重连时用）
# ──────────────────────────────────────────────────────────────────────────────

async def restore_speaker_mapping(session_id: str, db: AsyncSession) -> dict:
    """返回 {speaker_label: {profile_id, confidence, method}}"""
    result = await db.execute(
        select(LiveSpeakerMapping).where(
            LiveSpeakerMapping.session_id == uuid.UUID(session_id)
        )
    )
    mapping = {}
    for row in result.scalars().all():
        mapping[row.speaker_label] = {
            "profile_id": str(row.profile_id) if row.profile_id else None,
            "confidence": row.confidence,
            "method": row.method,
        }
    return mapping


# ──────────────────────────────────────────────────────────────────────────────
# 辅助：写 Turn + 发布 SSE 事件
# ──────────────────────────────────────────────────────────────────────────────

async def _write_turn_and_event(
    turn: TranscribedTurn,
    session_id: str,
    segment_id: Optional[uuid.UUID],
    speaker_mapping: dict,
    db: AsyncSession,
) -> int:
    """
    1. 写入 live_turns（幂等：UNIQUE(session_id, turn_index)）
    2. 写入 live_events（供 SSE H-1 重放）
    TODO Step 6: 触发技能匹配 + 实时建议
    """
    # 判断 speaker 字段（"user" | "other"）
    mapping_info = speaker_mapping.get(turn.speaker_label, {})
    # 简单规则：若该 speaker_label 绑定的 profile 是"自己"关系，则 is_me
    # TODO Step 6: 结合 profile relationship_type 精确判断
    speaker = "user" if turn.speaker_label == "Speaker_1" else "other"

    now = datetime.now(timezone.utc)

    # 写 live_turns（ON CONFLICT DO UPDATE 逻辑：SQLAlchemy merge）
    live_turn = LiveTurn(
        session_id=uuid.UUID(session_id),
        turn_index=turn.turn_index,
        speaker=speaker,
        speaker_label=turn.speaker_label,
        text=turn.text,
        timestamp_ms=int(now.timestamp() * 1000),
        segment_id=segment_id,
        matched_skills=[],
        suggestion=None,
    )
    try:
        db.add(live_turn)
        await db.flush()
    except Exception:
        await db.rollback()
        # 已存在（幂等）：更新文本
        await db.execute(
            LiveTurn.__table__.update()
            .where(
                LiveTurn.session_id == uuid.UUID(session_id),
                LiveTurn.turn_index == turn.turn_index,
            )
            .values(text=turn.text, speaker_label=turn.speaker_label)
        )
        await db.flush()

    # 写 live_events（SSE H-1 重放用）
    event_payload = {
        "turn_index": turn.turn_index,
        "speaker_label": turn.speaker_label,
        "speaker": speaker,
        "text": turn.text,
        "timestamp_ms": int(now.timestamp() * 1000),
    }
    live_event = LiveEvent(
        session_id=uuid.UUID(session_id),
        event_type="transcript",
        payload=event_payload,
    )
    db.add(live_event)
    await db.flush()
    # 保存 event_id 供 commit 后 push 用
    event_id: int = live_event.id

    return event_id  # 返回给调用方，commit 后调用 push_event + on_turn_received


async def _get_active_segment_id(session_id: str, db: AsyncSession) -> Optional[uuid.UUID]:
    """获取当前活跃 Segment 的 ID"""
    result = await db.execute(
        select(LiveSegment.id).where(
            LiveSegment.session_id == uuid.UUID(session_id),
            LiveSegment.status == "active",
        ).order_by(LiveSegment.segment_index.desc()).limit(1)
    )
    return result.scalar_one_or_none()


# ──────────────────────────────────────────────────────────────────────────────
# WebSocket 端点
# ──────────────────────────────────────────────────────────────────────────────

@router.websocket("/sessions/{session_id}/audio-stream")
async def audio_stream_websocket(
    websocket: WebSocket,
    session_id: str,
    token: str,           # JWT via ?token= query param（M-4）
    db: AsyncSession = Depends(get_db),
):
    """
    双向 WebSocket：
    - 上行：iOS 发送 PCM binary frames → 转发到 Gemini Live
    - 下行：Gemini Live 转录结果 → 写 DB + 推 JSON 消息给 iOS
    """
    # ── 鉴权 ──
    user_id = _user_id_from_token(token)
    if not user_id:
        await websocket.close(code=4001)
        return

    # ── Session 归属校验 ──
    session = await _get_live_session(session_id, user_id, db)
    if session is None:
        await websocket.close(code=4003)
        return
    if session.session_type != "live" or session.status not in ("active", "completed"):
        await websocket.close(code=4003)
        return

    # ── 清除旧的断连时间戳（重连场景）──
    session.ws_disconnected_at = None
    await db.commit()

    # ── Accept WebSocket ──
    await websocket.accept()
    logger.info(
        f"[LiveAudio] WS 连接 user={user_id[:8]} session={session_id[:8]}"
    )

    # ── 恢复 SpeakerMapping（重连时已有识别结果继续用）──
    speaker_mapping = await restore_speaker_mapping(session_id, db)

    # ── 创建 Deepgram 代理 ──
    proxy = DeepgramSession(session_id)
    try:
        await proxy.connect()
    except Exception as e:
        logger.error(f"[LiveAudio] Deepgram 连接失败: {e}")
        await websocket.send_json({"type": "error", "message": "Deepgram 连接失败，请重试"})
        await websocket.close(code=1011)
        return

    # ── 启动两个并发任务 ──
    send_task = asyncio.create_task(
        _ios_to_gemini(websocket, proxy, session_id),
        name=f"ios_to_gemini_{session_id[:8]}",
    )
    recv_task = asyncio.create_task(
        _gemini_to_ios(websocket, proxy, session_id, user_id, speaker_mapping, db),
        name=f"gemini_to_ios_{session_id[:8]}",
    )

    try:
        done, pending = await asyncio.wait(
            [send_task, recv_task],
            return_when=asyncio.FIRST_COMPLETED,
        )
        # 任意一方结束，取消另一方
        for t in pending:
            t.cancel()
        # 检查是否有异常
        for t in done:
            if t.exception():
                logger.error(
                    f"[LiveAudio] 任务异常 session={session_id[:8]}: {t.exception()}"
                )
    except Exception as e:
        logger.error(f"[LiveAudio] WS handler 异常: {e}")
    finally:
        await proxy.close()
        # 记录 WS 断连时间（H-3 孤儿 Session 检测）
        try:
            async with db.begin_nested():
                await db.execute(
                    DbSession.__table__.update()
                    .where(DbSession.id == uuid.UUID(session_id))
                    .values(ws_disconnected_at=datetime.now(timezone.utc))
                )
        except Exception:
            pass
        voiceprint_matcher.cleanup(session_id)
        logger.info(f"[LiveAudio] WS 断连 session={session_id[:8]}")


# ──────────────────────────────────────────────────────────────────────────────
# 上行：iOS PCM → Gemini Live
# ──────────────────────────────────────────────────────────────────────────────

async def _ios_to_gemini(
    websocket: WebSocket,
    proxy: DeepgramSession,
    session_id: str,
) -> None:
    """
    持续从 iOS WS 接收 binary 帧（PCM 16-bit 16kHz mono），
    转发到 Deepgram；同时写入声纹 PCM 缓冲。
    """
    try:
        while True:
            data = await websocket.receive_bytes()
            await proxy.send_audio(data)
            voiceprint_matcher.append_pcm(session_id, data)   # 声纹缓冲
    except WebSocketDisconnect:
        logger.info("[LiveAudio] iOS WS 断连（上行任务退出）")
    except Exception as e:
        logger.error(f"[LiveAudio] _ios_to_gemini 异常: {e}")


# ──────────────────────────────────────────────────────────────────────────────
# 下行：Gemini Live 转录 → iOS + DB
# ──────────────────────────────────────────────────────────────────────────────

async def _gemini_to_ios(
    websocket: WebSocket,
    proxy: DeepgramSession,
    session_id: str,
    user_id: str,
    speaker_mapping: dict,
    db: AsyncSession,
) -> None:
    """
    从 GeminiProxySession 取出 TranscribedTurn，
    写入 live_turns + live_events，并推 JSON 消息给 iOS。
    """
    try:
        async for turn in proxy.receive_turns():
            if turn is None:
                break

            # 获取当前活跃 Segment
            segment_id = await _get_active_segment_id(session_id, db)

            # 写 DB
            event_id = await _write_turn_and_event(
                turn=turn,
                session_id=session_id,
                segment_id=segment_id,
                speaker_mapping=speaker_mapping,
                db=db,
            )
            await db.commit()

            # 声纹匹配（fire-and-forget，不阻塞主流程）
            asyncio.create_task(
                voiceprint_matcher.match_turn(
                    session_id=session_id,
                    speaker_label=turn.speaker_label,
                    start_sec=turn.start_sec,
                    end_sec=turn.end_sec,
                    user_id=user_id,
                    push_event_fn=live_pubsub.push_event,
                ),
                name=f"vp_match_{session_id[:8]}_{turn.turn_index}",
            )

            # 触发 Turn 实时处理（快速建议 + 异步技能匹配，fire-and-forget）
            live_turn_processor.on_turn_received(session_id, turn.turn_index)
            # Segment Task A：每 10 turns 改写 running_context（Layer 2，fire-and-forget）
            live_segment_manager.on_turn_received(session_id, turn.turn_index, turn.speaker_label)

            # 推送 SSE transcript 事件（DB commit 后保证 replay 一致性）
            speaker = "user" if turn.speaker_label == "Speaker_1" else "other"
            live_pubsub.push_event(
                session_id=session_id,
                event_id=event_id,
                event_type="transcript",
                payload={
                    "turn_index": turn.turn_index,
                    "speaker_label": turn.speaker_label,
                    "speaker": speaker,
                    "text": turn.text,
                    "timestamp_ms": int(datetime.now(timezone.utc).timestamp() * 1000),
                },
            )

            # 推给 iOS
            msg = {
                "type": "transcript",
                "turn_index": turn.turn_index,
                "speaker_label": turn.speaker_label,
                "text": turn.text,
                "timestamp_ms": int(datetime.now(timezone.utc).timestamp() * 1000),
            }
            try:
                await websocket.send_json(msg)
            except Exception:
                # iOS 可能已断连，不影响写 DB
                pass

    except asyncio.CancelledError:
        pass
    except Exception as e:
        logger.error(f"[LiveAudio] _gemini_to_ios 异常: {e}")
