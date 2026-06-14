"""
Live Mode — Session 管理 API
对应架构文档 Module A + Module F（Speaker 确认）

端点列表：
  POST   /api/v1/live/sessions                          创建实时录音 Session
  POST   /api/v1/live/sessions/{id}/end                 结束录音，触发后台处理
  GET    /api/v1/live/sessions/{id}/summary-status      轮询后处理进度
  POST   /api/v1/live/sessions/{id}/confirm-speaker     确认 Speaker 身份（情况 B）
  POST   /api/v1/live/sessions/{id}/update-speaker      修改 Speaker 绑定（情况 A/B 修改）
  POST   /api/v1/live/sessions/{id}/voiceprint-intent   记录声纹录入意愿
"""
import asyncio
import json
import logging
import os
import sys
import uuid
from datetime import datetime, timezone, timedelta
from typing import Optional

import google.generativeai as genai
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select, func, update
from sqlalchemy.ext.asyncio import AsyncSession

from auth.jwt_handler import get_current_user_id
from database.connection import get_db, AsyncSessionLocal
from database.models import (
    Session as DbSession,
    LiveSegment,
    LiveTurn,
    LiveSpeakerMapping,
    LiveSummaryTask,
    Profile,
    StrategyAnalysis,
)

logger = logging.getLogger(__name__)

# ── Step 9 后处理常量 ──────────────────────────────────────────────────────────
_GEMINI_FLASH_MODEL = os.getenv("GEMINI_FLASH_MODEL", "gemini-3-flash-preview")
_GEMINI_API_KEY     = os.getenv("GEMINI_API_KEY", "")

_SUMMARY_PROMPT = """\
以下是本次录音各阶段的摘要，请生成整体总结：

{contexts}

只输出 JSON，不含其他内容：
{{"card_title":"30字以内的标题","summary":"200字左右的整体总结，包含主要话题、关键决策、后续行动项"}}"""

router = APIRouter(prefix="/api/v1/live", tags=["live-sessions"])

# ──────────────────────────────────────────────────────────────────────────────
# 常量
# ──────────────────────────────────────────────────────────────────────────────
WS_DISCONNECT_ABANDON_MINUTES = 2    # WS 断连超过 2 分钟 → 孤儿 Session 废弃
SESSION_STALE_HOURS = 1              # 活跃超过 1 小时无 WS → 定时扫描废弃


# ──────────────────────────────────────────────────────────────────────────────
# 辅助函数
# ──────────────────────────────────────────────────────────────────────────────

async def _verify_session_owner(
    session_id: str,
    user_id: str,
    db: AsyncSession,
) -> DbSession:
    """校验 session 归属，返回 session 对象；不归属则 403，不存在则 404"""
    result = await db.execute(
        select(DbSession).where(DbSession.id == uuid.UUID(session_id))
    )
    session = result.scalar_one_or_none()
    if session is None:
        raise HTTPException(status_code=404, detail="Session 不存在")
    if str(session.user_id) != user_id:
        raise HTTPException(status_code=403, detail="无权操作该 Session")
    return session


async def _get_active_live_session(user_id: str, db: AsyncSession) -> Optional[DbSession]:
    """查询用户当前活跃的 Live Session（最新一条）"""
    result = await db.execute(
        select(DbSession)
        .where(
            DbSession.user_id == uuid.UUID(user_id),
            DbSession.session_type == "live",
            DbSession.status == "active",
        )
        .order_by(DbSession.created_at.desc())
        .limit(1)
    )
    return result.scalar_one_or_none()


