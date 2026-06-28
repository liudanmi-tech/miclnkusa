"""
iOS 技能注册表 v2（支持热更新）
所有技能数据从 skills_config.json 加载，通过 reload_skills_config() 可在不重启服务的情况下热更新。
"""
import json
import logging
from pathlib import Path

logger = logging.getLogger(__name__)

# ─────────────────────────────────────────────
# JSON 配置文件路径（与本文件同级目录的上一层）
# ─────────────────────────────────────────────
_SKILLS_CONFIG_PATH = Path(__file__).parent.parent / "skills_config.json"

# ─────────────────────────────────────────────
# 执行模板 ID 常量（固定，不热更新）
# ─────────────────────────────────────────────
EXEC_WORK_LIFE       = "_exec_work_life"
EXEC_CAMPUS_LIFE     = "_exec_campus_life"
EXEC_RELATIONSHIPS   = "_exec_relationships"
EXEC_FAMILY          = "_exec_family"
EXEC_PERSONAL_GROWTH = "_exec_personal_growth"
EXEC_LIFE_SKILLS     = "_exec_life_skills"
EXEC_CUSTOM          = "_exec_custom"


# ─────────────────────────────────────────────
# JSON 加载函数
# ─────────────────────────────────────────────
def _load_config() -> dict:
    """从 skills_config.json 读取配置，解析失败时抛出异常"""
    try:
        with open(_SKILLS_CONFIG_PATH, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        n = len(cfg.get("system_skills", {}))
        logger.info(f"[SkillsConfig] 已加载 {n} 个技能 from {_SKILLS_CONFIG_PATH}")
        return cfg
    except Exception as e:
        logger.error(f"[SkillsConfig] 加载失败: {_SKILLS_CONFIG_PATH} — {e}")
        raise


# ─────────────────────────────────────────────
# 模块级可变数据结构
# 使用 in-place 更新（clear + update），确保 router.py 等外部 import
# 拿到的仍是同一个 dict 对象，热更新后自动生效。
# ─────────────────────────────────────────────
CATEGORY_SCENE_DESCRIPTIONS: dict = {}
SYSTEM_SKILLS: dict = {}
PROMPT_TEMPLATES: dict = {}
_WORK_LIFE_EXEC_SKILL_MAP: dict = {}
_FAMILY_EXEC_SKILL_MAP: dict = {}
_PERSONAL_EXEC_SKILL_MAP: dict = {}


def reload_skills_config() -> int:
    """
    从 skills_config.json 重新加载技能配置，原地更新所有模块级变量。
    调用此函数不需要重启服务，立即对所有后续请求生效。

    Returns:
        int: 加载的技能总数
    """
    cfg = _load_config()

    # 原地更新（保持外部已 import 的引用有效）
    CATEGORY_SCENE_DESCRIPTIONS.clear()
    CATEGORY_SCENE_DESCRIPTIONS.update(cfg.get("category_descriptions", {}))

    SYSTEM_SKILLS.clear()
    SYSTEM_SKILLS.update(cfg.get("system_skills", {}))

    PROMPT_TEMPLATES.clear()
    PROMPT_TEMPLATES.update(cfg.get("prompt_templates", {}))

    maps = cfg.get("exec_skill_maps", {})
    _WORK_LIFE_EXEC_SKILL_MAP.clear()
    _WORK_LIFE_EXEC_SKILL_MAP.update(maps.get("work_life", {}))

    _FAMILY_EXEC_SKILL_MAP.clear()
    _FAMILY_EXEC_SKILL_MAP.update(maps.get("family", {}))

    _PERSONAL_EXEC_SKILL_MAP.clear()
    _PERSONAL_EXEC_SKILL_MAP.update(maps.get("personal_growth", {}))

    count = len(SYSTEM_SKILLS)
    logger.info(
        f"[SkillsConfig] 热更新完成: {count} 个技能, "
        f"{len(CATEGORY_SCENE_DESCRIPTIONS)} 个场景分类, "
        f"{len(PROMPT_TEMPLATES)} 个 prompt 模板"
    )
    return count


# ─────────────────────────────────────────────
# 模块加载时初始化（从 JSON 读取）
# ─────────────────────────────────────────────
reload_skills_config()


# ─────────────────────────────────────────────
# 工具函数（接口不变，逻辑不变）
# ─────────────────────────────────────────────

def get_skill_config(skill_id: str) -> dict | None:
    """
    返回技能配置，支持系统技能和 custom_ 前缀的自创技能。
    找不到返回 None。
    """
    if skill_id.startswith("custom_"):
        return {
            "category": "custom",
            "name": skill_id,
            "exec_template": EXEC_CUSTOM,
            "exec_context": {},
        }
    return SYSTEM_SKILLS.get(skill_id)


def get_all_system_skill_ids() -> list[str]:
    """返回全部系统子技能 ID 列表"""
    return list(SYSTEM_SKILLS.keys())


def get_skills_by_category(category: str) -> list[str]:
    """返回指定分类下的所有系统子技能 ID"""
    return [k for k, v in SYSTEM_SKILLS.items() if v["category"] == category]


def get_category_for_skill(skill_id: str) -> str | None:
    """返回技能所属的 iOS 分类"""
    cfg = get_skill_config(skill_id)
    return cfg["category"] if cfg else None


def get_server_skill_id_for_exec(ios_skill_id: str) -> str | None:
    """
    对于复用已有数据库 prompt 的技能，返回对应的服务器 skill_id。
    campus_life / life_skills 使用内置 prompt，返回 None。
    custom_ 前缀使用动态 prompt，返回 None。
    """
    if ios_skill_id in _WORK_LIFE_EXEC_SKILL_MAP:
        return _WORK_LIFE_EXEC_SKILL_MAP[ios_skill_id]
    if ios_skill_id in _FAMILY_EXEC_SKILL_MAP:
        return _FAMILY_EXEC_SKILL_MAP[ios_skill_id]
    if ios_skill_id in _PERSONAL_EXEC_SKILL_MAP:
        return _PERSONAL_EXEC_SKILL_MAP[ios_skill_id]
    return None
