"""
知识图谱服务（PostgreSQL KG）
替代 mem0 的结构化记忆存储，零语义漂移、精准人物隔离。

写入路径：
  save_kg_from_transcript() ← B-hook（录音分析完成后）
  save_kg_from_skills()     ← C-hook（策略生成完成后，记录技能）
  save_kg_from_chat()       ← AI 对话结束后

读取路径：
  get_ai_context_kg()        ← AI Assistant 上下文检索（替代 search_memory）
  get_profile_memories_kg()  ← 档案记忆页（替代 vector 搜索+过滤）
"""

import logging
import uuid as uuid_module
from datetime import date, datetime, timezone
from typing import Optional

from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, any_

from database.models import KgPerson, KgEvent, KgEventPerson, KgGoal, KgSkill

logger = logging.getLogger(__name__)


# ─── 写入：B-hook ──────────────────────────────────────────────────────────────

async def save_kg_from_transcript(
    content: str,
    user_id: str,
    session_id: str,
    profile_names: dict = None,   # {profile_id: name}，帮助 LLM 准确识别人物
) -> bool:
    """
    B-hook 调用：从录音对话内容提取人物/事件/目标，写入 PostgreSQL KG。
    fire-and-forget：调用方用 asyncio.create_task 包裹。
    """
    if not content or not content.strip():
        return False

    try:
        import asyncio
        from services.structured_memory import _call_gemini_extract

        # 把已知人物名注入 content，帮助 LLM 准确识别
        if profile_names:
            names_hint = "已知对话人物：" + "、".join(profile_names.values())
            enhanced = f"{names_hint}\n\n{content}"
        else:
            enhanced = content

        extracted = await asyncio.to_thread(_call_gemini_extract, enhanced, session_id)

        from database.connection import AsyncSessionLocal
        async with AsyncSessionLocal() as db:
            person_id_map = {}
            for p in (extracted or {}).get("persons", []):
                person = await _upsert_person(db, user_id, p)
                if person:
                    person_id_map[p.get("name", "")] = person.id

            for e in (extracted or {}).get("events", []):
                await _insert_event(db, user_id, e, session_id, person_id_map)

            for g in (extracted or {}).get("goals", []):
                await _insert_goal(db, user_id, g, session_id, person_id_map)

            await db.commit()

        logger.info(f"[KG] B-hook 完成 session={session_id} persons={len(person_id_map)}")
        return True

    except Exception as exc:
        logger.warning(f"[KG] B-hook 写入失败 session={session_id}: {exc}")
        return False


# ─── 写入：C-hook ──────────────────────────────────────────────────────────────

async def save_kg_from_skills(
    user_id: str,
    session_id: str,
    skill_results: list,        # [{"skill_id":..., "skill_name":..., "category":...}]
    person_names: list = None,  # 本次对话识别到的人物名
) -> bool:
    """
    C-hook 调用：记录本次会话匹配的技能 → kg_skills。
    skill_results 来自策略分析的 applied_skills 列表。
    """
    if not skill_results:
        return False

    try:
        from database.connection import AsyncSessionLocal
        async with AsyncSessionLocal() as db:
            person_ids = []
            if person_names:
                uid = uuid_module.UUID(user_id)
                for name in person_names:
                    r = await db.execute(
                        select(KgPerson).where(
                            KgPerson.user_id == uid,
                            KgPerson.name == name,
                        )
                    )
                    p = r.scalar_one_or_none()
                    if p:
                        person_ids.append(p.id)

            for skill in skill_results:
                db.add(KgSkill(
                    user_id=uuid_module.UUID(user_id),
                    session_id=uuid_module.UUID(session_id) if session_id else None,
                    skill_id=skill.get("skill_id", ""),
                    skill_name=skill.get("skill_name") or skill.get("name") or skill.get("skill_id", ""),
                    skill_category=skill.get("category", ""),
                    person_ids=person_ids or None,
                ))

            await db.commit()

        logger.info(f"[KG] C-hook 技能写入完成 session={session_id} count={len(skill_results)}")
        return True

    except Exception as exc:
        logger.warning(f"[KG] C-hook 技能写入失败 session={session_id}: {exc}")
        return False