async def _abandon_session(session: DbSession, reason: str, db: AsyncSession) -> None:
    """废弃孤儿 Session：更新状态，若有 ≥5 条 turns 触发后台处理"""
    now = datetime.now(timezone.utc)
    session.status = "abandoned"
    session.ended_at = now
    session.abandon_reason = reason
    session.summary_status = "processing"
    session.image_status = "processing"
    session.skills_status = "processing"
    await db.flush()

    # 统计 turns 数量
    count_result = await db.execute(
        select(func.count()).where(LiveTurn.session_id == session.id)
    )
    turn_count = count_result.scalar() or 0

    if turn_count >= 5:
        # 触发后台处理（与正常 end 相同的流程）
        task_record = LiveSummaryTask(
            session_id=session.id,
            status="pending",
        )
        db.add(task_record)
        await db.flush()
        logger.info(f"[Live] 孤儿 Session {session.id} 已废弃，{turn_count} turns，触发后台处理")
        asyncio.create_task(_run_post_processing(str(session.id)))
    else:
        logger.info(f"[Live] 孤儿 Session {session.id} 已废弃，{turn_count} turns < 5，跳过后台处理")


async def _run_post_processing(session_id: str) -> None:
    """
    录音结束后三项并行任务（架构文档 Section 11.3）
    Task 1：Summary 汇总 → card_title + live_summary → summary_status = "completed"
    Task 2：场景图片生成（复用 generate_scene_images，max=5 张，失败跳过）
    Task 3：技能分类整理（按 Segment 分组 → live_segments.skill_results）
    """
    logger.info(f"[Live] 后台处理开始 session_id={session_id}")

    # 预创建 StrategyAnalysis 占位记录（幂等），确保 Task2 generate_scene_images 能写入 scene_images
    try:
        async with AsyncSessionLocal() as db:
            existing_sa = await db.execute(
                select(StrategyAnalysis).where(StrategyAnalysis.session_id == uuid.UUID(session_id))
            )
            if existing_sa.scalar_one_or_none() is None:
                db.add(StrategyAnalysis(
                    session_id=uuid.UUID(session_id),
                    visual_data=[],
                    strategies=[],
                ))
                await db.commit()
                logger.info(f"[Live] 预创建 StrategyAnalysis session={session_id}")
    except Exception as exc:
        logger.error(f"[Live] 预创建 StrategyAnalysis 失败 session={session_id}: {exc}", exc_info=True)

    results = await asyncio.gather(
        _task1_summary(session_id),
        _task2_images(session_id),
        _task3_skills(session_id),
        return_exceptions=True,
    )
    for i, r in enumerate(results, 1):
        if isinstance(r, Exception):
            logger.error(f"[Live] Task{i} 顶层异常 session={session_id}: {r}", exc_info=r)
    logger.info(f"[Live] 后台处理完成 session_id={session_id}")


# ── Task 1：Summary 汇总 ───────────────────────────────────────────────────────

