"""
Push 通知相关 API
- POST /api/v1/device/token       注册/更新 APNs device token
- POST /api/v1/notification/opened  记录用户点击通知
"""
import logging
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text

from auth.jwt_handler import get_current_user_id
from database.connection import get_db

logger = logging.getLogger(__name__)
router = APIRouter(tags=["notifications"])


# ── Pydantic models ──────────────────────────────────────────────────────────

class DeviceTokenRequest(BaseModel):
    device_token: str
    timezone: str = "America/New_York"
    sandbox: bool = False


class NotificationOpenedRequest(BaseModel):
    notification_log_id: int


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.post("/api/v1/device/token")
async def register_device_token(
    body: DeviceTokenRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """iOS 启动时注册/刷新 APNs device token，同时上报用户时区"""
    await db.execute(
        text("""
            UPDATE users
            SET apns_device_token   = :token,
                apns_sandbox        = :sandbox,
                timezone            = :tz
            WHERE id = :uid
        """),
        {"token": body.device_token, "sandbox": body.sandbox,
         "tz": body.timezone, "uid": user_id},
    )
    await db.commit()
    logger.info(f"[Notify] device token registered user={user_id[:8]} tz={body.timezone} sandbox={body.sandbox}")
    return {"ok": True}


@router.post("/api/v1/notification/opened")
async def notification_opened(
    body: NotificationOpenedRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """用户点击推送通知后 iOS 调用此接口，记录打开事件"""
    result = await db.execute(
        text("""
            UPDATE notification_log
            SET opened    = TRUE,
                opened_at = NOW()
            WHERE id = :nid AND user_id = :uid
            RETURNING id
        """),
        {"nid": body.notification_log_id, "uid": user_id},
    )
    await db.commit()
    row = result.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="notification not found")
    logger.info(f"[Notify] opened nid={body.notification_log_id} user={user_id[:8]}")
    return {"ok": True}