# ─── 写入：AI 对话 ─────────────────────────────────────────────────────────────

async def save_kg_from_chat(
    content: str,
    user_id: str,
    session_id: str,
    skill_id: str = "",
    skill_name: str = "",
    skill_category: str = "",
) -> bool:
    """
    AI 对话结束后调用：
    1. Gemini 抽取人物/事件/目标 → 写入 KG
    2. 记录本轮使用的技能 → kg_skills
    """
    if not content or not content.strip():
        return False

    try:
        import asyncio
        from services.structured_memory import _call_gemini_extract

        extracted = await asyncio.to_thread(_call_gemini_extract, content, session_id)

        from database.connection import AsyncSessionLocal
        async with AsyncSessionLocal() as db:
            person_id_map = {}
            for p in (extracted or {}).get("persons", []):
                person = await _upsert_person(db, user_id, p)
                if person:
                    person_id_map[p.get("name", "")] = person.id

            for e in (extracted or {}).get("events", []):
                await _insert_event(db, user_id, e, session_id, person_id_map)

            for g in (extracted or {}).get("goals", []):
                await _insert_goal(db, user_id, g, session_id, person_id_map)

            # 记录技能使用
            if skill_id:
                db.add(KgSkill(
                    user_id=uuid_module.UUID(user_id),
                    session_id=uuid_module.UUID(session_id) if session_id else None,
                    skill_id=skill_id,
                    skill_name=skill_name,
                    skill_category=skill_category,
                    person_ids=list(person_id_map.values()) or None,
                ))

            await db.commit()

        logger.info(f"[KG] AI对话写入完成 session={session_id} skill={skill_id} persons={len(person_id_map)}")
        return True

    except Exception as exc:
        logger.warning(f"[KG] AI对话写入失败 session={session_id}: {exc}")
        return False


# ─── 读取：AI Assistant 上下文 ─────────────────────────────────────────────────

async def get_ai_context_kg(user_message: str, user_id: str, db: AsyncSession) -> str:
    """
    替代 search_memory()，从 PostgreSQL KG 构建 AI 上下文字符串。

    策略：
    1. 扫描 kg_persons 中的人名，检查是否出现在消息里（精准匹配，无 LLM 调用）
    2. 匹配到人物 → 查该人的事件/目标/技能，格式化为上下文块
    3. 无匹配 → 返回最近 5 条事件作为通用背景
    """
    try:
        uid = uuid_module.UUID(user_id)

        # 拿全部人物名（通常 < 50 条，内存操作极快）
        persons_r = await db.execute(select(KgPerson).where(KgPerson.user_id == uid))
        all_persons = persons_r.scalars().all()

        mentioned = [p for p in all_persons if p.name and p.name in user_message]

        context_parts = []
        for person in mentioned[:3]:
            block = await _format_person_block(db, person)
            if block:
                context_parts.append(block)

        if not context_parts:
            # 通用背景：最近事件
            recent_r = await db.execute(
                select(KgEvent)
                .where(KgEvent.user_id == uid)
                .order_by(KgEvent.created_at.desc())
                .limit(5)
            )
            for e in recent_r.scalars():
                context_parts.append(f"[{e.event_date or '近期'}] {e.summary}")

        return "\n\n".join(context_parts)

    except Exception as exc:
        logger.warning(f"[KG] get_ai_context_kg 失败: {exc}")
        return ""


# ─── 读取：档案记忆页 ──────────────────────────────────────────────────────────