async def _task1_summary(session_id: str) -> None:
    """
    汇总各 Segment running_context → Gemini Flash → card_title + live_summary
    完成后 summary_status = "completed"；失败则 = "failed"
    """
    try:
        async with AsyncSessionLocal() as db:
            # 1. 读所有 Segment（按时序）
            segs_result = await db.execute(
                select(LiveSegment)
                .where(LiveSegment.session_id == uuid.UUID(session_id))
                .order_by(LiveSegment.segment_index.asc())
            )
            segments = segs_result.scalars().all()

            context_parts = [
                f"[阶段 {seg.segment_index + 1}] {seg.running_context}"
                for seg in segments
                if seg.running_context
            ]

            # 回退：对话太短未触发 Task A，直接读原始 turns
            if not context_parts:
                turns_result = await db.execute(
                    select(LiveTurn)
                    .where(LiveTurn.session_id == uuid.UUID(session_id))
                    .order_by(LiveTurn.turn_index.asc())
                    .limit(40)
                )
                turns = turns_result.scalars().all()
                if turns:
                    context_parts = ["\n".join(f"{t.speaker}: {t.text}" for t in turns)]

            # 无内容：直接标记完成给默认标题
            if not context_parts:
                await db.execute(
                    update(DbSession)
                    .where(DbSession.id == uuid.UUID(session_id))
                    .values(card_title="Live 对话", summary_status="completed")
                )
                await db.commit()
                return

            # 2. 调 Gemini Flash
            prompt = _SUMMARY_PROMPT.format(contexts="\n\n".join(context_parts))
            genai.configure(api_key=_GEMINI_API_KEY)
            model = genai.GenerativeModel(_GEMINI_FLASH_MODEL)
            resp = await asyncio.to_thread(model.generate_content, prompt)
            raw = (resp.text or "").strip()

            # 3. 解析 JSON
            card_title   = "Live 对话"
            live_summary = ""
            try:
                start = raw.find("{")
                end   = raw.rfind("}") + 1
                if start >= 0 and end > start:
                    data = json.loads(raw[start:end])
                    card_title   = (data.get("card_title") or "Live 对话").strip()[:30]
                    live_summary = (data.get("summary")    or "").strip()[:400]
            except (json.JSONDecodeError, ValueError):
                pass

            # 4. 写入
            await db.execute(
                update(DbSession)
                .where(DbSession.id == uuid.UUID(session_id))
                .values(
                    card_title=card_title,
                    live_summary=live_summary,
                    summary_status="completed",
                )
            )
            await db.commit()
            logger.info(f"[Live] Task1 完成 session={session_id} title={card_title}")

    except Exception as exc:
        logger.error(f"[Live] Task1 Summary 异常 session={session_id}: {exc}", exc_info=True)
        try:
            async with AsyncSessionLocal() as db:
                await db.execute(
                    update(DbSession)
                    .where(DbSession.id == uuid.UUID(session_id))
                    .values(summary_status="failed")
                )
                await db.commit()
        except Exception:
            pass


# ── Task 2：场景图片生成 ──────────────────────────────────────────────────────

async def _task2_images(session_id: str) -> None:
    """
    调用 generate_scene_images() 生成场景图（Live Mode，max=5 张）。
    generate_image_fn 从 main 模块动态获取，不可用时跳过。
    """
    try:
        main_mod = sys.modules.get("main")
        if main_mod is None:
            logger.warning("[Live] Task2 跳过：main 模块未加载")
            return

        generate_image_fn      = getattr(main_mod, "generate_image_from_prompt", None)
        get_profile_refs_fn    = getattr(main_mod, "_get_profile_reference_images", None)
        fetch_profile_image_fn = getattr(main_mod, "_fetch_profile_image_from_oss", None)

        if generate_image_fn is None:
            logger.warning("[Live] Task2 跳过：generate_image_from_prompt 未找到")
            return

        from scene_image_generator import generate_scene_images
        from utils.user_preferences import get_user_image_style

        async with AsyncSessionLocal() as db:
            sess_result = await db.execute(
                select(DbSession).where(DbSession.id == uuid.UUID(session_id))
            )
            session = sess_result.scalar_one_or_none()
            if session is None:
                return
            user_id = str(session.user_id)

            # 组装 transcript（is_me = speaker == "user"）
            turns_result = await db.execute(
                select(LiveTurn)
                .where(LiveTurn.session_id == uuid.UUID(session_id))
                .order_by(LiveTurn.turn_index.asc())
            )
            turns = turns_result.scalars().all()
            if not turns:
                return

            transcript = [
                {
                    "text":    t.text,
                    "is_me":   t.speaker == "user",
                    "speaker": t.speaker_label or t.speaker,
                }
                for t in turns
            ]

            # 取 SpeakerMapping（label → profile_id）
            maps_result = await db.execute(
                select(LiveSpeakerMapping).where(
                    LiveSpeakerMapping.session_id == uuid.UUID(session_id)
                )
            )
            speaker_mapping = {
                m.speaker_label: str(m.profile_id)
                for m in maps_result.scalars().all()
                if m.profile_id
            }

        image_style = get_user_image_style(user_id)
        await generate_scene_images(
            transcript=transcript,
            style_key=image_style,
            session_id=session_id,
            user_id=user_id,
            gemini_flash_model=_GEMINI_FLASH_MODEL,
            generate_image_fn=generate_image_fn,
            get_profile_refs_fn=get_profile_refs_fn,
            speaker_mapping=speaker_mapping,
            fetch_profile_image_fn=fetch_profile_image_fn,
            max_images=5,
        )
        logger.info(f"[Live] Task2 图片生成完成 session={session_id}")

    except Exception as exc:
        logger.error(f"[Live] Task2 图片生成异常 session={session_id}: {exc}", exc_info=True)


