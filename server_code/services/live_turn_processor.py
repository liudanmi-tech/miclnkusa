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
    LiveSpeakerMapping,
    Profile,
    Skill,
)
from services import live_pubsub
from services import live_segment_manager

logger = logging.getLogger(__name__)

# ── 常量 ──────────────────────────────────────────────────────────────────────

QUICK_TRIGGER_SECS   = 20.0      # 距上次超过 N 秒则触发（超时兜底，防长时间沉默漏触发）
ASYNC_TRIGGER_TURNS  = 10        # 每累积 N turn 触发异步分析（turn_index = 9,19,29...）

# 自适应触发间隔：urgency_level → turn 间隔
# 0=平静(4条)，1=警觉(3条)，2=危急(1条，每条都触发)
URGENCY_INTERVALS: dict[int, int] = {0: 4, 1: 3, 2: 1}

# 快速建议：轻量模型，< 2s 目标
GEMINI_FLASH_MODEL = os.getenv("GEMINI_FLASH_MODEL", "gemini-2.0-flash")
# 异步分析：高质量模型，场景分类 + 技能匹配
GEMINI_TEXT_MODEL  = os.getenv("GEMINI_TEXT_MODEL",  "gemini-2.5-flash")
GEMINI_API_KEY     = os.getenv("GEMINI_API_KEY", "")

# 技能卡片 advice/reminder 生成 prompt（与异步分析同批次，单次调用）
_SKILL_ADVICE_PROMPT = """\
以下是最近的对话记录（user=我，other=对方）：

{transcript}

针对以下匹配的职场技能，为「我（user）」生成具体的行动建议和注意提醒：
{skills_list}

以 JSON 数组输出，每个技能对应一个对象（顺序与上方一致）：
[{{"skill_id":"...","advice":"针对本次对话的具体建议（30字内）","reminder":"需要注意的风险或提醒（20字内）"}}]

只输出 JSON 数组，不含其他内容。"""

# 快速建议 prompt（严格要求单行 JSON，< 2s）
# {context_section} = Layer 2 running_context 前缀（有则注入，无则空串）
# {speaker_section} = 已知说话人角色（声纹匹配后注入，无则空串）
_QUICK_PROMPT = """\
你是实时对话辅助助手。{context_section}{speaker_section}以下是对话最近几句（user=我）：

{transcript}

请分析并输出严格单行JSON，不含其他内容：
{{"relevant_to_user":true,"urgency_level":0,"speech_act":"neutral","text":"建议（20字内）","emotion_tag":"情绪标签（含emoji）","skill_hint":"技能关键词"}}

字段说明：
- relevant_to_user: 这段对话是否与 user 直接相关（true=相关，false=背景噪音/其他人间的对话与user无关）
- urgency_level: 0=平静 1=警觉（对方在追问/施压） 2=危急（质疑/命令我，需立即应对）
- speech_act: neutral / question_to_me / challenge / command / affirm
- text: 给 user 的沟通建议（20字内），relevant_to_user=false 时输出空串"""

# ── 内存状态（per session，服务重启自动重置）──────────────────────────────────

_state: Dict[str, Dict[str, Any]] = {}