async def get_profile_memories_kg(
    profile_name: str,
    user_id: str,
    db: AsyncSession,
    profile_id: Optional[str] = None,
) -> dict:
    """
    替代 vector 搜索 + 过滤，精准 SQL JOIN，人物隔离 100%。
    返回格式兼容现有 iOS ProfileMemoriesResponse（新增 skills 字段）。
    """
    try:
        uid = uuid_module.UUID(user_id)

        # 1. 查人物节点（先精确匹配名字，再按 speaker_mapping→session 链条 fallback）
        person_r = await db.execute(
            select(KgPerson).where(KgPerson.user_id == uid, KgPerson.name == profile_name)
        )
        person = person_r.scalar_one_or_none()

        if not person and profile_id:
            # Fallback: 按 profile_id 直接查（场景生成写入的链接）
            import uuid as _uuid_mod
            pid_uuid = _uuid_mod.UUID(profile_id)
            fb_r = await db.execute(
                select(KgPerson)
                .where(KgPerson.user_id == uid, KgPerson.profile_id == pid_uuid)
                .order_by(KgPerson.updated_at.desc())
            )
            person = fb_r.scalars().first()
            if person:
                logger.info(
                    f"[KG] memories fallback 命中: profile_id={profile_id} → kg_person={person.name}"
                )

        if not person:
            return _empty_response(profile_name)

        # 2. 关系概况
        relationship = []
        if person.rel_desc or person.rel_type:
            parts = [f"Relationship: {person.rel_desc or person.rel_type}"]
            if person.intimacy:
                parts.append(f"intimacy {person.intimacy}/10")
            if person.friction:
                parts.append(f"friction {person.friction}/10")
            if person.power:
                power_map = {"superior": "Superior", "equal": "Equal", "subordinate": "Subordinate"}
                parts.append(power_map.get(person.power, person.power))
            relationship.append({"content": ", ".join(parts), "type": "relationship",
                                  "date": None, "status": None})

        # 3. 事件列表（按日期降序）
        events_r = await db.execute(
            select(KgEvent)
            .join(KgEventPerson, KgEvent.id == KgEventPerson.event_id)
            .where(KgEventPerson.person_id == person.id)
            .order_by(KgEvent.event_date.desc(), KgEvent.created_at.desc())
            .limit(50)
        )
        events = [{"content": e.summary, "type": "event",
                   "date": e.event_date, "status": e.outcome}
                  for e in events_r.scalars()]

        # 4. 目标列表（进行中优先）
        goals_r = await db.execute(
            select(KgGoal)
            .where(KgGoal.person_id == person.id)
            .order_by(KgGoal.updated_at.desc())
        )
        goals = [{"content": g.description, "type": "goal",
                  "date": None, "status": g.status}
                 for g in goals_r.scalars()]
        goals.sort(key=lambda x: x["status"] != "in_progress")

        # 5. 技能列表（此档案对话中用过的技能）
        skills_r = await db.execute(
            select(KgSkill)
            .where(
                KgSkill.user_id == uid,
                person.id == any_(KgSkill.person_ids),
            )
            .order_by(KgSkill.applied_at.desc())
            .limit(10)
        )
        skills = [{"content": s.skill_name or s.skill_id, "type": "skill",
                   "date": s.applied_at.strftime("%Y-%m-%d") if s.applied_at else None,
                   "status": None}
                  for s in skills_r.scalars()]

        total = len(relationship) + len(events) + len(goals) + len(skills)

        return {
            "profile_name": profile_name,
            "relationship": relationship,
            "events": events,
            "goals": goals,
            "skills": skills,
            "other": [],
            "total": total,
        }

    except Exception as exc:
        logger.warning(f"[KG] get_profile_memories_kg 失败 name={profile_name}: {exc}")
        return _empty_response(profile_name)


# ─── 内部写入工具 ──────────────────────────────────────────────────────────────

_KG_AI_IDENTITY_NAMES = {"对话助手", "AI助手", "助手", "ai", "AI"}

