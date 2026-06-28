"""
Apple App Store Server API - StoreKit 2 收据验证
文档: https://developer.apple.com/documentation/appstoreserverapi

验证流程:
  1. iOS 购买成功后, StoreKit 2 返回 signedTransactionInfo (JWS)
  2. 客户端将 originalTransactionId 发给后端
  3. 后端用 App Store Server API 查询验证
  4. 解析产品ID → 确定订阅档位和到期时间
  5. 更新数据库 subscription_tier / subscription_expires_at
"""

import os
import time
import uuid
import logging
import httpx
import jwt          # PyJWT
from datetime import datetime, timezone, timedelta
from cryptography.hazmat.primitives.serialization import load_pem_private_key

logger = logging.getLogger(__name__)

# ── 环境变量 ───────────────────────────────────────────────────────────────
APPLE_BUNDLE_ID   = os.getenv("APPLE_BUNDLE_ID", "com.liudan.WorkSurvivalGuide")
APPLE_ISSUER_ID   = os.getenv("APPLE_ISSUER_ID", "")        # App Store Connect → 密钥 → Issuer ID
APPLE_KEY_ID      = os.getenv("APPLE_KEY_ID", "")           # App Store Connect → 密钥 → 密钥ID
APPLE_PRIVATE_KEY = os.getenv("APPLE_PRIVATE_KEY", "")      # .p8 文件全文内容（含 BEGIN/END 行）

# Apple API 端点（production / sandbox 自动尝试）
APPLE_API_PROD    = "https://api.storekit.itunes.apple.com"
APPLE_API_SANDBOX = "https://api.storekit-sandbox.itunes.apple.com"

# ── 产品ID → 订阅档位映射 ──────────────────────────────────────────────────
PRODUCT_TIER_MAP = {
    "com.miclnk.pro.monthly":   {"tier": "pro", "months": 1},
    "com.miclnk.pro.quarterly": {"tier": "pro", "months": 3},
    "com.miclnk.pro.annual":    {"tier": "pro", "months": 12},
}


# ── JWT 生成（用于调用 App Store Server API）──────────────────────────────
def _make_apple_jwt() -> str:
    """
    生成 App Store Server API 认证 JWT（ES256，有效期20分钟）
    需要: APPLE_ISSUER_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY
    """
    if not all([APPLE_ISSUER_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY]):
        raise ValueError(
            "缺少 Apple API 配置，请在 .env 中设置: "
            "APPLE_ISSUER_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY"
        )

    now = int(time.time())
    payload = {
        "iss": APPLE_ISSUER_ID,
        "iat": now,
        "exp": now + 1200,          # 20分钟有效期
        "aud": "appstoreconnect-v1",
        "bid": APPLE_BUNDLE_ID,
    }
    headers = {
        "alg": "ES256",
        "kid": APPLE_KEY_ID,
        "typ": "JWT",
    }

    # 处理私钥格式（支持直接PEM或换行符转义）
    private_key_pem = APPLE_PRIVATE_KEY.replace("\\n", "\n").strip()
    if not private_key_pem.startswith("-----"):
        raise ValueError("APPLE_PRIVATE_KEY 格式错误，应为 PEM 格式（以 -----BEGIN... 开头）")

    token = jwt.encode(payload, private_key_pem, algorithm="ES256", headers=headers)
    return token


# ── 核心验证：查询单笔交易 ─────────────────────────────────────────────────
async def verify_transaction(original_transaction_id: str) -> dict:
    """
    通过 App Store Server API 验证交易（先查 production，再查 sandbox）
    返回:
    {
      "valid": True/False,
      "tier": "pro",
      "expires_at": datetime(...),
      "product_id": "com.miclnk.pro.monthly",
      "original_transaction_id": "...",
      "environment": "Production"/"Sandbox",
      "error": None 或错误信息
    }
    """
    apple_jwt = _make_apple_jwt()
    headers = {
        "Authorization": f"Bearer {apple_jwt}",
        "Content-Type": "application/json",
    }

    # 先查 production，失败再查 sandbox
    for env_name, base_url in [("Production", APPLE_API_PROD), ("Sandbox", APPLE_API_SANDBOX)]:
        url = f"{base_url}/inApps/v1/subscriptions/{original_transaction_id}"
        try:
            async with httpx.AsyncClient(timeout=15.0) as client:
                resp = await client.get(url, headers=headers)

            if resp.status_code == 404:
                logger.debug(f"[apple_iap] {env_name}: 交易不存在，尝试下一环境")
                continue

            if resp.status_code == 401:
                if env_name == "Sandbox":
                    # Sandbox 401 = JWT 凭证真的有问题
                    logger.error(f"[apple_iap] Apple API 认证失败，请检查 APPLE_ISSUER_ID / APPLE_KEY_ID / APPLE_PRIVATE_KEY")
                    return {"valid": False, "error": "Apple API authentication failed"}
                else:
                    # Production 401 通常意味着 App 未上架生产环境，继续尝试 Sandbox
                    logger.info(f"[apple_iap] Production 返回 401（App 可能仅在 Sandbox），继续尝试 Sandbox")
                    continue

            if resp.status_code != 200:
                logger.error(f"[apple_iap] {env_name}: HTTP {resp.status_code} - {resp.text[:200]}")
                continue

            data = resp.json()
            return _parse_subscription_response(data, env_name)

        except httpx.TimeoutException:
            logger.error(f"[apple_iap] {env_name}: 请求超时")
            continue
        except Exception as e:
            logger.error(f"[apple_iap] {env_name}: 异常 {e}")
            continue

    return {"valid": False, "error": "Transaction not found in Production or Sandbox"}