# ── Task 3：技能分类整理 ──────────────────────────────────────────────────────

async def _task3_skills(session_id: str) -> None:
    """
    按 Segment 分组已有 matched_skills（实时阶段已写入），写入 live_segments.skill_results。
    不重新分析，仅做去重 + 整理。完成后 skills_status = "completed"。
    """
    try:
        async with AsyncSessionLocal() as db:
            segs_result = await db.execute(
                select(LiveSegment)
                .where(LiveSegment.session_id == uuid.UUID(session_id))
                .order_by(LiveSegment.segment_index.asc())
            )
            segments = segs_result.scalars().all()

            # 跨 Segment 全局去重，用于写入 strategy_analysis.skill_cards
            all_best: dict[str, dict] = {}

            for segment in segments:
                # 取该 Segment 有 matched_skills 的 turns
                turns_result = await db.execute(
                    select(LiveTurn)
                    .where(
                        LiveTurn.segment_id == segment.id,
                        LiveTurn.matched_skills.isnot(None),
                    )
                    .order_by(LiveTurn.turn_index.asc())
                )
                turns = turns_result.scalars().all()

                # 按 skill_id 去重，保留最高 confidence
                best: dict[str, dict] = {}
                for turn in turns:
                    for skill in (turn.matched_skills or []):
                        sid = skill.get("skill_id", "")
                        if not sid:
                            continue
                        if sid not in best or skill.get("confidence", 0) > best[sid].get("confidence", 0):
                            best[sid] = skill
                        if sid not in all_best or skill.get("confidence", 0) > all_best[sid].get("confidence", 0):
                            all_best[sid] = skill

                skill_results = [
                    {
                        "skill_id":   s.get("skill_id", ""),
                        "skill_name": s.get("skill_name", ""),
                        "category":   s.get("category", ""),
                        "confidence": s.get("confidence", 0),
                    }
                    for s in list(best.values())[:5]
                    if s.get("skill_id")
                ]

                # scene_title：取 running_context 首句（≤30字）
                scene_title = ""
                if segment.running_context:
                    scene_title = segment.running_context.split("\n")[0].strip()[:30]
                if not scene_title:
                    scene_title = f"对话阶段 {segment.segment_index + 1}"

                await db.execute(
                    update(LiveSegment)
                    .where(LiveSegment.id == segment.id)
                    .values(skill_results=skill_results, scene_title=scene_title)
                )

            # 将全局技能写入 strategy_analysis.skill_cards（供 detail 页技能分类展示）
            sa_result = await db.execute(
                select(StrategyAnalysis).where(StrategyAnalysis.session_id == uuid.UUID(session_id))
            )
            sa = sa_result.scalar_one_or_none()
            if sa is not None and not sa.skill_cards:
                sa.skill_cards = [
                    {
                        "skill_id":     s.get("skill_id", ""),
                        "skill_name":   s.get("skill_name", ""),
                        "content_type": "strategy",
                        "category":     s.get("category", ""),
                    }
                    for s in all_best.values()
                    if s.get("skill_id")
                ]
                logger.info(f"[Live] Task3 写入 skill_cards={len(sa.skill_cards)} session={session_id}")

            await db.execute(
                update(DbSession)
                .where(DbSession.id == uuid.UUID(session_id))
                .values(skills_status="completed")
            )
            await db.commit()
            logger.info(
                f"[Live] Task3 技能分类完成 session={session_id} segments={len(segments)}"
            )

    except Exception as exc:
        logger.error(f"[Live] Task3 技能分类异常 session={session_id}: {exc}", exc_info=True)