async def _upsert_person(db: AsyncSession, user_id: str, p: dict) -> Optional[KgPerson]:
    """同名人物 → 更新（亲密度/摩擦值滑动平均），新人物 → 插入"""
    name = (p.get("name") or "").strip()
    if not name:
        return None
    # 过滤 AI 助手身份词，防止把 AI 自称写入 kg_persons 污染人物库
    if name in _KG_AI_IDENTITY_NAMES:
        return None

    uid = uuid_module.UUID(user_id)
    r = await db.execute(
        select(KgPerson).where(KgPerson.user_id == uid, KgPerson.name == name)
    )
    person = r.scalar_one_or_none()

    if person:
        # 亲密度/摩擦值：取历史与本次的平均，避免单次波动覆盖积累
        if p.get("intimacy"):
            old = person.intimacy or 5
            person.intimacy = round((old + int(p["intimacy"])) / 2)
        if p.get("friction"):
            old = person.friction or 5
            person.friction = round((old + int(p["friction"])) / 2)
        if p.get("relationship_desc") or p.get("relationship"):
            person.rel_desc = p.get("relationship_desc") or p.get("relationship")
        if p.get("power"):
            person.power = p["power"]
        person.updated_at = datetime.now(timezone.utc)
    else:
        person = KgPerson(
            user_id=uid,
            name=name,
            rel_type=p.get("relationship", ""),
            rel_desc=p.get("relationship_desc", ""),
            intimacy=int(p["intimacy"]) if p.get("intimacy") else None,
            friction=int(p["friction"]) if p.get("friction") else None,
            power=p.get("power", ""),
        )
        db.add(person)

    await db.flush()
    return person


async def _insert_event(
    db: AsyncSession,
    user_id: str,
    e: dict,
    session_id: str,
    person_id_map: dict,
) -> None:
    summary = (e.get("summary") or "").strip()
    if not summary:
        return

    event_date = e.get("date") or date.today().isoformat()
    if event_date == "today":
        event_date = date.today().isoformat()

    event = KgEvent(
        user_id=uuid_module.UUID(user_id),
        event_date=event_date,
        summary=summary,
        sentiment=e.get("sentiment", ""),
        outcome=e.get("outcome", ""),
        session_id=uuid_module.UUID(session_id) if session_id else None,
    )
    db.add(event)
    await db.flush()

    # 关联人物（事件可涉及多人，目前 LLM 每条事件只抽取一个 person 字段）
    person_name = (e.get("person") or "").strip()
    if person_name and person_name in person_id_map:
        db.add(KgEventPerson(event_id=event.id, person_id=person_id_map[person_name]))


async def _insert_goal(
    db: AsyncSession,
    user_id: str,
    g: dict,
    session_id: str,
    person_id_map: dict,
) -> None:
    desc = (g.get("description") or "").strip()
    if not desc:
        return

    person_name = (g.get("person") or "").strip()
    person_id = person_id_map.get(person_name) if person_name else None

    db.add(KgGoal(
        user_id=uuid_module.UUID(user_id),
        description=desc,
        status=g.get("status", "in_progress"),
        person_id=person_id,
        session_id=uuid_module.UUID(session_id) if session_id else None,
    ))


# ─── 内部读取工具 ──────────────────────────────────────────────────────────────

