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
    "followup":      "围绕「事件结果跟进」生成，语气：好奇+关心",
    "emotion":       "围绕「用户情绪后续变化」生成，语气：温柔+陪伴",
    "perspective":   "围绕「换一个角度看同一件事」生成，语气：启发+平静",
    "action":        "围绕「做一件小事改变现状」生成，语气：鼓励+务实",
    "reflection":    "围绕「时间过去后的新感受」生成，语气：沉静+智慧",
    "memory_ref":    "模糊引用用户历史经历，让用户感到被记得，语气：温暖",
    "encouragement": "鼓励用户说出当下状态，语气：温暖+开放",
    "challenge":     "提一个让用户思考的小问题，语气：好奇+轻松",
}

# ── 冷启动模板池（14 条，2 周不重复）────────────────────────────────────────
COLD_TEMPLATES = [
    {"day": 1,  "title": "今天工作顺利吗？",           "body": "职场上有什么卡住的地方，说出来或许就通了"},
    {"day": 2,  "title": "最近有什么烦心事吗？",       "body": "不管大事小事，说出来会轻松很多"},
    {"day": 3,  "title": "和同事相处还好吗？",         "body": "人与人之间的摩擦，往往值得聊聊"},
    {"day": 4,  "title": "今天心情怎么样？",           "body": "好的坏的都可以讲，这里不会评判你"},
    {"day": 5,  "title": "最近睡得好吗？",             "body": "睡不好往往是心里有事，聊聊？"},
    {"day": 6,  "title": "有什么话想说却没地方说？",   "body": "找不到人说的时候，这里随时在"},
    {"day": 7,  "title": "和家人的关系还好吗？",       "body": "亲密关系里的小摩擦，聊出来更容易看清楚"},
    {"day": 8,  "title": "这周过得怎么样？",           "body": "回顾一下，也许有些事值得再想想"},
    {"day": 9,  "title": "最近有让你开心的事吗？",     "body": "好消息也值得被记录下来"},
    {"day": 10, "title": "有没有一件事一直拖着没做？", "body": "说出来，可能就是迈出第一步"},
    {"day": 11, "title": "下周有什么让你担心的事？",   "body": "提前说出来，会比你想的好处理"},
    {"day": 12, "title": "最近有没有让你委屈的事？",   "body": "委屈憋着会很难受，这里可以说"},
    {"day": 13, "title": "有没有一个人你最近想多了解？","body": "关系里的困惑，说出来会更清晰"},
    {"day": 14, "title": "今天想聊什么都可以",         "body": "不需要主题，随便说说就好"},
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
你是一个关心用户的 AI 好友。根据用户最近的对话，生成一条 iOS 推送通知。

用户最近对话：
主题：{ref.card_title or ''}
情绪：{ref.mood_state or ''}{('（' + ref.emotion_type + '）') if ref.emotion_type else ''}
发生在：{_hours_ago(ref.created_at)} 小时前

生成角度：{HOOK_INSTRUCTIONS.get(hook_type, '')}

输出纯 JSON，不要有其他内容：
{{"title": "≤15字", "body": "≤35字"}}

规则：
- 不出现人名、公司名、具体地名
- 口吻像好友发微信，不像 App 推送通知
- 不用感叹号结尾
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
