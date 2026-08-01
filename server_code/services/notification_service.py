"""
Push 通知核心服务
职责：
  1. get_eligible_users()    — 筛选当前时区桶内今日应推送的用户
  2. build_user_context()    — 拉取用户对话历史，判断 Tier
  3. pick_next_hook()        — 选择切入角度（防重复）
  4. pick_cold_template()    — 冷启动用户模板轮换
  5. generate_copy()         — Gemini 生成个性化文案（Tier 1/2/3）
  6. send_apns()             — APNs HTTP/2 推送
  7. process_one_user()      — 单用户完整流程
  8. process_batch()         — 批量入口（由 cron 脚本调用）
"""
import os
import json
import time
import random
import logging
import asyncio
from datetime import datetime, timedelta, timezone

import httpx
import jwt as pyjwt
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text

from database.connection import AsyncSessionLocal

logger = logging.getLogger(__name__)

# ── APNs 环境配置 ─────────────────────────────────────────────────────────────
APNS_KEY_ID    = os.getenv("APNS_KEY_ID", "")
APNS_TEAM_ID   = os.getenv("APNS_TEAM_ID", "")
APNS_BUNDLE_ID = os.getenv("APNS_BUNDLE_ID", "com.miclnk.pro")

# p8 key：优先读文件（推荐），也支持直接写 PEM 字符串到 APNS_P8_KEY 环境变量
def _load_p8_key() -> str:
    path = os.getenv("APNS_P8_KEY_PATH", "")
    if path and os.path.exists(path):
        with open(path, "r") as f:
            return f.read().strip()
    return os.getenv("APNS_P8_KEY", "")

APNS_P8_KEY = _load_p8_key()

# Gemini（复用 main.py 的 client，这里用独立 httpx 调用）
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
GEMINI_MODEL   = "gemini-2.5-flash-lite-preview-06-17"
PROXY_URL      = os.getenv("PROXY_URL", "")

# ── 角度池 ───────────────────────────────────────────────────────────────────
HOOK_ORDER_T1_T2 = ["followup", "emotion", "perspective", "action", "reflection"]
HOOK_ORDER_T3    = ["memory_ref", "encouragement", "challenge"]

HOOK_INSTRUCTIONS = {
    "followup":      "Focus on following up about how the situation turned out. Tone: curious and caring",
    "emotion":       "Focus on how the user's feelings may have shifted since then. Tone: gentle and supportive",
    "perspective":   "Offer a fresh angle on the same situation. Tone: thoughtful and calm",
    "action":        "Suggest one small thing the user could do to move forward. Tone: encouraging and practical",
    "reflection":    "Invite the user to notice any new feelings now that time has passed. Tone: quiet and wise",
    "memory_ref":    "Vaguely reference the user's past experience so they feel remembered. Tone: warm",
    "encouragement": "Encourage the user to share how they are right now. Tone: warm and open",
    "challenge":     "Pose a small question to get the user thinking. Tone: curious and light",
}

# ── 冷启动模板池（14 条，2 周不重复）────────────────────────────────────────
COLD_TEMPLATES = [
    {"day": 1,  "title": "How's work going today?",          "body": "Stuck on something? Saying it out loud usually helps"},
    {"day": 2,  "title": "Anything on your mind lately?",    "body": "Big or small — talking about it makes it lighter"},
    {"day": 3,  "title": "Getting along okay with coworkers?","body": "Workplace friction is always worth a quick chat"},
    {"day": 4,  "title": "How are you feeling today?",       "body": "Good or bad, no judgment here — just say it"},
    {"day": 5,  "title": "Sleeping well these days?",        "body": "Restless nights usually mean something's on your mind"},
    {"day": 6,  "title": "Something you've wanted to say?",  "body": "When there's no one to tell, I'm always here"},
    {"day": 7,  "title": "How's things with family?",        "body": "Small tensions at home are worth talking through"},
    {"day": 8,  "title": "How has this week been?",          "body": "Looking back, there might be more worth reflecting on"},
    {"day": 9,  "title": "Anything good happen recently?",   "body": "Good news deserves to be remembered too"},
    {"day": 10, "title": "Anything you've been putting off?","body": "Saying it out loud might be the first step"},
    {"day": 11, "title": "Worried about anything next week?","body": "Voicing it early usually makes it easier to handle"},
    {"day": 12, "title": "Felt hurt by something lately?",   "body": "Keeping it in is hard — this is a safe place to share"},
    {"day": 13, "title": "Someone you want to understand more?","body": "Relationship questions get clearer when you talk them out"},
    {"day": 14, "title": "Chat about anything today",        "body": "No topic needed — just say whatever's on your mind"},
]