async def _format_person_block(db: AsyncSession, person: KgPerson) -> str:
    """格式化单人上下文块，供 AI 系统提示使用"""
    rel = person.rel_desc or person.rel_type or ""
    intimacy = f" 亲密度{person.intimacy}/10" if person.intimacy else ""
    friction = f" 摩擦{person.friction}/10" if person.friction else ""
    lines = [f"【{person.name}】{rel}{intimacy}{friction}"]

    # 最近 5 条事件
    events_r = await db.execute(
        select(KgEvent)
        .join(KgEventPerson, KgEvent.id == KgEventPerson.event_id)
        .where(KgEventPerson.person_id == person.id)
        .order_by(KgEvent.event_date.desc(), KgEvent.created_at.desc())
        .limit(5)
    )
    for e in events_r.scalars():
        outcome = f"（{e.outcome}）" if e.outcome else ""
        lines.append(f"  事件[{e.event_date or '近期'}] {e.summary}{outcome}")

    # 进行中目标
    goals_r = await db.execute(
        select(KgGoal)
        .where(KgGoal.person_id == person.id, KgGoal.status == "in_progress")
        .order_by(KgGoal.updated_at.desc())
        .limit(3)
    )
    for g in goals_r.scalars():
        lines.append(f"  目标[进行中] {g.description}")

    # 最近使用过的技能
    skills_r = await db.execute(
        select(KgSkill)
        .where(
            KgSkill.user_id == person.user_id,
            person.id == any_(KgSkill.person_ids),
        )
        .order_by(KgSkill.applied_at.desc())
        .limit(3)
    )
    for s in skills_r.scalars():
        lines.append(f"  技能[{s.applied_at.strftime('%m-%d') if s.applied_at else ''}] {s.skill_name or s.skill_id}")

    return "\n".join(lines)


def _empty_response(profile_name: str) -> dict:
    return {
        "profile_name": profile_name,
        "relationship": [],
        "events": [],
        "goals": [],
        "skills": [],
        "other": [],
        "total": 0,
    }



async def get_self_memories_kg(
    profile_name: str,
    user_id: str,
    db: AsyncSession,
) -> dict:
    """Self 档案专用：展示用户自己的目标和使用过的技能。"""
    try:
        import uuid as _uuid_mod
        uid = _uuid_mod.UUID(user_id)

        # goals: person_id IS NULL，属于用户自身的目标
        goals_r = await db.execute(
            select(KgGoal)
            .where(KgGoal.user_id == uid, KgGoal.person_id == None)
            .order_by(KgGoal.updated_at.desc())
            .limit(30)
        )
        goals = [{"content": g.description, "type": "goal",
                  "date": None, "status": g.status}
                 for g in goals_r.scalars()]
        goals.sort(key=lambda x: x["status"] != "in_progress")

        # skills: 该用户所有会话中应用过的技能，去重
        skills_r = await db.execute(
            select(KgSkill)
            .where(KgSkill.user_id == uid)
            .order_by(KgSkill.applied_at.desc())
            .limit(50)
        )
        seen = set()
        skills = []
        for s in skills_r.scalars():
            if s.skill_id not in seen:
                seen.add(s.skill_id)
                skills.append({
                    "content": s.skill_name or s.skill_id,
                    "type": "skill",
                    "date": s.applied_at.strftime("%Y-%m-%d") if s.applied_at else None,
                    "status": None,
                })

        total = len(goals) + len(skills)
        return {
            "profile_name": profile_name,
            "relationship": [],
            "events": [],
            "goals": goals,
            "skills": skills,
            "other": [],
            "total": total,
        }
    except Exception as exc:
        logger.warning(f"[KG] get_self_memories_kg failed: {exc}")
        return _empty_response(profile_name)

async def link_kg_person_to_profile(
    user_id: str,
    person_name: str,
    profile_id: str,
    db: AsyncSession,
) -> None:
    """
    场景生成完成 _name_mapping 后调用，把 kg_persons.profile_id 指向匹配的档案。
    幂等：已设置则跳过。
    """
    try:
        import uuid as _uuid_mod
        uid = _uuid_mod.UUID(user_id)
        pid = _uuid_mod.UUID(profile_id)
        r = await db.execute(
            select(KgPerson).where(KgPerson.user_id == uid, KgPerson.name == person_name)
        )
        person = r.scalar_one_or_none()
        if person and person.profile_id != pid:
            person.profile_id = pid
            await db.commit()
            logger.info(f"[KG] kg_persons 链接: {person_name} → profile_id={profile_id}")
    except Exception as exc:
        logger.warning(f"[KG] link_kg_person_to_profile 失败: {exc}")
