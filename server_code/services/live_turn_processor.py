"""
Live Mode Turn 实时处理器
对应架构文档 Module C（服务端 C）

两条路径：
  快速路径（Fast Path）
    触发：每 3 turn 或距上次 20s
    输入：最近 8 条 turn
    输出：1 条实时建议 + 情绪标签 → 更新 live_turns.suggestion + 推 SSE suggestion

  异步路径（Async Path）
    触发：每累计 10 turn（turn_index = 9, 19, 29 ...）
    输入：本批次 10 条 turn
    输出：skill_cards → 更新 live_turns.matched_skills + 推 SSE analysis_ready

注意：
  - 状态在内存中（服务重启后从 turn_index 推断，无需持久化）
  - 所有异步任务使用独立 DB session，不复用 WS handler 的 session
  - 任务失败只记录日志，不影响主链路
"""
import asyncio
import json
import logging
import os
import uuid
from typing import Any, Dict

from google import genai as genai_sdk
from sqlalchemy import select, update

from database.connection import AsyncSessionLocal
from database.models import (
    Session as DbSession,
    LiveTurn,
    LiveEvent,
)
from services import live_pubsub
from services import live_segment_manager

logger = logging.getLogger(__name__)

# ── 常量 ──────────────────────────────────────────────────────────────────────

QUICK_TRIGGER_TURNS  = 3         # 每累积 N turn 触发快速建议
QUICK_TRIGGER_SECS   = 20.0      # 或距上次超过 N 秒
ASYNC_TRIGGER_TURNS  = 10        # 每累积 N turn 触发异步分析（turn_index = 9,19,29...）

# 快速建议：轻量模型，< 2s 目标
GEMINI_FLASH_MODEL = os.getenv("GEMINI_FLASH_MODEL", "gemini-2.0-flash")
# 异步分析：高质量模型，场景分类 + 技能匹配
GEMINI_TEXT_MODEL  = os.getenv("GEMINI_TEXT_MODEL",  "gemini-2.5-flash")
GEMINI_API_KEY     = os.getenv("GEMINI_API_KEY", "")

# 快速建议 prompt（严格要求单行 JSON，< 2s）
# {context_section} = Layer 2 running_context 前缀（有则注入，无则空串）
_QUICK_PROMPT = """\
你是实时对话辅助助手。{context_section}以下是对话最近几句（user=我，other=对方）：

{transcript}

分析对方当前情绪，给出1条简短沟通建议。

输出严格单行JSON，不含其他内容：
{{"text":"建议（20字内）","emotion_tag":"情绪标签（含emoji）","skill_hint":"技能关键词"}}"""

# ── 内存状态（per session，服务重启自动重置）──────────────────────────────────

_state: Dict[str, Dict[str, Any]] = {}


def _get_state(session_id: str) -> Dict[str, Any]:
    if session_id not in _state:
        _state[session_id] = {
            "last_quick_turn_index": -QUICK_TRIGGER_TURNS,  # 首条 turn 即触发
            "last_quick_mono": 0.0,
        }
    return _state[session_id]


def clear_session(session_id: str) -> None:
    """Session 结束后清理内存状态（由 live_sessions.py end 调用）"""
    _state.pop(session_id, None)


# ── 公共入口 ──────────────────────────────────────────────────────────────────

def on_turn_received(session_id: str, turn_index: int) -> None:
    """
    每条 turn 写 DB 并 commit 后调用（同步，从 async 上下文调用）。
    根据触发条件 fire-and-forget 创建后台任务。
    """
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return  # 不在 async 上下文，跳过

    state = _get_state(session_id)
    now   = loop.time()

    # ── 快速路径检查 ──────────────────────────────────────────────────────
    turns_since = turn_index - state["last_quick_turn_index"]
    secs_since  = now - state["last_quick_mono"]

    if turns_since >= QUICK_TRIGGER_TURNS or secs_since >= QUICK_TRIGGER_SECS:
        state["last_quick_turn_index"] = turn_index
        state["last_quick_mono"]       = now
        loop.create_task(
            _run_quick_suggestion(session_id, turn_index),
            name=f"quick_{session_id[:8]}_{turn_index}",
        )

    # ── 异步路径检查 ──────────────────────────────────────────────────────
    # turn_index 0-based：第 10 条（idx=9）、第 20 条（idx=19）...
    if (turn_index + 1) % ASYNC_TRIGGER_TURNS == 0:
        batch_start = turn_index + 1 - ASYNC_TRIGGER_TURNS
        loop.create_task(
            _run_async_analysis(session_id, batch_start, turn_index),
            name=f"async_{session_id[:8]}_{batch_start}-{turn_index}",
        )