# ── 1. 筛选目标用户 ──────────────────────────────────────────────────────────

async def get_eligible_users(timezones: list[str], db: AsyncSession) -> list:
    """
    返回符合推送条件的用户列表：
    - 在指定时区桶内
    - 有 device token
    - 开启通知
    - 今日（UTC日期）未发过
    - 今日未活跃（last_active_at 不是今天）
    """
    result = await db.execute(
        text("""
            SELECT u.id, u.apns_device_token, u.apns_sandbox, u.timezone
            FROM users u
            LEFT JOIN notification_log nl
                ON  nl.user_id  = u.id
                AND nl.sent_at::date = CURRENT_DATE
            WHERE u.timezone            = ANY(:tzs)
              AND u.apns_device_token  IS NOT NULL
              AND u.notification_opt_in = TRUE
              AND nl.id IS NULL
              AND (
                  u.last_active_at IS NULL
                  OR u.last_active_at::date < CURRENT_DATE
              )
        """),
        {"tzs": timezones},
    )
    return result.fetchall()


# ── 2. 构建用户上下文 + 判断 Tier ────────────────────────────────────────────

async def build_user_context(user_id: str, db: AsyncSession) -> dict:
    now = datetime.now(timezone.utc)

    result = await db.execute(
        text("""
            SELECT id, card_title, mood_state, emotion_type, created_at
            FROM sessions
            WHERE user_id      = :uid
              AND session_type = 'chat'
              AND card_title  IS NOT NULL
            ORDER BY created_at DESC
            LIMIT 5
        """),
        {"uid": user_id},
    )
    sessions = result.fetchall()

    if not sessions:
        return {"tier": 4, "ref_session": None, "ref_session_date": None}

    latest = sessions[0]
    # created_at 可能是 naive datetime，统一加上 UTC
    created = latest.created_at
    if created.tzinfo is None:
        created = created.replace(tzinfo=timezone.utc)
    age = now - created

    if age <= timedelta(hours=48):
        tier = 1
    elif age <= timedelta(days=7):
        tier = 2
    elif age <= timedelta(days=30):
        tier = 3
    else:
        tier = 4

    return {
        "tier":             tier,
        "ref_session":      latest,
        "ref_session_date": latest.created_at.date(),
    }


# ── 3. 选择切入角度（防重复）────────────────────────────────────────────────

async def pick_next_hook(user_id: str, tier: int, db: AsyncSession) -> str:
    result = await db.execute(
        text("""
            SELECT hook_type FROM notification_log
            WHERE user_id = :uid
            ORDER BY sent_at DESC
            LIMIT 7
        """),
        {"uid": user_id},
    )
    used = {r.hook_type for r in result.fetchall()}

    pool      = HOOK_ORDER_T1_T2 if tier <= 2 else HOOK_ORDER_T3
    available = [h for h in pool if h not in used]
    if not available:
        available = pool   # 全部用完，重新循环

    return available[0]


# ── 4. 冷启动模板轮换 ────────────────────────────────────────────────────────

