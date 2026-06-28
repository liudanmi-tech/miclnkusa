"""
星图/内在宇宙 API
从 skill_executions 历史计算星图数据，无需额外持久化表。
"""
import logging
import math
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional

from fastapi import APIRouter, Depends
from sqlalchemy import func, select, and_
from sqlalchemy.ext.asyncio import AsyncSession

from auth.jwt_handler import get_current_user_id
from database.connection import get_db
from database.models import SkillExecution, Skill, Session

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/galaxy", tags=["galaxy"])

# ──────────────────────── 星座映射 ────────────────────────
# 每个子技能 -> (sector, constellation)
_STAR_MAP: Dict[str, dict] = {
    # 职场 - 统御座
    "managing_up":      {"sector": "workplace", "constellation": "统御座", "label": "向上管理"},
    "managing_down":    {"sector": "workplace", "constellation": "统御座", "label": "向下管理"},
    "influence":        {"sector": "workplace", "constellation": "统御座", "label": "影响力提升"},
    # 职场 - 博弈座
    "negotiation":      {"sector": "workplace", "constellation": "博弈座", "label": "谈判博弈"},
    "conflict_resolution": {"sector": "workplace", "constellation": "博弈座", "label": "冲突化解"},
    "defensive":        {"sector": "workplace", "constellation": "博弈座", "label": "防御技能"},
    # 职场 - 智慧座
    "logical_thinking": {"sector": "workplace", "constellation": "智慧座", "label": "逻辑思维"},
    "presentation":     {"sector": "workplace", "constellation": "智慧座", "label": "汇报展示"},
    "crisis_management": {"sector": "workplace", "constellation": "智慧座", "label": "危机公关"},
    # 职场 - 其他
    "peer_collaboration": {"sector": "workplace", "constellation": "统御座", "label": "横向协作"},
    "external_communication": {"sector": "workplace", "constellation": "智慧座", "label": "对外沟通"},
    "offensive":        {"sector": "workplace", "constellation": "博弈座", "label": "进攻技型"},
    "constructive":     {"sector": "workplace", "constellation": "博弈座", "label": "建设技能"},
    "healing":          {"sector": "workplace", "constellation": "统御座", "label": "治愈技能"},
    "rookie":           {"sector": "workplace", "constellation": "智慧座", "label": "新人小白"},
    "core_manager":     {"sector": "workplace", "constellation": "统御座", "label": "骨干中层"},
    "executive":        {"sector": "workplace", "constellation": "统御座", "label": "高管领袖"},
    "eq":               {"sector": "workplace", "constellation": "博弈座", "label": "情商提升"},
    "small_talk":       {"sector": "workplace", "constellation": "智慧座", "label": "闲聊社交"},
    "brainstorm":       {"sector": "workplace", "constellation": "智慧座", "label": "头脑风暴"},
    # 家庭 - 羁绊座
    "family_relationship": {"sector": "family", "constellation": "羁绊座", "label": "亲密关系"},
    # 家庭 - 启明星
    "education_communication": {"sector": "family", "constellation": "启明星", "label": "教育沟通"},
    # 个人 - 自愈座
    "emotion_recognition": {"sector": "personal", "constellation": "自愈座", "label": "情绪识别"},
    "depression_prevention": {"sector": "personal", "constellation": "自愈座", "label": "防抑郁监控"},
}

# 维度技能 -> 它的子技能列表 (用于聚合)
_DIMENSION_SUB_SKILLS = {
    "workplace_role": ["managing_up", "managing_down", "peer_collaboration", "external_communication"],
    "workplace_scenario": ["conflict_resolution", "negotiation", "presentation", "small_talk", "crisis_management"],
    "workplace_psychology": ["defensive", "offensive", "constructive", "healing"],
    "workplace_career": ["rookie", "core_manager", "executive"],
    "workplace_capability": ["logical_thinking", "eq", "influence"],
}


def _compute_state(mass: int) -> str:
    if mass == 0:
        return "locked"
    if mass < 3:
        return "proto"
    if mass < 10:
        return "main"
    return "supernova"


def _compute_brightness(mass: int, last_active: Optional[datetime]) -> int:
    if mass == 0:
        return 0
    base = min(mass * 10, 80)
    if last_active:
        now = datetime.now(timezone.utc)
        days_ago = (now - last_active).days
        recency_bonus = max(0, 20 - days_ago * 2)
    else:
        recency_bonus = 0
    return min(base + recency_bonus, 100)