# ── 快速路径（Fast Path）─────────────────────────────────────────────────────

async def _run_quick_suggestion(session_id: str, turn_index: int) -> None:
    """
    调用 Gemini Flash 生成 1 条实时建议。
    写入 live_turns.suggestion（最新 turn）+ live_events（SSE 重放）。
    触发 SSE 推送。
    """
    try:
        async with AsyncSessionLocal() as db:
            # 1. 取最近 8 条 turns
            result = await db.execute(
                select(LiveTurn)
                .where(LiveTurn.session_id == uuid.UUID(session_id))
                .order_by(LiveTurn.turn_index.desc())
                .limit(8)
            )
            turns = list(reversed(result.scalars().all()))
            if not turns:
                return

            # 2. 格式化 transcript
            lines = "\n".join(
                f"{t.speaker}: {t.text}" for t in turns
            )

            # 2b. 注入 Layer 2（running_context，若有）
            running_ctx = await live_segment_manager.get_running_context(session_id, db)
            context_section = (
                f"背景摘要（本段已有共识）：{running_ctx}\n\n"
                if running_ctx else ""
            )
            prompt = _QUICK_PROMPT.format(
                transcript=lines,
                context_section=context_section,
            )

            # 3. 调 Gemini Flash（< 2s）
            _client = genai_sdk.Client(api_key=GEMINI_API_KEY)
            resp = await asyncio.to_thread(
                _client.models.generate_content,
                model=GEMINI_FLASH_MODEL,
                contents=prompt,
            )
            raw = (resp.text or "").strip()

            # 4. 解析 JSON
            suggestion_text = ""
            emotion_tag     = ""
            skill_hint      = ""
            try:
                # 提取 JSON（防止模型输出额外文字）
                start = raw.find("{")
                end   = raw.rfind("}") + 1
                if start >= 0 and end > start:
                    data = json.loads(raw[start:end])
                    suggestion_text = data.get("text", "").strip()
                    emotion_tag     = data.get("emotion_tag", "").strip()
                    skill_hint      = data.get("skill_hint", "").strip()
            except (json.JSONDecodeError, ValueError):
                suggestion_text = raw[:60] if raw else ""

            if not suggestion_text:
                logger.debug(f"[TurnProc] 快速建议为空 session={session_id[:8]}")
                return

            # 5. 更新最新 turn 的 suggestion 字段
            await db.execute(
                update(LiveTurn)
                .where(
                    LiveTurn.session_id == uuid.UUID(session_id),
                    LiveTurn.turn_index == turn_index,
                )
                .values(suggestion=suggestion_text)
            )

            # 6. 写 live_events（供 SSE H-1 重放）
            payload = {
                "type":       "suggestion",
                "text":       suggestion_text,
                "emotion_tag": emotion_tag,
                "skill_hint": skill_hint,
                "turn_index": turn_index,
            }
            live_event = LiveEvent(
                session_id=uuid.UUID(session_id),
                event_type="suggestion",
                payload=payload,
            )
            db.add(live_event)
            await db.flush()
            event_id = live_event.id
            await db.commit()

            # 7. 推送 SSE
            live_pubsub.push_event(
                session_id=session_id,
                event_id=event_id,
                event_type="suggestion",
                payload=payload,
            )
            logger.info(
                f"[TurnProc] 快速建议已推送 session={session_id[:8]} "
                f"turn={turn_index} emotion={emotion_tag}"
            )

    except Exception as exc:
        logger.error(
            f"[TurnProc] 快速建议异常 session={session_id[:8]} turn={turn_index}: {exc}"
        )


# ── 异步路径（Async Path）────────────────────────────────────────────────────