async def pick_cold_template(user_id: str, db: AsyncSession) -> dict:
    result = await db.execute(
        text("""
            SELECT hook_index FROM notification_log
            WHERE user_id    = :uid
              AND hook_index IS NOT NULL
            ORDER BY sent_at DESC
            LIMIT 14
        """),
        {"uid": user_id},
    )
    used      = {r.hook_index for r in result.fetchall()}
    available = [t for t in COLD_TEMPLATES if t["day"] not in used]
    if not available:
        available = COLD_TEMPLATES   # 14条全发完，重新循环
    return random.choice(available)


# ── 5. Gemini 文案生成 ───────────────────────────────────────────────────────

def _hours_ago(dt) -> int:
    if dt is None:
        return 0
    now = datetime.now(timezone.utc)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return max(0, int((now - dt).total_seconds() / 3600))


async def generate_copy(context: dict, hook_type: str) -> dict:
    ref  = context["ref_session"]
    tier = context["tier"]

    prompt = f"""
You are a caring AI friend. Based on the user's recent conversation, write one iOS push notification.

User's recent conversation:
Topic: {ref.card_title or ''}
Mood: {ref.mood_state or ''}{(' (' + ref.emotion_type + ')') if ref.emotion_type else ''}
Happened: {_hours_ago(ref.created_at)} hours ago

Angle: {HOOK_INSTRUCTIONS.get(hook_type, '')}

Output pure JSON only, nothing else:
{{"title": "≤10 words", "body": "≤20 words"}}

Rules:
- No names, company names, or specific locations
- Tone like a text from a friend, not an app notification
- Do not end with an exclamation mark
- Write in English only
"""

    url = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent?key={GEMINI_API_KEY}"
    payload = {
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {"temperature": 0.9, "maxOutputTokens": 120},
    }

    proxies = {"https://": PROXY_URL} if PROXY_URL else None
    try:
        async with httpx.AsyncClient(proxies=proxies, timeout=15) as client:
            resp = await client.post(url, json=payload)
            resp.raise_for_status()
            raw = resp.json()
            text_out = raw["candidates"][0]["content"]["parts"][0]["text"].strip()
            # 去掉可能的 markdown 代码块
            if text_out.startswith("```"):
                text_out = text_out.split("```")[1]
                if text_out.startswith("json"):
                    text_out = text_out[4:]
            data = json.loads(text_out)
            return {
                "title":     data.get("title", "今天怎么样？"),
                "body":      data.get("body", "有什么想说的，随时在"),
                "tier":      tier,
                "hook_type": hook_type,
            }
    except Exception as e:
        logger.warning(f"[Notify] Gemini generate_copy failed: {e}, fallback to template")
        # 降级到 Tier 4 兜底
        t = random.choice(COLD_TEMPLATES)
        return {"title": t["title"], "body": t["body"], "tier": tier, "hook_type": hook_type}


# ── 6. APNs HTTP/2 发送 ──────────────────────────────────────────────────────

def _make_apns_jwt() -> str:
    return pyjwt.encode(
        {"iss": APNS_TEAM_ID, "iat": int(time.time())},
        APNS_P8_KEY,
        algorithm="ES256",
        headers={"kid": APNS_KEY_ID},
    )


async def send_apns(token: str, title: str, body: str,
                    extra: dict, sandbox: bool = False) -> bool:
    host = "api.sandbox.push.apple.com" if sandbox else "api.push.apple.com"
    apns_jwt = _make_apns_jwt()

    payload = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "badge": 1,
        },
        **extra,
    }

    try:
        async with httpx.AsyncClient(http2=True, timeout=10) as client:
            resp = await client.post(
                f"https://{host}/3/device/{token}",
                json=payload,
                headers={
                    "authorization": f"bearer {apns_jwt}",
                    "apns-topic":     APNS_BUNDLE_ID,
                    "apns-push-type": "alert",
                    "apns-priority":  "5",
                },
            )

        if resp.status_code == 410:
            # Token 失效（用户已卸载）→ 清除
            logger.info(f"[Notify] APNs 410 token expired, clearing: {token[:10]}...")
            async with AsyncSessionLocal() as db:
                await db.execute(
                    text("UPDATE users SET apns_device_token = NULL WHERE apns_device_token = :t"),
                    {"t": token},
                )
                await db.commit()
            return False

        if resp.status_code != 200:
            logger.warning(f"[Notify] APNs error {resp.status_code}: {resp.text}")
            return False

        return True

    except Exception as e:
        logger.error(f"[Notify] send_apns exception: {e}")
        return False