def _get_state(session_id: str) -> Dict[str, Any]:
    if session_id not in _state:
        _state[session_id] = {
            "last_quick_turn_index": -URGENCY_INTERVALS[0],  # 首条 turn 即触发（用平静 interval 初始化）
            "last_quick_mono": 0.0,
            "last_urgency_level": 0,   # 当前模式：0=平静 / 1=警觉 / 2=危急
            "calm_streak": 0,          # 连续 urgency=0 次数（用于降级：需连续 3 次）
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

    # ── 快速路径检查（动态 interval，基于上次 urgency_level）─────────────
    last_urgency = state.get("last_urgency_level", 0)
    interval     = URGENCY_INTERVALS.get(last_urgency, 4)
    turns_since  = turn_index - state["last_quick_turn_index"]
    secs_since   = now - state["last_quick_mono"]

    logger.debug(
        f"[DIAG-ADAPT-1] on_turn_received session={session_id[:8]} "
        f"turn={turn_index} urgency={last_urgency} interval={interval} "
        f"turns_since={turns_since} secs_since={secs_since:.1f}s"
    )

    if turns_since >= interval or secs_since >= QUICK_TRIGGER_SECS:
        state["last_quick_turn_index"] = turn_index
        state["last_quick_mono"]       = now
        trigger_reason = "turns" if turns_since >= interval else "timeout"
        logger.info(
            f"[DIAG-ADAPT-2] 触发快速建议 session={session_id[:8]} "
            f"turn={turn_index} urgency={last_urgency} interval={interval} "
            f"reason={trigger_reason}"
        )
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
    含两阶段改进：
      Phase 1 — 自适应状态机：解析 urgency_level，更新 _state，下次触发用动态 interval
      Phase 2 — 说话人识别：查 live_speaker_mappings → profiles，真名注入 prompt
    写入 live_turns.suggestion + live_events（SSE 重放）并推 SSE suggestion。
    """
    try:
        async with AsyncSessionLocal() as db:
            # ── Step 1：取最近 8 条 turns ─────────────────────────────────
            result = await db.execute(
                select(LiveTurn)
                .where(LiveTurn.session_id == uuid.UUID(session_id))
                .order_by(LiveTurn.turn_index.desc())
                .limit(8)
            )
            turns = list(reversed(result.scalars().all()))
            if not turns:
                logger.debug(f"[TurnProc] 无 turn 数据，跳过 session={session_id[:8]}")
                return

            # ── Step 2：说话人三层识别（Phase 2）────────────────────────────
            # 第一层：声纹已匹配 → 真名 + 关系
            speaker_map: Dict[str, str] = {}  # speaker_label → display string
            try:
                mapping_rows = await db.execute(
                    select(LiveSpeakerMapping)
                    .where(LiveSpeakerMapping.session_id == uuid.UUID(session_id))
                )
                for m in mapping_rows.scalars().all():
                    if m.profile_id:
                        prof_row = await db.execute(
                            select(Profile).where(Profile.id == m.profile_id)
                        )
                        prof = prof_row.scalar_one_or_none()
                        if prof:
                            rel = prof.relationship_type or ""
                            display = f"{prof.name}（{rel}）" if rel else prof.name
                            speaker_map[m.speaker_label] = display
                            logger.info(
                                f"[DIAG-SPKR-1] 声纹已匹配 session={session_id[:8]} "
                                f"label={m.speaker_label} → {display}"
                            )
                if not speaker_map:
                    logger.debug(
                        f"[DIAG-SPKR-1] 无声纹匹配 session={session_id[:8]} "
                        f"turn={turn_index}，Gemini 凭内容推断"
                    )
            except Exception as spkr_exc:
                logger.warning(
                    f"[TurnProc] 说话人查询失败（非致命）session={session_id[:8]}: {spkr_exc}"
                )

            # 构建 speaker_section（注入 prompt）
            if speaker_map:
                desc_lines = "\n".join(
                    f"  {lbl} = {desc}" for lbl, desc in speaker_map.items()
                )
                speaker_section = f"已知说话人：\n{desc_lines}\n\n"
            else:
                speaker_section = ""

            # ── Step 3：格式化 transcript（使用真名替换 label）───────────────
            def _fmt_speaker(t: LiveTurn) -> str:
                """优先用声纹匹配真名，其次 user/other，最后 speaker_label"""
                lbl = t.speaker_label or ""
                if lbl and lbl in speaker_map:
                    return speaker_map[lbl]
                return "我（user）" if t.speaker == "user" else (lbl or t.speaker or "other")

            lines = "\n".join(
                f"{_fmt_speaker(t)}: {t.text}" for t in turns
            )

            # ── Step 4：注入 Layer 2（running_context）──────────────────────
            running_ctx = await live_segment_manager.get_running_context(session_id, db)
            context_section = (
                f"背景摘要（本段已有共识）：{running_ctx}\n\n"
                if running_ctx else ""
            )

            # ── Step 5：组装 Prompt ──────────────────────────────────────────
            prompt = _QUICK_PROMPT.format(
                transcript=lines,
                context_section=context_section,
                speaker_section=speaker_section,
            )

            # ── Step 6：调 Gemini Flash（< 2s）──────────────────────────────
            _client = genai_sdk.Client(api_key=GEMINI_API_KEY)
            resp = await asyncio.to_thread(
                _client.models.generate_content,
                model=GEMINI_FLASH_MODEL,
                contents=prompt,
            )
            raw = (resp.text or "").strip()

            # ── Step 7：解析 JSON（含新字段）────────────────────────────────
            relevant_to_user = True   # 默认 true：保守策略，防误过滤
            urgency_level    = 0
            speech_act       = "neutral"
            suggestion_text  = ""
            emotion_tag      = ""
            skill_hint       = ""
            try:
                start = raw.find("{")
                end   = raw.rfind("}") + 1
                if start >= 0 and end > start:
                    data = json.loads(raw[start:end])
                    relevant_to_user = bool(data.get("relevant_to_user", True))
                    urgency_level    = int(data.get("urgency_level", 0))
                    speech_act       = str(data.get("speech_act", "neutral")).strip()
                    suggestion_text  = str(data.get("text", "")).strip()
                    emotion_tag      = str(data.get("emotion_tag", "")).strip()
                    skill_hint       = str(data.get("skill_hint", "")).strip()
            except (json.JSONDecodeError, ValueError):
                suggestion_text = raw[:60] if raw else ""

            logger.info(
                f"[DIAG-ADAPT-3] Gemini 返回 session={session_id[:8]} turn={turn_index} "
                f"relevant={relevant_to_user} urgency={urgency_level} "
                f"speech_act={speech_act} text={suggestion_text[:20]!r}"
            )

            # ── Step 8：relevant_to_user 过滤────────────────────────────────
            # false = 背景噪音 / 与用户无关的对话 → 跳过建议生成，不更新状态机
            if not relevant_to_user:
                logger.info(
                    f"[DIAG-ADAPT-4] relevant_to_user=false，跳过 "
                    f"session={session_id[:8]} turn={turn_index}"
                    f"（噪音/与用户无关）"
                )
                return

            # ── Step 9：非对称状态机更新（Phase 1）──────────────────────────
            state      = _get_state(session_id)
            prev_urgency = state["last_urgency_level"]

            if urgency_level >= 1:
                # 升级：瞬时生效（1 次即触发）
                state["last_urgency_level"] = urgency_level
                state["calm_streak"]        = 0
                logger.info(
                    f"[DIAG-ADAPT-5] 模式升级 session={session_id[:8]} "
                    f"{prev_urgency}→{urgency_level}（瞬时，interval={URGENCY_INTERVALS[urgency_level]}）"
                )
            else:
                # urgency=0：需连续 3 次 calm 才降级
                state["calm_streak"] += 1
                if state["calm_streak"] >= 3 and prev_urgency > 0:
                    state["last_urgency_level"] = 0
                    logger.info(
                        f"[DIAG-ADAPT-5] 模式降级 session={session_id[:8]} "
                        f"{prev_urgency}→0（calm_streak={state['calm_streak']}，"
                        f"interval={URGENCY_INTERVALS[0]}）"
                    )
                else:
                    logger.debug(
                        f"[DIAG-ADAPT-5] 保持模式 session={session_id[:8]} "
                        f"urgency={prev_urgency} calm_streak={state['calm_streak']}"
                    )

            if not suggestion_text:
                logger.debug(
                    f"[TurnProc] 快速建议文本为空 session={session_id[:8]} "
                    f"turn={turn_index}（但状态机已更新）"
                )
                return

            # ── Step 10：写 DB（更新 suggestion 字段）───────────────────────
            await db.execute(
                update(LiveTurn)
                .where(
                    LiveTurn.session_id == uuid.UUID(session_id),
                    LiveTurn.turn_index == turn_index,
                )
                .values(suggestion=suggestion_text)
            )

            # ── Step 11：写 live_events（供 SSE H-1 重放）────────────────────
            payload = {
                "type":          "suggestion",
                "text":          suggestion_text,
                "emotion_tag":   emotion_tag,
                "skill_hint":    skill_hint,
                "turn_index":    turn_index,
                "urgency_level": urgency_level,   # Phase 1 新增
                "speech_act":    speech_act,      # Phase 1 新增
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

            # ── Step 12：推送 SSE ─────────────────────────────────────────────
            live_pubsub.push_event(
                session_id=session_id,
                event_id=event_id,
                event_type="suggestion",
                payload=payload,
            )
            logger.info(
                f"[TurnProc] 快速建议已推送 session={session_id[:8]} "
                f"turn={turn_index} urgency={urgency_level} "
                f"speech_act={speech_act} emotion={emotion_tag}"
            )

    except Exception as exc:
        logger.error(
            f"[TurnProc] 快速建议异常 session={session_id[:8]} turn={turn_index}: {exc}",
            exc_info=True,
        )


# ── 内置技能分类和匹配（skills.router 不可用时的 fallback）──────────────────────

async def _classify_scene_fallback(transcript: list, client) -> dict:
    """Gemini Flash 场景分类，自包含实现，不依赖 skills.router"""
    lines = "\n".join(
        f"{t.get('speaker', '?')}: {t.get('text', '')}" for t in transcript[-10:]
    )
    prompt = (
        "分析以下对话，识别场景类别。\n\n"
        f"对话：\n{lines}\n\n"
        "只输出JSON，不含其他内容：\n"
        '{"primary_scene":"workplace","confidence":0.8}\n'
        "primary_scene 取值：workplace / family / education / social / other"
    )
    resp = await asyncio.to_thread(
        client.models.generate_content,
        model=GEMINI_FLASH_MODEL,
        contents=prompt,
    )
    raw = (resp.text or "").strip()
    try:
        s = raw.find("{")
        e = raw.rfind("}") + 1
        if s >= 0 and e > s:
            return json.loads(raw[s:e])
    except Exception:
        pass
    return {"primary_scene": "workplace", "confidence": 0.6}


async def _match_skills_fallback(
    scene_result: dict,
    transcript: list,
    db,
) -> list:
    """查 skills 表 + Gemini Flash 匹配 top-3 技能，自包含实现，不依赖 skills.router"""
    primary_scene = scene_result.get("primary_scene", "workplace")

    # 1. 从 DB 取已启用技能（最多 20 个）
    skills_result = await db.execute(
        select(Skill)
        .where(Skill.enabled == True)
        .order_by(Skill.priority.desc())
        .limit(20)
    )
    skills = skills_result.scalars().all()
    if not skills:
        logger.warning("[TurnProc] skills 表为空，跳过技能匹配")
        return []

    # 2. Gemini Flash 匹配
    skills_list = "\n".join(
        f"{i+1}. skill_id={s.skill_id} name={s.name} category={s.category}"
        + (f" desc={s.description[:60]}" if s.description else "")
        for i, s in enumerate(skills)
    )
    lines = "\n".join(
        f"{t.get('speaker', '?')}: {t.get('text', '')}" for t in transcript
    )
    prompt = (
        f"对话场景={primary_scene}，以下是最近对话：\n{lines}\n\n"
        f"从以下技能中选出最匹配的3个（按相关性排序）：\n{skills_list}\n\n"
        "只输出JSON数组，不含其他内容：\n"
        '[{"skill_id":"...","skill_name":"...","category":"...","score":85}]'
    )
    _client = genai_sdk.Client(api_key=GEMINI_API_KEY)
    resp = await asyncio.to_thread(
        _client.models.generate_content,
        model=GEMINI_FLASH_MODEL,
        contents=prompt,
    )
    raw = (resp.text or "").strip()
    try:
        s = raw.find("[")
        e = raw.rfind("]") + 1
        if s >= 0 and e > s:
            matched = json.loads(raw[s:e])
            skill_map = {sk.skill_id: sk for sk in skills}
            for m in matched:
                sid = m.get("skill_id", "")
                if sid in skill_map:
                    sk = skill_map[sid]
                    m.setdefault("skill_name", sk.name)
                    m.setdefault("category", sk.category)
            return matched[:3]
    except Exception:
        pass
    return []


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
    # 优先使用 skills.router（生产环境），不可用时 fallback 到内置实现
    try:
        from skills.router import classify_scene as _classify_fn
        from skills.router import match_skills as _match_fn
    except ImportError:
        logger.warning("[TurnProc] skills.router 不可用，使用内置技能匹配")
        _classify_fn = None
        _match_fn = None

    try:
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

            # 4. 场景分类
            _client = genai_sdk.Client(api_key=GEMINI_API_KEY)
            if _classify_fn is not None:
                scene_result = await asyncio.to_thread(_classify_fn, transcript, _client)
            else:
                scene_result = await _classify_scene_fallback(transcript, _client)
            primary_scene = scene_result.get("primary_scene", "")
            logger.info(
                f"[TurnProc] 场景分类 session={session_id[:8]} "
                f"batch={batch_start}-{batch_end} scene={primary_scene}"
            )

            # 5. 技能匹配
            if _match_fn is not None:
                matched_skills: list[dict] = await _match_fn(
                    scene_result=scene_result,
                    db=db,
                    transcript=transcript,
                    user_id=user_id,
                )
            else:
                matched_skills = await _match_skills_fallback(scene_result, transcript, db)
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
                    "confidence": round(float(s.get("score") or 0) / 100, 2),
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

            # 8. 为 skill_cards 生成 advice / reminder（单次 Gemini 调用）
            advice_map: dict[str, dict] = {}
            top_skills = skills_for_db[:3]
            if top_skills:
                try:
                    skills_list = "\n".join(
                        f"{i+1}. skill_id={s['skill_id']} name={s['skill_name']} category={s['category']}"
                        for i, s in enumerate(top_skills)
                    )
                    advice_prompt = _SKILL_ADVICE_PROMPT.format(
                        transcript="\n".join(f"{t.speaker}: {t.text}" for t in turns),
                        skills_list=skills_list,
                    )
                    advice_client = genai_sdk.Client(api_key=GEMINI_API_KEY)
                    advice_resp = await asyncio.to_thread(
                        advice_client.models.generate_content,
                        model=GEMINI_FLASH_MODEL,
                        contents=advice_prompt,
                    )
                    advice_raw = (advice_resp.text or "").strip()
                    # 提取 JSON 数组
                    arr_start = advice_raw.find("[")
                    arr_end   = advice_raw.rfind("]") + 1
                    if arr_start >= 0 and arr_end > arr_start:
                        for item in json.loads(advice_raw[arr_start:arr_end]):
                            sid = item.get("skill_id", "")
                            if sid:
                                advice_map[sid] = {
                                    "advice":   item.get("advice", ""),
                                    "reminder": item.get("reminder", ""),
                                }
                except Exception as adv_exc:
                    logger.warning(f"[TurnProc] advice 生成失败 session={session_id[:8]}: {adv_exc}")

            # 9. 构建 skill_cards（SSE payload，含 advice / reminder）
            skill_cards = [
                {
                    "skill_id":   s["skill_id"],
                    "skill_name": s["skill_name"],
                    "category":   s["category"],
                    "confidence": s["confidence"],
                    "advice":     advice_map.get(s["skill_id"], {}).get("advice", ""),
                    "reminder":   advice_map.get(s["skill_id"], {}).get("reminder", ""),
                }
                for s in top_skills
            ]

            # 10. 写 live_events（SSE H-1 重放）
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

            # 11. 推送 SSE
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

    except Exception as exc:
        logger.error(
            f"[TurnProc] 异步分析异常 session={session_id[:8]} "
            f"batch={batch_start}-{batch_end}: {exc}",
            exc_info=True,
        )