def _compute_phase(total_mass: int) -> dict:
    if total_mass < 5:
        return {"phase": "nebula", "label": "星云期", "description": "你的内在宇宙刚刚诞生，一切充满可能"}
    if total_mass < 15:
        return {"phase": "protostar", "label": "原恒星期", "description": "能量开始凝聚，恒星即将成形"}
    if total_mass < 40:
        return {"phase": "stellar_formation", "label": "恒星形成期", "description": "多颗恒星被点亮，星系初具规模"}
    if total_mass < 80:
        return {"phase": "main_sequence", "label": "主序星系期", "description": "稳定而璀璨，你的宇宙正在扩张"}
    return {"phase": "spiral_galaxy", "label": "螺旋星系", "description": "壮丽的螺旋臂清晰可见，你已掌握多维能力"}


@router.get("/overview")
async def get_galaxy_overview(
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """
    返回用户的星图概览数据，从 skill_executions 实时计算。
    """
    import uuid as _uuid
    uid = _uuid.UUID(user_id) if isinstance(user_id, str) else user_id

    # 查询该用户所有成功的技能执行记录
    stmt = (
        select(
            SkillExecution.skill_id,
            func.count().label("exec_count"),
            func.max(SkillExecution.created_at).label("last_active"),
        )
        .join(Session, and_(
            SkillExecution.session_id == Session.id,
            Session.user_id == uid,
        ))
        .where(SkillExecution.success == True)  # noqa: E712
        .group_by(SkillExecution.skill_id)
    )
    rows = (await db.execute(stmt)).all()

    # skill_id -> {count, last_active}
    skill_stats: Dict[str, dict] = {}
    for row in rows:
        skill_stats[row.skill_id] = {
            "count": row.exec_count,
            "last_active": row.last_active,
        }

    # 将维度级统计拆分到子技能
    sub_skill_stats: Dict[str, dict] = {}
    for skill_id, stats in skill_stats.items():
        if skill_id in _DIMENSION_SUB_SKILLS:
            # 将维度技能的执行次数平均分配给其子技能
            subs = _DIMENSION_SUB_SKILLS[skill_id]
            per_sub = max(1, stats["count"] // len(subs))
            for sub_id in subs:
                existing = sub_skill_stats.get(sub_id, {"count": 0, "last_active": None})
                sub_skill_stats[sub_id] = {
                    "count": existing["count"] + per_sub,
                    "last_active": stats["last_active"]
                    if existing["last_active"] is None
                    else max(existing["last_active"], stats["last_active"]),
                }
        elif skill_id in _STAR_MAP:
            existing = sub_skill_stats.get(skill_id, {"count": 0, "last_active": None})
            sub_skill_stats[skill_id] = {
                "count": existing["count"] + stats["count"],
                "last_active": stats["last_active"]
                if existing["last_active"] is None
                else max(existing["last_active"], stats["last_active"]),
            }

    # 构建恒星列表
    stars = []
    sector_energy = {"workplace": 0, "family": 0, "personal": 0}
    total_mass = 0

    for star_id, info in _STAR_MAP.items():
        stats = sub_skill_stats.get(star_id, {"count": 0, "last_active": None})
        mass = stats["count"]
        brightness = _compute_brightness(mass, stats["last_active"])
        state = _compute_state(mass)
        total_mass += mass
        sector_energy[info["sector"]] += brightness

        stars.append({
            "star_id": star_id,
            "label": info["label"],
            "sector": info["sector"],
            "constellation": info["constellation"],
            "brightness": brightness,
            "mass": mass,
            "state": state,
        })

    # 旋臂能量归一化
    sectors = []
    for sec_id, sec_name, sec_color in [
        ("workplace", "职场旋臂", "#00E5FF"),
        ("family", "家庭旋臂", "#FF69B4"),
        ("personal", "个人旋臂", "#FFD700"),
    ]:
        sec_stars = [s for s in stars if s["sector"] == sec_id]
        max_possible = len(sec_stars) * 100
        energy_pct = int(sector_energy[sec_id] / max_possible * 100) if max_possible > 0 else 0
        sectors.append({
            "id": sec_id,
            "name": sec_name,
            "color": sec_color,
            "energy": energy_pct,
            "star_count": len(sec_stars),
            "active_count": sum(1 for s in sec_stars if s["state"] != "locked"),
        })

    phase = _compute_phase(total_mass)

    return {
        "code": 200,
        "data": {
            "phase": phase,
            "total_mass": total_mass,
            "sectors": sectors,
            "stars": stars,
        },
    }