# ──────────────────────────────────────────────────────────────────────────────
# Pydantic Schemas
# ──────────────────────────────────────────────────────────────────────────────

class CreateSessionRequest(BaseModel):
    title: Optional[str] = None     # 可选，不传则后续由 Gemini 生成


class EndSessionResponse(BaseModel):
    session_id: str
    session_type: str
    total_turns: int
    duration_seconds: Optional[int]
    summary_status: str
    image_status: str
    skills_status: str
    speaker_mappings: list[SpeakerMappingItem] = []  # Step 8 Speaker 确认 UI 数据


class SummaryStatusResponse(BaseModel):
    summary_status: str             # processing | completed | failed
    image_status: str               # processing | partial | completed | failed
    skills_status: str              # processing | completed
    card_title: Optional[str]
    summary: Optional[str]
    cover_image_url: Optional[str]
    total_images_expected: int
    total_images_completed: int
    total_images_failed: int


class ConfirmSpeakerRequest(BaseModel):
    speaker_label: str              # 'Speaker_1'
    profile_id: str                 # UUID of existing profile


class UpdateSpeakerRequest(BaseModel):
    speaker_label: str
    old_profile_id: Optional[str] = None
    new_profile_id: str


class VoiceprintIntentRequest(BaseModel):
    speaker_label: str
    profile_id: str
    intent: bool = True


class SpeakerMappingItem(BaseModel):
    speaker_label: str
    profile_id: Optional[str] = None
    profile_name: Optional[str] = None
    confidence: Optional[float] = None
    method: Optional[str] = None
    sample_texts: list[str] = []


# ──────────────────────────────────────────────────────────────────────────────
# POST /api/v1/live/sessions — 创建 Live Session
# ──────────────────────────────────────────────────────────────────────────────