async def _run_async_analysis(
    session_id: str,
    batch_start: int,
    batch_end: int,
) -> None:
    """
    场景分类 + 技能匹配，结果写入 live_turns.matched_skills，
    并推送 SSE analysis_ready（含 skill_cards）。
    脚本生成（visual[]）在 Step 9 后处理时完成。
    """
    try:
        # 延迟导入：skills.router 只在服务端存在
        from skills.router import classify_scene, match_skills

        async with AsyncSessionLocal() as db:
            # 1. 取本批次 turns
            result = await db.execute(
                select(LiveTurn)
                .where(
                    LiveTurn.session_id == uuid.UUID(session_id),
                    LiveTurn.turn_index >= batch_start,
                    LiveTurn.turn_index <= batch_end,
                )
                .order_by(LiveTurn.turn_index.asc())
            )
            turns = result.scalars().all()
            if not turns:
                logger.warning(
                    f"[TurnProc] 异步分析无数据 session={session_id[:8]} "
                    f"batch={batch_start}-{batch_end}"
                )
                return

            # 2. 格式化 transcript（兼容 classify_scene 期望格式）
            transcript = [
                {"speaker": t.speaker, "text": t.text, "speaker_label": t.speaker_label or "Speaker_1"}
                for t in turns
            ]

            # 3. 获取 user_id（技能偏好查询用）
            session_result = await db.execute(
                select(DbSession.user_id).where(DbSession.id == uuid.UUID(session_id))
            )
            user_id_val = session_result.scalar_one_or_none()
            user_id     = str(user_id_val) if user_id_val else None

            # 4. 场景分类（sync，包装到线程）
            # 注：skills/router.py 未部署时，上方 from skills.router import 已抛 ImportError，此处不会执行
            _client = genai_sdk.Client(api_key=GEMINI_API_KEY)
            text_model = _client
            scene_result = await asyncio.to_thread(classify_scene, transcript, text_model)
            primary_scene = scene_result.get("primary_scene", "")
            logger.info(
                f"[TurnProc] 场景分类 session={session_id[:8]} "
                f"batch={batch_start}-{batch_end} scene={primary_scene}"
            )

            # 5. 技能匹配（async）
            matched_skills: list[dict] = await match_skills(
                scene_result=scene_result,
                db=db,
                transcript=transcript,
                user_id=user_id,
            )
            logger.info(
                f"[TurnProc] 技能匹配 session={session_id[:8]} "
                f"skills={[s.get('skill_id') for s in matched_skills[:3]]}"
            )

            # 6. 构建 matched_skills JSONB（写入 live_turns）
            skills_for_db = [
                {
                    "skill_id":   s.get("skill_id", ""),
                    "skill_name": s.get("skill_name", ""),
                    "category":   s.get("category", ""),
                    "confidence": round(float(s.get("score", 0)) / 100, 2),
                }
                for s in matched_skills
                if s.get("skill_id")
            ][:5]  # 最多 5 个

            # 7. 批量更新本批次所有 turns 的 matched_skills
            if skills_for_db:
                await db.execute(
                    update(LiveTurn)
                    .where(
                        LiveTurn.session_id == uuid.UUID(session_id),
                        LiveTurn.turn_index >= batch_start,
                        LiveTurn.turn_index <= batch_end,
                    )
                    .values(matched_skills=skills_for_db)
                )

            # 8. 构建 skill_cards（SSE payload，精简版）
            skill_cards = [
                {
                    "skill_id":   s["skill_id"],
                    "skill_name": s["skill_name"],
                    "category":   s["category"],
                    "confidence": s["confidence"],
                }
                for s in skills_for_db[:3]  # iOS 展示最多 3 个
            ]

            # 9. 写 live_events（SSE H-1 重放）
            payload = {
                "type":          "analysis_ready",
                "skill_cards":   skill_cards,
                "primary_scene": primary_scene,
                "turn_range":    [batch_start, batch_end],
            }
            live_event = LiveEvent(
                session_id=uuid.UUID(session_id),
                event_type="analysis_ready",
                payload=payload,
            )
            db.add(live_event)
            await db.flush()
            event_id = live_event.id
            await db.commit()

            # 10. 推送 SSE
            live_pubsub.push_event(
                session_id=session_id,
                event_id=event_id,
                event_type="analysis_ready",
                payload=payload,
            )
            logger.info(
                f"[TurnProc] 异步分析完成 session={session_id[:8]} "
                f"batch={batch_start}-{batch_end} scene={primary_scene} "
                f"skills={len(skill_cards)}"
            )

    except ImportError:
        logger.error("[TurnProc] skills.router 未找到，异步分析跳过")
    except Exception as exc:
        logger.error(
            f"[TurnProc] 异步分析异常 session={session_id[:8]} "
            f"batch={batch_start}-{batch_end}: {exc}",
            exc_info=True,
        )