async def verify_transaction_local_test(original_transaction_id: str, product_id: str) -> dict:
    """
    本地 StoreKit 测试环境（.storekit 文件）产生的交易，Apple 服务器无法验证。
    设备端已通过 StoreKit 2 checkVerified() 验证，后端直接信任并授予对应档位。
    仅用于开发测试，生产环境不应调用。
    """
    from datetime import datetime, timezone, timedelta

    mapping = PRODUCT_TIER_MAP.get(product_id)
    if not mapping:
        # 产品ID未知，兜底给pro
        mapping = {"tier": "pro", "months": 1}
        logger.warning(f"[apple_iap] 本地测试：未知产品ID {product_id}，默认授予 pro 1个月")

    expires_at = datetime.now(timezone.utc) + timedelta(days=30 * mapping["months"])
    logger.info(f"[apple_iap] ✅ 本地测试交易信任: txId={original_transaction_id} product={product_id} tier={mapping['tier']}")
    return {
        "valid": True,
        "tier": mapping["tier"],
        "expires_at": expires_at,
        "product_id": product_id,
        "original_transaction_id": original_transaction_id,
        "environment": "LocalTest",
        "error": None,
    }


def _parse_subscription_response(data: dict, environment: str) -> dict:
    """
    解析 /inApps/v1/subscriptions/{id} 响应
    取最新一笔 lastTransactions 中状态为 active(1) 的交易
    """
    last_transactions = data.get("data", [])
    if not last_transactions:
        return {"valid": False, "error": "No subscription data returned"}

    # 找最新的有效订阅（status=1: active, 2: expired, 3: in billing retry, 4: in grace period, 5: revoked)
    ACTIVE_STATUSES = {1, 3, 4}   # 1=active, 3=billing retry（仍有效）, 4=grace period（仍有效）
    active_item = None
    for item in last_transactions:
        last_tx = item.get("lastTransactions", [{}])[0]
        status = last_tx.get("status")
        if status in ACTIVE_STATUSES:
            active_item = (item, last_tx)
            break

    if not active_item:
        # 取最新一条检查过期时间（可能已过期）
        item = last_transactions[0]
        last_tx = item.get("lastTransactions", [{}])[0]
        product_id = item.get("productId", "")
        expires_ms = last_tx.get("expiresDate", 0)
        expires_at = datetime.fromtimestamp(expires_ms / 1000, tz=timezone.utc) if expires_ms else None
        now = datetime.now(timezone.utc)
        if expires_at and expires_at > now:
            pass  # 还没过期，继续处理
        else:
            return {"valid": False, "error": f"Subscription expired or revoked (status={last_tx.get('status')})"}
        active_item = (item, last_tx)

    item, last_tx = active_item
    product_id = item.get("productId", "")
    expires_ms  = last_tx.get("expiresDate", 0)
    orig_tx_id  = last_tx.get("originalTransactionId", "")

    if expires_ms:
        expires_at = datetime.fromtimestamp(expires_ms / 1000, tz=timezone.utc)
    else:
        expires_at = datetime.now(timezone.utc) + timedelta(days=30)  # 兜底1个月

    mapping = PRODUCT_TIER_MAP.get(product_id)
    if not mapping:
        logger.warning(f"[apple_iap] 未知产品ID: {product_id}")
        return {"valid": False, "error": f"Unknown product_id: {product_id}"}

    logger.info(
        f"[apple_iap] ✅ 验证成功 env={environment} product={product_id} "
        f"tier={mapping['tier']} expires={expires_at.isoformat()}"
    )
    return {
        "valid": True,
        "tier": mapping["tier"],
        "expires_at": expires_at,
        "product_id": product_id,
        "original_transaction_id": orig_tx_id,
        "environment": environment,
        "error": None,
    }


# ── Apple Server Notifications V2 解析 ────────────────────────────────────
def parse_server_notification(signed_payload: str) -> dict:
    """
    解析 Apple Server Notifications V2 推送的 signedPayload（JWS）
    注意：生产环境应验证 Apple 根证书签名，此处仅 decode（不验签，依赖 Apple API 二次确认）
    """
    try:
        # JWS = header.payload.signature，只取 payload 部分
        parts = signed_payload.split(".")
        if len(parts) != 3:
            raise ValueError("Invalid JWS format")
        import base64
        import json
        # base64url decode（补 padding）
        payload_b64 = parts[1] + "=" * (-len(parts[1]) % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_b64))
        return payload
    except Exception as e:
        logger.error(f"[apple_iap] 解析 Server Notification 失败: {e}")
        return {}