@router.post("/sessions", status_code=201)
async def create_live_session(
    body: CreateSessionRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """
    创建新的 Live Mode 录音 Session。

    H-3 孤儿 Session 处理：
    - 如有活跃 Session 且 WS 已断连 >2min → 废弃旧 Session，创建新的
    - 如有活跃 Session 且 WS 仍连接 → 返回 409
    """
    now = datetime.now(timezone.utc)

    existing = await _get_active_live_session(user_id, db)
    if existing is not None:
        if existing.ws_disconnected_at is not None:
            disconnect_duration = (now - existing.ws_disconnected_at.replace(tzinfo=timezone.utc)).total_seconds()
            if disconnect_duration > WS_DISCONNECT_ABANDON_MINUTES * 60:
                # 孤儿 Session：WS 断连已超时，废弃它
                await _abandon_session(existing, reason="new_session", db=db)
            else:
                raise HTTPException(
                    status_code=409,
                    detail=f"已有活跃的 Live Session（WS 断连 {int(disconnect_duration)}s，未超过 {WS_DISCONNECT_ABANDON_MINUTES*60}s 阈值）",
                )
        else:
            # WS 仍连接（ws_disconnected_at 为 None），不允许并发
            raise HTTPException(
                status_code=409,
                detail="已有活跃的 Live Session，请先结束当前录音",
            )

    # 创建新 Session
    session = DbSession(
        user_id=uuid.UUID(user_id),
        title=body.title or "实时录音",
        session_type="live",
        status="active",
        start_time=now,
        summary_status="processing",
        image_status="processing",
        skills_status="processing",
        total_images_expected=0,
        total_images_completed=0,
        total_images_failed=0,
    )
    db.add(session)
    await db.flush()  # 获取 session.id

    # 创建初始 Segment（segment_index=0）
    first_segment = LiveSegment(
        session_id=session.id,
        segment_index=0,
        start_turn_index=0,
        status="active",
    )
    db.add(first_segment)
    await db.commit()
    await db.refresh(session)

    logger.info(f"[Live] 创建 Session user={user_id[:8]} session={session.id}")

    return {
        "session_id": str(session.id),
        "session_type": "live",
        "status": "active",
        "created_at": session.created_at.isoformat() if session.created_at else None,
    }


# ──────────────────────────────────────────────────────────────────────────────
# POST /api/v1/live/sessions/{id}/end — 结束录音
# ──────────────────────────────────────────────────────────────────────────────

@router.post("/sessions/{session_id}/end")
async def end_live_session(
    session_id: str,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """
    结束 Live Mode 录音：
    1. 更新 session status → 'completed'，记录 ended_at
    2. 关闭所有活跃 Segment
    3. 统计 turns 数量和录音时长
    4. 创建 live_summary_tasks 记录
    5. Fire-and-forget 触发三项后台任务（Section 11.3）
    """
    session = await _verify_session_owner(session_id, user_id, db)

    if session.session_type != "live":
        raise HTTPException(status_code=400, detail="该 Session 不是 Live Mode 录音")
    if session.status not in ("active", "abandoned"):
        raise HTTPException(status_code=400, detail=f"Session 状态为 '{session.status}'，无法结束")

    now = datetime.now(timezone.utc)

    # 关闭所有活跃 Segment
    active_segs_result = await db.execute(
        select(LiveSegment).where(
            LiveSegment.session_id == session.id,
            LiveSegment.status == "active",
        )
    )
    for seg in active_segs_result.scalars().all():
        # 取该 Segment 最后一条 turn 的 turn_index
        last_turn = await db.execute(
            select(LiveTurn.turn_index)
            .where(LiveTurn.segment_id == seg.id)
            .order_by(LiveTurn.turn_index.desc())
            .limit(1)
        )
        last_idx = last_turn.scalar_one_or_none()
        seg.status = "closed"
        seg.closed_at = now
        if last_idx is not None:
            seg.end_turn_index = last_idx

    # 统计 turns
    count_result = await db.execute(
        select(func.count()).where(LiveTurn.session_id == session.id)
    )
    total_turns = count_result.scalar() or 0

    # 计算时长（秒）
    duration_seconds = None
    if session.start_time:
        start = session.start_time
        if start.tzinfo is None:
            start = start.replace(tzinfo=timezone.utc)
        duration_seconds = int((now - start).total_seconds())

    # 更新 Session
    session.status = "completed"
    session.ended_at = now
    session.end_time = now
    session.duration = duration_seconds

    # 创建后台任务记录（幂等：已存在则跳过）
    existing_task = await db.execute(
        select(LiveSummaryTask).where(LiveSummaryTask.session_id == session.id)
    )
    if existing_task.scalar_one_or_none() is None:
        task_record = LiveSummaryTask(
            session_id=session.id,
            status="pending",
        )
        db.add(task_record)

    await db.commit()

    # ── 查询 Speaker Mappings（Step 8 Speaker 确认 UI 数据来源）──────────────
    mappings_result = await db.execute(
        select(LiveSpeakerMapping).where(
            LiveSpeakerMapping.session_id == session.id
        )
    )
    speaker_mappings_list: list[SpeakerMappingItem] = []
    for mapping in mappings_result.scalars().all():
        # 取最近 2 条代表性发言
        texts_result = await db.execute(
            select(LiveTurn.text)
            .where(
                LiveTurn.session_id == session.id,
                LiveTurn.speaker_label == mapping.speaker_label,
            )
            .order_by(LiveTurn.turn_index.desc())
            .limit(2)
        )
        sample_texts = list(reversed([row[0] for row in texts_result.all()]))
        # 查档案名称（LiveSpeakerMapping 无 .name 字段，需 JOIN profiles）
        profile_name = None
        if mapping.profile_id:
            name_result = await db.execute(
                select(Profile.name).where(Profile.id == mapping.profile_id)
            )
            profile_name = name_result.scalar_one_or_none()
        speaker_mappings_list.append(SpeakerMappingItem(
            speaker_label=mapping.speaker_label,
            profile_id=str(mapping.profile_id) if mapping.profile_id else None,
            profile_name=profile_name,
            confidence=mapping.confidence,
            method=mapping.method,
            sample_texts=sample_texts,
        ))

    # Fire-and-forget 后台处理
    asyncio.create_task(_run_post_processing(session_id))

    logger.info(
        f"[Live] 结束录音 session={session_id} turns={total_turns} "
        f"duration={duration_seconds}s speakers={len(speaker_mappings_list)}"
    )

    return EndSessionResponse(
        session_id=session_id,
        session_type="live",
        total_turns=total_turns,
        duration_seconds=duration_seconds,
        summary_status="processing",
        image_status="processing",
        skills_status="processing",
        speaker_mappings=speaker_mappings_list,
    )


# ──────────────────────────────────────────────────────────────────────────────
# GET /api/v1/live/sessions/{id}/summary-status — 轮询后处理进度
# ──────────────────────────────────────────────────────────────────────────────

@router.get("/sessions/{session_id}/summary-status", response_model=SummaryStatusResponse)
async def get_summary_status(
    session_id: str,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """iOS 每 4 秒轮询，summary_status=completed 时卡片变可点击"""
    session = await _verify_session_owner(session_id, user_id, db)

    if session.session_type != "live":
        raise HTTPException(status_code=400, detail="该 Session 不是 Live Mode 录音")

    return SummaryStatusResponse(
        summary_status=session.summary_status or "processing",
        image_status=session.image_status or "processing",
        skills_status=session.skills_status or "processing",
        card_title=session.card_title,
        summary=session.live_summary,
        cover_image_url=session.cover_image_url,
        total_images_expected=session.total_images_expected or 0,
        total_images_completed=session.total_images_completed or 0,
        total_images_failed=session.total_images_failed or 0,
    )


# ──────────────────────────────────────────────────────────────────────────────
# POST /api/v1/live/sessions/{id}/confirm-speaker — 确认 Speaker 身份
# ──────────────────────────────────────────────────────────────────────────────

@router.post("/sessions/{session_id}/confirm-speaker")
async def confirm_speaker(
    session_id: str,
    body: ConfirmSpeakerRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """
    情况 B：用户在 Step 2 弹窗确认 Speaker_X = 已有档案成员。
    confidence=1.0 + method='user_confirmed'，高置信度优先覆盖。
    """
    await _verify_session_owner(session_id, user_id, db)
    await _upsert_speaker_mapping(
        session_id=session_id,
        speaker_label=body.speaker_label,
        profile_id=body.profile_id,
        confidence=1.0,
        method="user_confirmed",
        db=db,
    )
    await db.commit()

    # 查询 profile 名字用于返回
    profile_result = await db.execute(
        select(Profile).where(Profile.id == uuid.UUID(body.profile_id))
    )
    profile = profile_result.scalar_one_or_none()

    logger.info(
        f"[Live] confirm-speaker session={session_id} "
        f"label={body.speaker_label} profile={body.profile_id}"
    )
    return {
        "success": True,
        "speaker_label": body.speaker_label,
        "profile_id": body.profile_id,
        "profile_name": profile.name if profile else None,
    }


# ──────────────────────────────────────────────────────────────────────────────
# POST /api/v1/live/sessions/{id}/update-speaker — 修改 Speaker 绑定
# ──────────────────────────────────────────────────────────────────────────────

@router.post("/sessions/{session_id}/update-speaker")
async def update_speaker(
    session_id: str,
    body: UpdateSpeakerRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """情况 A/B 修改：用户选择了不同的档案成员，强制覆盖（confidence=1.0）"""
    await _verify_session_owner(session_id, user_id, db)
    await _upsert_speaker_mapping(
        session_id=session_id,
        speaker_label=body.speaker_label,
        profile_id=body.new_profile_id,
        confidence=1.0,
        method="user_confirmed",
        db=db,
        force=True,  # 修改操作强制覆盖
    )
    await db.commit()

    profile_result = await db.execute(
        select(Profile).where(Profile.id == uuid.UUID(body.new_profile_id))
    )
    profile = profile_result.scalar_one_or_none()

    logger.info(
        f"[Live] update-speaker session={session_id} "
        f"label={body.speaker_label} new_profile={body.new_profile_id}"
    )
    return {
        "success": True,
        "speaker_label": body.speaker_label,
        "profile_id": body.new_profile_id,
        "profile_name": profile.name if profile else None,
    }


# ──────────────────────────────────────────────────────────────────────────────
# POST /api/v1/live/sessions/{id}/voiceprint-intent — 记录声纹录入意愿
# ──────────────────────────────────────────────────────────────────────────────

@router.post("/sessions/{session_id}/voiceprint-intent")
async def record_voiceprint_intent(
    session_id: str,
    body: VoiceprintIntentRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """
    记录用户的声纹录入意愿（点击「录入声纹」按钮）。
    实际声纹采集为未来功能，当前仅在 profiles 表写入 voiceprint_intent=True。
    """
    await _verify_session_owner(session_id, user_id, db)

    profile_result = await db.execute(
        select(Profile).where(
            Profile.id == uuid.UUID(body.profile_id),
            Profile.user_id == uuid.UUID(user_id),
        )
    )
    profile = profile_result.scalar_one_or_none()
    if profile is None:
        raise HTTPException(status_code=404, detail="档案不存在")

    profile.voiceprint_intent = body.intent
    profile.voiceprint_intent_at = datetime.now(timezone.utc)
    await db.commit()

    logger.info(
        f"[Live] voiceprint-intent session={session_id} "
        f"profile={body.profile_id} intent={body.intent}"
    )
    return {
        "success": True,
        "message": "声纹录入意愿已记录，后续可在档案页完成录入",
    }


# ──────────────────────────────────────────────────────────────────────────────
# 内部：SpeakerMapping Upsert（高置信度覆盖低置信度，M-2）
# ──────────────────────────────────────────────────────────────────────────────

async def _upsert_speaker_mapping(
    session_id: str,
    speaker_label: str,
    profile_id: str,
    confidence: float,
    method: str,
    db: AsyncSession,
    force: bool = False,
) -> None:
    """
    写入 live_speaker_mappings：
    - force=True：直接覆盖（用户主动修改）
    - force=False：仅当新 confidence >= 现有 confidence 时覆盖
    """
    result = await db.execute(
        select(LiveSpeakerMapping).where(
            LiveSpeakerMapping.session_id == uuid.UUID(session_id),
            LiveSpeakerMapping.speaker_label == speaker_label,
        )
    )
    existing = result.scalar_one_or_none()

    if existing is None:
        db.add(LiveSpeakerMapping(
            session_id=uuid.UUID(session_id),
            speaker_label=speaker_label,
            profile_id=uuid.UUID(profile_id),
            confidence=confidence,
            method=method,
        ))
    elif force or confidence >= existing.confidence:
        existing.profile_id = uuid.UUID(profile_id)
        existing.confidence = confidence
        existing.method = method
        existing.updated_at = datetime.now(timezone.utc)
    else:
        logger.debug(
            f"[Live] _upsert_speaker_mapping 跳过：新 confidence {confidence:.2f} "
            f"< 现有 {existing.confidence:.2f}"
        )
