"""
订阅服务层
管理用户订阅档位、录音次数限流、图片张数控制
"""
from datetime import datetime, timezone
from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from database.models import User
import uuid
import logging

logger = logging.getLogger(__name__)

# ── 各档位配置 ─────────────────────────────────────────────────────────────
TIER_LIMITS = {
    "free": {
        "monthly_recordings": 3,    # 每月录音次数上限
        "images_per_recording": 1,  # 每条录音生成图片数
        "history_days": 30,         # 历史记录保留天数（None = 永久）
    },
    "pro": {
        "monthly_recordings": 30,
        "images_per_recording": 3,
        "history_days": None,
    },
}

DEFAULT_TIER = "free"


def get_tier_config(tier: str) -> dict:
    return TIER_LIMITS.get(tier, TIER_LIMITS[DEFAULT_TIER])


def get_images_count(tier: str) -> int:
    """返回该档位每条录音应生成的图片数量"""
    return get_tier_config(tier)["images_per_recording"]


async def get_user_subscription(user_id: str, db: AsyncSession) -> dict:
    """
    获取用户订阅状态，同时执行月度重置检查。
    返回: { tier, expires_at, monthly_recording_count, monthly_limit, images_per_recording }
    """
    user = await db.get(User, uuid.UUID(user_id))
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    # ── 过期检查：到期后降回 free ───────────────────────────────────────────
    now = datetime.now(timezone.utc)
    tier = user.subscription_tier or DEFAULT_TIER
    if tier != "free" and user.subscription_expires_at:
        if user.subscription_expires_at < now:
            user.subscription_tier = "free"
            user.subscription_expires_at = None
            tier = "free"
            await db.commit()
            logger.info(f"[subscription] 用户 {user_id[:8]} 订阅已过期，降级为 free")

    # ── 月度重置检查 ────────────────────────────────────────────────────────
    reset_at = user.monthly_reset_at
    need_reset = False
    if reset_at is None:
        need_reset = True
    else:
        # 如果重置时间早于本月1日 00:00 UTC，需要重置
        month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        if reset_at < month_start:
            need_reset = True

    if need_reset:
        user.monthly_recording_count = 0
        user.monthly_reset_at = now
        await db.commit()
        logger.info(f"[subscription] 用户 {user_id[:8]} 月度录音计数已重置")

    config = get_tier_config(tier)
    return {
        "tier": tier,
        "expires_at": user.subscription_expires_at.isoformat() if user.subscription_expires_at else None,
        "monthly_recording_count": user.monthly_recording_count,
        "monthly_limit": config["monthly_recordings"],
        "images_per_recording": config["images_per_recording"],
        "history_days": config["history_days"],
    }


async def check_and_increment_recording(user_id: str, db: AsyncSession) -> dict:
    """
    检查用户是否还有录音配额，有则+1并提交。
    无配额时抛出 HTTP 429。
    返回订阅状态 dict（含 images_per_recording 供调用方使用）。
    """
    status = await get_user_subscription(user_id, db)
    count = status["monthly_recording_count"]
    limit = status["monthly_limit"]

    if count >= limit:
        tier = status["tier"]
        logger.warning(f"[subscription] 用户 {user_id[:8]} 录音次数已达上限 {count}/{limit} (tier={tier})")
        raise HTTPException(
            status_code=429,
            detail={
                "code": "RECORDING_LIMIT_REACHED",
                "message": f"You've used all {limit} recordings this month.",
                "current": count,
                "limit": limit,
                "tier": tier,
                "upgrade_required": tier == "free",
            }
        )

    # 配额 +1
    user = await db.get(User, uuid.UUID(user_id))
    user.monthly_recording_count = count + 1
    await db.commit()
    logger.info(f"[subscription] 用户 {user_id[:8]} 录音计数 {count+1}/{limit} (tier={status['tier']})")

    status["monthly_recording_count"] = count + 1
    return status


async def update_subscription(
    user_id: str,
    tier: str,
    expires_at: datetime,
    db: AsyncSession,
) -> None:
    """
    更新用户订阅档位（Apple 收据验证成功后调用）。
    """
    if tier not in TIER_LIMITS:
        raise HTTPException(status_code=400, detail=f"Invalid tier: {tier}")
    user = await db.get(User, uuid.UUID(user_id))
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.subscription_tier = tier
    user.subscription_expires_at = expires_at
    await db.commit()
    logger.info(f"[subscription] 用户 {user_id[:8]} 订阅已更新: tier={tier} expires={expires_at}")