# ── 7. 单用户完整处理流程 ────────────────────────────────────────────────────

async def process_one_user(user_row, db: AsyncSession):
    user_id    = str(user_row.id)
    token      = user_row.apns_device_token
    sandbox    = user_row.apns_sandbox or False

    # Step 1: 拉上下文，判断 Tier
    context = await build_user_context(user_id, db)
    tier    = context["tier"]

    # Step 2a: Tier 4 → 模板轮换，不调 AI
    if tier == 4:
        template = await pick_cold_template(user_id, db)
        copy = {
            "title":           template["title"],
            "body":            template["body"],
            "tier":            4,
            "hook_type":       f"generic_{template['day']}",
            "hook_index":      template["day"],
            "ref_session_id":  None,
            "ref_session_date": None,
        }

    # Step 2b: Tier 1/2/3 → 选角度，调 Gemini
    else:
        ref_session = context["ref_session"]

        # 查上次推送记录
        last_log_result = await db.execute(
            text("""
                SELECT ref_session_id, hook_type
                FROM notification_log
                WHERE user_id = :uid
                ORDER BY sent_at DESC
                LIMIT 1
            """),
            {"uid": user_id},
        )
        last_log = last_log_result.fetchone()

        # 有新 session → 重置为 followup；否则选下一个角度
        session_changed = (
            last_log is None or
            last_log.ref_session_id != str(ref_session.id)
        )
        hook_type = "followup" if session_changed else await pick_next_hook(user_id, tier, db)

        copy = await generate_copy(context, hook_type)
        copy["hook_index"]      = None
        copy["ref_session_id"]  = str(ref_session.id)
        copy["ref_session_date"] = context["ref_session_date"]

    # Step 3: 发送 APNs
    ok = await send_apns(
        token   = token,
        title   = copy["title"],
        body    = copy["body"],
        extra   = {"action": "open_chat"},
        sandbox = sandbox,
    )

    # Step 4: 写日志
    if ok:
        result = await db.execute(
            text("""
                INSERT INTO notification_log
                  (user_id, sent_at, tier, hook_type, hook_index,
                   title, body, ref_session_id, ref_session_date)
                VALUES
                  (:uid, NOW(), :tier, :hook, :hidx,
                   :title, :body, :ref_id, :ref_date)
                RETURNING id
            """),
            {
                "uid":      user_id,
                "tier":     copy["tier"],
                "hook":     copy["hook_type"],
                "hidx":     copy.get("hook_index"),
                "title":    copy["title"],
                "body":     copy["body"],
                "ref_id":   copy.get("ref_session_id"),
                "ref_date": copy.get("ref_session_date"),
            },
        )
        await db.commit()
        log_id = result.fetchone()[0]
        logger.info(
            f"[Notify] sent user={user_id[:8]} tier={copy['tier']} "
            f"hook={copy['hook_type']} nid={log_id} title='{copy['title']}'"
        )
    else:
        logger.warning(f"[Notify] send failed user={user_id[:8]}")


# ── 8. 批量入口 ──────────────────────────────────────────────────────────────

async def process_batch(timezones: list[str]):
    async with AsyncSessionLocal() as db:
        users = await get_eligible_users(timezones, db)
        logger.info(f"[Notify] batch start timezones={timezones} eligible={len(users)}")

        for user_row in users:
            try:
                await process_one_user(user_row, db)
            except Exception as e:
                logger.error(f"[Notify] user={str(user_row.id)[:8]} error={e}", exc_info=True)
                continue

        logger.info(f"[Notify] batch done timezones={timezones}")
