"""
AI Assistant Chat API
POST /api/v1/assistant/chat  — SSE 流式对话
"""
import os
import re
import json
import uuid
import random
import asyncio
import threading
import logging
import time
from typing import List, Optional

import httpx
import google.generativeai as genai
from fastapi import APIRouter, Depends, HTTPException, Form, File, UploadFile
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from datetime import datetime, timezone, timedelta
from pydantic import BaseModel

from database.connection import get_db
from database.models import AnalysisResult, StrategyAnalysis, User, Session, SkillExecution
from auth.jwt_handler import get_current_user_id

logger = logging.getLogger(__name__)

# ─── Quota Config ─────────────────────────────────────────────────────────────

_PLAN_QUOTA = {
    "com.miclnk.pro.weekly":  {"plan": "weekly",  "chat_limit": 30,   "image_limit": 20,   "period_days": 7},
    "com.miclnk.pro.monthly": {"plan": "monthly", "chat_limit": 100,  "image_limit": 90,   "period_days": 30},
    "com.miclnk.pro.yearly":  {"plan": "yearly",  "chat_limit": None, "image_limit": 1100, "period_days": 365},
}


async def _get_quota_status(user_id: str, db: AsyncSession) -> dict:
    """
    返回用户当前配额状态。
    结构：{plan, chat_limit(None=无限), image_limit, period_start(None=终身), used_chat, used_image}
    """
    from sqlalchemy import func as sa_func

    user_q = await db.execute(select(User).where(User.id == uuid.UUID(user_id)))
    user = user_q.scalar_one_or_none()

    quota: dict = {"plan": "free", "chat_limit": 5, "image_limit": 5, "period_start": None}

    if user:
        tier = getattr(user, "subscription_tier", None) or "free"
        expires = getattr(user, "subscription_expires_at", None)
        product_id = getattr(user, "subscription_product_id", None)
        sub_period_start = getattr(user, "sub_period_start", None)

        # 过期检查
        if tier == "pro" and expires:
            exp = expires if expires.tzinfo else expires.replace(tzinfo=timezone.utc)
            if exp < datetime.now(timezone.utc):
                tier = "free"
                product_id = None

        if tier == "pro" and product_id and product_id in _PLAN_QUOTA:
            pq = _PLAN_QUOTA[product_id]
            quota["plan"] = pq["plan"]
            quota["chat_limit"] = pq["chat_limit"]   # None = 无限
            quota["image_limit"] = pq["image_limit"]

            # 计算当前周期 start（基于 sub_period_start 滚动）
            if sub_period_start:
                now = datetime.now(timezone.utc)
                sp = sub_period_start if sub_period_start.tzinfo else sub_period_start.replace(tzinfo=timezone.utc)
                elapsed_days = max(0, (now - sp).days)
                periods_elapsed = elapsed_days // pq["period_days"]
                quota["period_start"] = sp + timedelta(days=periods_elapsed * pq["period_days"])
            else:
                now = datetime.now(timezone.utc)
                quota["period_start"] = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

    # 统计 used_chat（free 无日期过滤 = 终身计数）
    chat_q = select(sa_func.count(Session.id)).where(
        Session.user_id == uuid.UUID(user_id),
        Session.session_type == "chat",
    )
    if quota["period_start"]:
        chat_q = chat_q.where(Session.created_at >= quota["period_start"])
    quota["used_chat"] = (await db.execute(chat_q)).scalar() or 0

    # 统计 used_image
    img_q = select(sa_func.count(Session.id)).where(
        Session.user_id == uuid.UUID(user_id),
        Session.session_type == "chat",
        Session.cover_image_url.isnot(None),
    )
    if quota["period_start"]:
        img_q = img_q.where(Session.created_at >= quota["period_start"])
    quota["used_image"] = (await db.execute(img_q)).scalar() or 0

    logger.info(
        f"[quota] user={user_id[:8]} plan={quota['plan']} "
        f"chat={quota['used_chat']}/{quota['chat_limit']} "
        f"image={quota['used_image']}/{quota['image_limit']}"
    )
    return quota

# ─── Skill Resource Loader ───────────────────────────────────────────────────

_SKILLS_DIR = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "skills"))

def _load_skill_resource(skill_id: str) -> str:
    """Load resource.md for a skill. Returns empty string if file not found."""
    path = os.path.join(_SKILLS_DIR, skill_id, "resource.md")
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""
    except Exception as e:
        logger.warning(f"[assistant] load_skill_resource({skill_id}) error: {e}")
        return ""


def _load_skill_note(skill_id: str) -> str:
    """Load note.md template for a skill. Returns empty string if file not found."""
    path = os.path.join(_SKILLS_DIR, skill_id, "note.md")
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""
    except Exception as e:
        logger.warning(f"[assistant] load_skill_note({skill_id}) error: {e}")
        return ""


def _extract_note_questions(note_content: str) -> str:
    """
    从 note.md 中提取问卷话术段落的问题文本，
    用于直接输出给用户（跳过 Gemini）。
    支持中英文标题：'AI 初始化问卷话术' 或 'AI Onboarding Script'
    提取范围：## 标题 下方，到下一个 --- 分隔符之前。
    """
    import re
    m = re.search(
        r"## (?:AI 初始化问卷话术|AI Onboarding Script)\s*\n(.*?)(?:\n---|\Z)",
        note_content,
        re.DOTALL,
    )
    if not m:
        return ""
    section = m.group(1).strip()
    # 去掉 Markdown 标记：引用块(>)、粗体(**)、代码块(`)
    section = re.sub(r"^\s*>\s*", "", section, flags=re.MULTILINE)
    section = re.sub(r"\*\*([^*]+)\*\*", r"\1", section)
    section = re.sub(r"`([^`]+)`", r"\1", section)
    # 把反引号剩余符号清掉
    section = section.replace("`", "")
    return section.strip()


router = APIRouter()

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
ASSISTANT_MODEL = "gemini-2.5-flash"

# Gemini safety settings — applied to all model calls
_GEMINI_SAFETY = [
    {"category": "HARM_CATEGORY_HARASSMENT",        "threshold": "BLOCK_MEDIUM_AND_ABOVE"},
    {"category": "HARM_CATEGORY_HATE_SPEECH",       "threshold": "BLOCK_MEDIUM_AND_ABOVE"},
    {"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_LOW_AND_ABOVE"},
    {"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_MEDIUM_AND_ABOVE"},
]

# ─── KLIPY Meme Config ────────────────────────────────────────────────────────

KLIPY_APP_KEY = os.getenv("KLIPY_APP_KEY", "")

# 情感类别 → KLIPY 搜索词
MEME_QUERIES: dict[str, str] = {
    "feel_you":      "i feel you reaction",
    "hang_in_there": "you got this hang in there",
    "this_is_fine":  "this is fine",
    "mind_blown":    "mind blown reaction",
    "seriously":     "seriously reaction eye roll",
    "celebration":   "congratulations well done",
    "same":          "same relatable reaction",
    "thinking":      "hmm thinking",
}

# 内存缓存（搜索词 → URL列表），每小时刷新
_klipy_cache: dict[str, list[str]] = {}
_klipy_cache_ts: dict[str, float] = {}
_KLIPY_CACHE_TTL = 3600


# ─── Request / Response Models ────────────────────────────────────────────────

class ChatHistoryItem(BaseModel):
    role: str    # "user" | "assistant"
    content: str

class AssistantChatRequest(BaseModel):
    session_id: str
    skill_id: str
    message: str          # "__INIT__" 表示首次自动触发
    history: List[ChatHistoryItem] = []
    image_base64_list: Optional[List[str]] = None  # 用户上传的图片列表（JPEG base64，最多3张），仅传给 Gemini 不落库
    is_chat_session: bool = False   # True = 对话式会话模式（无需预先录音分析）
    skill_mode: str = "auto"        # "auto" | "manual"
    user_language: Optional[str] = "en"  # 用户语言，影响 prompt 语言提示


# ─── Helpers ──────────────────────────────────────────────────────────────────

def _sse(event: dict) -> str:
    return f"data: {json.dumps(event, ensure_ascii=False)}\n\n"


def _build_prompt(
    skill_name: str,
    skill_content_json: str,
    conversation_summary: str,
    memory_context: str,
    history: List[ChatHistoryItem],
    message: str,
    user_language: Optional[str] = None,
    skill_resource: str = "",
    baseline_text: str = "",
    baseline_init_note: str = "",
) -> str:
    """Build the complete prompt for Gemini"""
    mem_block = f"\nRelevant memory context:\n{memory_context}" if memory_context else ""
    summary_block = f"\nWork conversation summary:\n{conversation_summary}" if conversation_summary else ""
    resource_block = f"\nSkill reference material:\n{skill_resource}\n" if skill_resource else ""
    baseline_block = f"\nUser background for this skill:\n{baseline_text}\n" if baseline_text else ""

    history_block = ""
    if history:
        lines = []
        for h in history:
            prefix = "User" if h.role == "user" else "AI"
            lines.append(f"{prefix}: {h.content}")
        history_block = "\nConversation history:\n" + "\n".join(lines)

    # Skill content: show full detail for early turns, abbreviate later to save tokens
    history_turns = len(history) // 2  # each turn = 1 user + 1 AI message
    if history_turns < 3:
        skill_block = f"Work context reference ({skill_name}):\n{skill_content_json}"
    else:
        skill_block = f"Work context reference ({skill_name}): [known skill context, omitted to save tokens]"

    # Baseline init block: injected when user's background for this skill is not yet collected
    if baseline_init_note:
        if history_turns == 1:
            baseline_init_block = (
                f"\nBASELINE COLLECTION (First session for \"{skill_name}\"):\n"
                f"After addressing the user's message, naturally ask for key background info (required fields only). "
                f"Do NOT output [BASELINE_DATA] in this turn — only ask the questions.\n\n"
                f"{baseline_init_note}\n"
            )
        else:
            baseline_init_block = (
                f"\nBASELINE CAPTURE ({skill_name}):\n"
                f"The user just responded to your background questions. "
                f"After the [/SUGGESTIONS] block, output the confirmed baseline data:\n"
                f"[BASELINE_DATA]{{\"field1\":\"value\",\"field2\":\"value\",...}}[/BASELINE_DATA]\n"
                f"Use field keys from the note template. Use \"\" for unknown values. "
                f"This block is hidden from the user.\n\n"
                f"{baseline_init_note}\n"
            )
    else:
        baseline_init_block = ""

    if message == "__INIT__":
        task_desc = (
            f"Based on the context above, write a friendly opening message (2-3 sentences):\n"
            f"1. Briefly summarize the key point you noticed in the conversation\n"
            f"2. Describe how you can help\n"
            f"3. End with an open-ended question\n"
            f"Tone should be warm and natural, like a knowledgeable friend."
        )
    elif message == "__SWITCH__":
        task_desc = (
            f"The user just switched to the \"{skill_name}\" skill.\n"
            f"Write 1-2 sentences naturally transitioning into this topic, briefly explaining how \"{skill_name}\" can help, "
            f"without repeating previous conversation content, and end with a targeted question. Keep the tone light and natural."
        )
    elif message == "__VOICE__":
        task_desc = (
            "The user sent a voice message (the audio is attached at the start of this request). "
            "Listen to what they said and respond naturally as their workplace AI assistant. "
            "Empathize with their situation and provide helpful, targeted advice."
        )
    else:
        task_desc = (
            f"User says: {message}\n\n"
            f"Respond directly to the user's message. "
            f"If it relates to their work context, use that context to give more targeted advice; "
            f"if they're asking about something else, just help them directly without forcing it into the work context."
        )

    suggestions_instruction = (
        "\n\n---\n"
        "At the end of your reply, on a new line, strictly output 4 follow-up questions the user might ask (no numbering):\n"
        '[SUGGESTIONS]{"items":["question1","question2","question3","question4"]}[/SUGGESTIONS]\n'
        "Questions should be concise (under 15 words), closely related to this reply.\n\n"
        "Then after [/SUGGESTIONS], on a new line, output a meme tag based on the emotional tone of your reply:\n"
        "[MEME:category] or [MEME:none] (use none if inappropriate)\n"
        "Available categories and when to use them:\n"
        "  feel_you=user was criticized/hurt/treated unfairly  hang_in_there=encouraging user to keep going\n"
        "  this_is_fine=accepting workplace reality with resignation  mind_blown=aha moment/key insight\n"
        "  seriously=joking/venting about absurd work situations  celebration=user achieved goal/good news\n"
        "  same=shared feeling/relatability  thinking=deep analysis/strategic advice\n"
        "【Do NOT send meme when】: user is very distressed, serious conflict of interests, or reply is longer than 3 paragraphs → output [MEME:none]"
    )

    # 根据客户端设备语言动态生成语言指令
    lang_code = (user_language or "en").lower().split("-")[0]
    if lang_code == "zh":
        lang_instruction_start = "系统要求：你必须全程用中文回复。无论下面的上下文是英文还是其他语言，都必须用中文作答。\n\n"
        lang_instruction_end   = "重要：你的全部回复必须使用中文，包括建议选项。"
    else:
        lang_instruction_start = "SYSTEM REQUIREMENT: You MUST respond in English only. Do not use Chinese or any other language under any circumstances.\n\n"
        lang_instruction_end   = "IMPORTANT: Your ENTIRE response must be in English only."

    return (
        f"{lang_instruction_start}"
        f"You are the user's workplace AI assistant who understands their work situation. Answer what they ask and follow the natural flow of conversation.\n\n"
        f"{skill_block}"
        f"{resource_block}"
        f"{baseline_init_block}"
        f"{baseline_block}"
        f"{summary_block}"
        f"{mem_block}"
        f"{history_block}\n\n"
        f"{task_desc}"
        f"{suggestions_instruction}\n\n"
        f"{lang_instruction_end}"
    )


async def _fetch_klipy_gif(category: str) -> Optional[str]:
    """根据情感类别从 KLIPY 获取一个 GIF URL（带内存缓存，1小时刷新）"""
    if not KLIPY_APP_KEY:
        logger.warning("[meme] KLIPY_APP_KEY 未配置，跳过梗图")
        return None
    query = MEME_QUERIES.get(category)
    if not query:
        return None

    now = time.time()
    if query in _klipy_cache and now - _klipy_cache_ts.get(query, 0) < _KLIPY_CACHE_TTL:
        urls = _klipy_cache[query]
        return random.choice(urls) if urls else None

    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(
                f"https://api.klipy.com/api/v1/{KLIPY_APP_KEY}/gifs/search",
                params={
                    "q": query,
                    "per_page": 20,
                    "content_filter": "high",
                    "format_filter": "gif",
                },
            )
            data = resp.json()
        # KLIPY 响应结构：data.data[].file.sm.gif.url
        urls = [
            r["file"]["sm"]["gif"]["url"]
            for r in data.get("data", {}).get("data", [])
            if r.get("file", {}).get("sm", {}).get("gif", {}).get("url")
        ]
        _klipy_cache[query] = urls
        _klipy_cache_ts[query] = now
        logger.info(f"[meme] KLIPY 缓存更新 query='{query}' count={len(urls)}")
        return random.choice(urls) if urls else None
    except Exception as exc:
        logger.warning(f"[meme] KLIPY API 失败 query='{query}': {exc}")
        return None


async def _stream_gemini(prompt: str, image_base64_list: Optional[List[str]] = None):
    """在线程中运行 Gemini 流式生成，通过 asyncio.Queue 桥接到协程"""
    import base64
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()

    def _run():
        try:
            genai.configure(api_key=GEMINI_API_KEY)
            model = genai.GenerativeModel(ASSISTANT_MODEL, safety_settings=_GEMINI_SAFETY)
            if image_base64_list:
                image_parts = [
                    genai.protos.Part(
                        inline_data=genai.protos.Blob(
                            mime_type="image/jpeg",
                            data=base64.b64decode(b64)
                        )
                    )
                    for b64 in image_base64_list[:3]  # 最多3张
                ]
                count = len(image_parts)
                hint = f"(The user also sent {count} image(s). Please incorporate the image content in your response.)"
                full_prompt = prompt + "\n\n" + hint
                contents = image_parts + [full_prompt]
            else:
                contents = prompt
            response = model.generate_content(contents, stream=True)
            for chunk in response:
                try:
                    text = chunk.text
                except (ValueError, AttributeError):
                    text = None
                if text:
                    loop.call_soon_threadsafe(queue.put_nowait, ("token", text))
            loop.call_soon_threadsafe(queue.put_nowait, ("done", None))
        except Exception as exc:
            loop.call_soon_threadsafe(queue.put_nowait, ("error", str(exc)))

    thread = threading.Thread(target=_run, daemon=True)
    thread.start()

    while True:
        event_type, content = await queue.get()
        yield event_type, content
        if event_type in ("done", "error"):
            break


async def _stream_gemini_with_audio(prompt: str, audio_bytes: bytes, audio_mime_type: str = "audio/m4a"):
    """在线程中运行 Gemini 流式生成（音频输入），通过 asyncio.Queue 桥接到协程。
    audio_bytes 直接传给 SDK inline_data，无需 base64 编码。"""
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()

    def _run():
        try:
            genai.configure(api_key=GEMINI_API_KEY)
            model = genai.GenerativeModel(ASSISTANT_MODEL, safety_settings=_GEMINI_SAFETY)
            audio_part = genai.protos.Part(
                inline_data=genai.protos.Blob(
                    mime_type=audio_mime_type,
                    data=audio_bytes,
                )
            )
            contents = [audio_part, prompt]
            response = model.generate_content(contents, stream=True)
            for chunk in response:
                try:
                    text = chunk.text
                except (ValueError, AttributeError):
                    text = None
                if text:
                    loop.call_soon_threadsafe(queue.put_nowait, ("token", text))
            loop.call_soon_threadsafe(queue.put_nowait, ("done", None))
        except Exception as exc:
            loop.call_soon_threadsafe(queue.put_nowait, ("error", str(exc)))

    thread = threading.Thread(target=_run, daemon=True)
    thread.start()

    while True:
        event_type, content = await queue.get()
        yield event_type, content
        if event_type in ("done", "error"):
            break


async def _transcribe_audio(audio_bytes: bytes, audio_mime_type: str) -> str:
    """Quick non-streaming Gemini call to get the user's speech as text.
    Returns the raw transcription; empty string on failure."""
    def _run():
        genai.configure(api_key=GEMINI_API_KEY)
        _model = genai.GenerativeModel(ASSISTANT_MODEL, safety_settings=_GEMINI_SAFETY)
        audio_part = genai.protos.Part(
            inline_data=genai.protos.Blob(mime_type=audio_mime_type, data=audio_bytes)
        )
        resp = _model.generate_content(
            [audio_part,
             "Transcribe exactly what the user said in this audio clip. "
             "Output only the transcription in the original language, nothing else."]
        )
        return (resp.text or "").strip()

    return await asyncio.to_thread(_run)


async def _generate_suggested_questions(
    user_message: str,
    ai_reply: str,
    history: list,
    skill_name: str,
    language: str,
) -> List[str]:
    """从用户角度生成3个猜你想问（主流结束后调用，基于AI本次回复内容）"""
    lang_code = (language or "en").lower().split("-")[0]
    recent = history[-4:] if len(history) > 4 else history
    ctx_lines = []
    for m in recent:
        # history items may be Pydantic models (attr access) or dicts
        if hasattr(m, "get"):
            role_val = m.get("role", "user")
            content_val = m.get("content", "")
        else:
            role_val = getattr(m, "role", "user")
            content_val = getattr(m, "content", "")
        role_label = "用户" if role_val == "user" else "AI"
        ctx_lines.append(f"{role_label}: {str(content_val)[:120]}")
    ctx = "\n".join(ctx_lines)

    if lang_code == "zh":
        prompt = (
            f"对话背景（最近几轮）：\n{ctx}\n\n"
            f"用户刚才说：{user_message[:200]}\n\n"
            f"AI刚才的回复：{ai_reply[:400]}\n\n"
            f"根据以上情绪事件，生成3个「下一幕场景」——用户在这件事发生后，可能经历的具体画面。要求：\n"
            f"- 描述一个有画面感的时间/地点/动作，用现在进行时\n"
            f"- 不是问题，不是建议，是一个场景片段\n"
            f"- 每条不超过15字，简洁直接\n"
            f"- 场景要真实、有代入感，可以是独处/倾诉/行动/回忆等\n"
            f"- 仅输出JSON数组，不要任何其他文字\n"
            f'示例：["散会后一个人坐在工位前发呆…","下班走在路上，脑子里反复回放那一幕…","回到家，跟朋友倾诉今天的事…"]'
        )
    else:
        prompt = (
            f"Conversation context (recent turns):\n{ctx}\n\n"
            f"User just said: {user_message[:200]}\n\n"
            f"AI just replied: {ai_reply[:400]}\n\n"
            f"Based on this emotional event, generate 3 'next scene' continuations — specific visual moments the user might experience after this. Requirements:\n"
            f"- Describe a vivid scene with a time, place, or action — present tense\n"
            f"- NOT a question or advice — a scene fragment\n"
            f"- Under 12 words each, short and evocative\n"
            f"- Real and relatable: alone processing it, venting to someone, taking action, replaying it, etc.\n"
            f"- Output only a JSON array, no other text\n"
            f'Example: ["Sitting alone at my desk after the meeting…","Walking home, replaying every word in my head…","Telling my best friend what just happened…"]'
        )
    try:
        genai.configure(api_key=GEMINI_API_KEY)
        model = genai.GenerativeModel(ASSISTANT_MODEL, safety_settings=_GEMINI_SAFETY)
        resp = await asyncio.to_thread(model.generate_content, prompt)
        raw = resp.text.strip()
        if raw.startswith("```"):
            raw = raw.split("```")[1]
            if raw.startswith("json"):
                raw = raw[4:]
        items = json.loads(raw)
        if isinstance(items, list) and len(items) >= 3:
            return items[:3]
    except Exception as exc:
        logger.warning(f"[assistant] suggested_questions 生成失败: {exc}")
    return []


async def _async_update_dynamic_kg(session_id: str, user_id: str) -> None:
    """
    fire-and-forget：退出时将本次对话写入的 KG 事件/目标 UUID
    追加到 skill_notes.dynamic_kg_ids（去重）。
    """
    from database.connection import AsyncSessionLocal
    from database.models import KgEvent, KgGoal, StrategyAnalysis
    from sqlalchemy import select as sa_select, text as sa_text_d, bindparam
    from sqlalchemy.dialects.postgresql import ARRAY
    from sqlalchemy import UUID as SA_UUID

    id8 = session_id[:8]
    try:
        async with AsyncSessionLocal() as db:
            # 1. 从 strategy_analysis 取主技能 ID
            _sa_q = await db.execute(
                sa_select(StrategyAnalysis.skill_cards).where(
                    StrategyAnalysis.session_id == uuid.UUID(session_id)
                )
            )
            skill_cards = _sa_q.scalar_one_or_none() or []
            primary_skill_id = None
            for card in (skill_cards or []):
                sid = card.get("skill_id", "")
                if sid and sid not in ("emotion_recognition", "depression_prevention"):
                    primary_skill_id = sid
                    break
            if not primary_skill_id:
                primary_skill_id = next((c.get("skill_id") for c in (skill_cards or [])), None)
            if not primary_skill_id:
                logger.info(f"[CHAT:{id8}] update_dynamic_kg: no primary skill, skip")
                return

            # 2. 查本次会话写入的 KG 事件/目标 ID
            uid = uuid.UUID(user_id)
            sess_id = uuid.UUID(session_id)
            _ev_q = await db.execute(
                sa_select(KgEvent.id).where(
                    KgEvent.session_id == sess_id,
                    KgEvent.user_id == uid,
                )
            )
            _go_q = await db.execute(
                sa_select(KgGoal.id).where(
                    KgGoal.session_id == sess_id,
                    KgGoal.user_id == uid,
                )
            )
            new_ids = {str(r[0]) for r in _ev_q.all()} | {str(r[0]) for r in _go_q.all()}
            if not new_ids:
                logger.info(f"[CHAT:{id8}] update_dynamic_kg: no new KG nodes, skip")
                return

            # 3. 取当前 dynamic_kg_ids，Python 侧去重合并
            _cur_q = await db.execute(
                sa_text_d(
                    "SELECT dynamic_kg_ids FROM skill_notes "
                    "WHERE user_id = :uid AND skill_id = :sid"
                ),
                {"uid": uid, "sid": primary_skill_id},
            )
            _cur = _cur_q.fetchone()
            _cur_ids = {str(i) for i in (_cur[0] or [])} if _cur else set()
            merged_uuids = [uuid.UUID(i) for i in (_cur_ids | new_ids)]

            # 4. UPSERT dynamic_kg_ids（如无行则 INSERT，否则 UPDATE）
            _array_type = ARRAY(SA_UUID(as_uuid=True))
            if _cur:
                await db.execute(
                    sa_text_d(
                        "UPDATE skill_notes SET dynamic_kg_ids = :ids, last_updated = NOW() "
                        "WHERE user_id = :uid AND skill_id = :sid"
                    ).bindparams(bindparam("ids", type_=_array_type)),
                    {"uid": uid, "sid": primary_skill_id, "ids": merged_uuids},
                )
            else:
                await db.execute(
                    sa_text_d(
                        "INSERT INTO skill_notes (user_id, skill_id, dynamic_kg_ids) "
                        "VALUES (:uid, :sid, :ids)"
                    ).bindparams(bindparam("ids", type_=_array_type)),
                    {"uid": uid, "sid": primary_skill_id, "ids": merged_uuids},
                )
            await db.commit()

        logger.info(
            f"[CHAT:{id8}] dynamic_kg_updated | skill={primary_skill_id} "
            f"added={len(new_ids)} total={len(merged_uuids)}"
        )
    except Exception as e:
        logger.error(f"[CHAT:{id8}] update_dynamic_kg failed | error={e}")


async def _write_skill_baseline(user_id: str, skill_id: str, baseline_text: str) -> None:
    """fire-and-forget: 写入 skill_notes.baseline_text, 设 baseline_complete=true"""
    from database.connection import AsyncSessionLocal
    from sqlalchemy import text as sa_text_w
    id8 = user_id[:8]
    try:
        async with AsyncSessionLocal() as db:
            await db.execute(
                sa_text_w(
                    "INSERT INTO skill_notes (user_id, skill_id, baseline_text, baseline_complete, last_updated) "
                    "VALUES (:uid, :sid, :btext, true, NOW()) "
                    "ON CONFLICT (user_id, skill_id) DO UPDATE "
                    "SET baseline_text = :btext, baseline_complete = true, last_updated = NOW()"
                ),
                {"uid": uuid.UUID(user_id), "sid": skill_id, "btext": baseline_text},
            )
            await db.commit()
        logger.info(f"[KG] baseline_written | user={id8} skill={skill_id} chars={len(baseline_text)}")
    except Exception as e:
        logger.error(f"[KG] baseline_write failed | user={id8} skill={skill_id} error={e}")


# ─── Endpoint ─────────────────────────────────────────────────────────────────

# ── Chat Session：创建 ─────────────────────────────────────────────────────────

class InitChatSessionResponse(BaseModel):
    session_id: str
    created_at: str


@router.post("/assistant/init-chat-session", response_model=InitChatSessionResponse)
async def init_chat_session(
    db: AsyncSession = Depends(get_db),
    user_id: str = Depends(get_current_user_id),
):
    """
    创建 chat 类型 session，立即返回，无任何 AI 调用。
    Phase 1 of chat session implementation.
    """
    logger.info(f"[CHAT:new] init_chat_session | user_id={user_id[:8]}")

    # ── 配额检查：chat 次数 ──────────────────────────────────────────────────
    quota = await _get_quota_status(user_id, db)
    if quota["chat_limit"] is not None and quota["used_chat"] >= quota["chat_limit"]:
        logger.warning(
            f"[CHAT:new] chat_limit_reached | user={user_id[:8]} "
            f"used={quota['used_chat']} limit={quota['chat_limit']} plan={quota['plan']}"
        )
        raise HTTPException(status_code=403, detail="chat_limit_reached")
    # ────────────────────────────────────────────────────────────────────────

    try:
        session = Session(
            user_id=uuid.UUID(user_id),
            session_type="chat",
            status="processing",
            finalize_status="pending",
            image_status="none",
        )
        db.add(session)
        await db.commit()
        await db.refresh(session)

        session_id = str(session.id)
        created_at = session.created_at.isoformat() if session.created_at else datetime.now(timezone.utc).isoformat()

        logger.info(f"[CHAT:{session_id[:8]}] session created | user_id={user_id[:8]}")
        return InitChatSessionResponse(session_id=session_id, created_at=created_at)

    except Exception as e:
        logger.error(f"[CHAT:new] init_chat_session failed | user_id={user_id[:8]} error={str(e)}")
        raise HTTPException(status_code=500, detail="Failed to create chat session")


async def _match_skills_serial(
    session_id: str,
    message: str,
    user_id: str,
    history: Optional[List[ChatHistoryItem]] = None,
) -> list:
    """
    串行技能匹配（Groq ~250ms）：await 后返回 skill_tags list。
    匹配完成同时 UPSERT strategy_analysis，供当轮 prompt 构建使用。
    失败时返回空列表（不阻塞主流程）。
    """
    id8 = session_id[:8]
    logger.info(f"[CHAT:{id8}] skill_matching started (serial/Groq) | history_len={len(history) if history else 0}")
    try:
        from database.connection import AsyncSessionLocal
        from skills.router import match_skills_v2
        from sqlalchemy import func as sa_func

        if history:
            transcript_stub = [
                {"speaker": "user" if h.role == "user" else "assistant", "text": h.content}
                for h in history
            ]
            transcript_stub.append({"speaker": "user", "text": message})
        else:
            transcript_stub = [{"speaker": "user", "text": message}]

        # 从 kg_persons 查出对话中提到的人物及其关系，传给 match_skills_v2 做强制分类
        # 当 kg_person 有关联档案时，用档案的 relationship_type（用户手动标注，更准确）
        full_text = " ".join(item["text"] for item in transcript_stub)
        chat_profiles: list[dict] = []
        try:
            from database.models import KgPerson, Profile as KgProfileModel
            async with AsyncSessionLocal() as db_kg:
                rows_r = await db_kg.execute(
                    select(KgPerson, KgProfileModel.relationship_type)
                    .outerjoin(KgProfileModel, KgPerson.profile_id == KgProfileModel.id)
                    .where(KgPerson.user_id == uuid.UUID(user_id))
                )
                rows = rows_r.all()
                mentioned = [(p, prof_rel) for p, prof_rel in rows if p.name and p.name in full_text]
                chat_profiles = []
                for p, prof_rel in mentioned:
                    if (p.rel_type or "") in ("self", ""):
                        continue
                    # 档案关系优先（用户手动标注），KG推断次之
                    effective_rel_type = (prof_rel or p.rel_type or "").lower().strip()
                    chat_profiles.append({
                        "relationship_type": prof_rel or p.rel_desc or "",
                        "rel_type": effective_rel_type,
                    })
                if chat_profiles:
                    logger.info(f"[CHAT:{id8}] kg_profiles matched | {[(p['rel_type'], p['relationship_type']) for p in chat_profiles]}")
                else:
                    logger.info(f"[CHAT:{id8}] kg_profiles: no person mentioned in transcript")
        except Exception as _e:
            logger.warning(f"[CHAT:{id8}] kg_profiles query failed: {_e}")

        async with AsyncSessionLocal() as db:
            stubs = await match_skills_v2(
                transcript=transcript_stub,
                profiles=chat_profiles or None,
                user_id=user_id,
                db=db,
                model=None,
                use_groq=True,
            )

        skill_tags = [
            {"skill_id": s["skill_id"], "skill_name": s["skill_name"]}
            for s in stubs
        ]
        logger.info(f"[CHAT:{id8}] skill_matching done | tags={[t['skill_id'] for t in skill_tags]}")

        # 从 skills_config.json 推导真实 scene_category（取匹配最多的 category）
        import json as _json, os as _os
        _cfg_path = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "../skills_config.json")
        try:
            with open(_cfg_path) as _f:
                _skills_cfg = _json.load(_f)
            _cat_counter: dict = {}
            for s in stubs:
                _cat = (_skills_cfg.get("system_skills", {}).get(s["skill_id"]) or {}).get("category")
                if _cat and _cat not in ("system",):
                    _cat_counter[_cat] = _cat_counter.get(_cat, 0) + 1
            primary_scene = max(_cat_counter, key=_cat_counter.get) if _cat_counter else "personal_growth"
        except Exception:
            primary_scene = "personal_growth"
        logger.info(f"[CHAT:{id8}] primary_scene resolved | scene={primary_scene}")

        # UPSERT strategy_analysis
        async with AsyncSessionLocal() as db:
            stmt = pg_insert(StrategyAnalysis).values(
                id=uuid.uuid4(),
                session_id=uuid.UUID(session_id),
                visual_data=[],
                strategies=[],
                applied_skills=[{"skill_id": s["skill_id"], "priority": 100} for s in stubs],
                skill_cards=stubs,
                scene_category=primary_scene,
                scene_confidence=1.0,
            ).on_conflict_do_update(
                index_elements=["session_id"],
                set_={
                    "applied_skills": [{"skill_id": s["skill_id"], "priority": 100} for s in stubs],
                    "skill_cards": stubs,
                    "updated_at": sa_func.now(),
                },
            )
            await db.execute(stmt)
            await db.commit()
        logger.info(f"[CHAT:{id8}] strategy_analysis written | skills={len(stubs)}")

        return skill_tags

    except Exception as e:
        logger.error(f"[CHAT:{id8}] _match_skills_serial failed | error={str(e)}")
        return []


@router.post("/assistant/chat")
async def assistant_chat(
    req: AssistantChatRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    # 0. 对话轮数限制（每 session，Free=10轮，Pro=50轮）
    _CHAT_LIMITS = {"free": 10, "pro": 50}
    _user_q = await db.execute(select(User).where(User.id == uuid.UUID(user_id)))
    _user = _user_q.scalar_one_or_none()
    if _user:
        _tier = getattr(_user, "subscription_tier", None) or "free"
        _expires = getattr(_user, "subscription_expires_at", None)
        if _tier == "pro" and _expires:
            _exp = _expires if _expires.tzinfo else _expires.replace(tzinfo=timezone.utc)
            if _exp < datetime.now(timezone.utc):
                _tier = "free"
        _max_turns = _CHAT_LIMITS.get(_tier, _CHAT_LIMITS["free"])
        _used_turns = len(req.history) // 2  # 每轮 = 1条 user + 1条 assistant
        if _used_turns >= _max_turns:
            raise HTTPException(status_code=403, detail="chat_limit_reached")

    # Chat Session 进入日志 & SSE skill_tags 队列
    _session_turn = len(req.history) // 2
    if req.is_chat_session:
        logger.info(f"[CHAT:{req.session_id[:8]}] /chat received | is_chat=True turn={_session_turn}")

    # 串行技能匹配（Groq ~250ms），每轮都匹配，结果供当轮 prompt 使用
    _matched_tags: list = []
    if req.is_chat_session and req.message not in ("__INIT__", "__SWITCH__"):
        _matched_tags = await _match_skills_serial(
            req.session_id, req.message, user_id,
            history=req.history if req.history else None,
        )

    # 1. 取策略分析
    strategy_q = await db.execute(
        select(StrategyAnalysis).where(
            StrategyAnalysis.session_id == uuid.UUID(req.session_id)
        )
    )
    strategy = strategy_q.scalar_one_or_none()
    if not strategy:
        if not req.is_chat_session:
            raise HTTPException(status_code=404, detail="Strategy not found")
        # 对话会话首轮：strategy 尚未写入，使用默认 emotion_recognition
        skill_name = "Emotion Recognition"
        skill_content_json = "{}"
    else:
        # 2. 定位目标技能卡片
        skill_cards: list = strategy.skill_cards or []
        target_card = next(
            (c for c in skill_cards if c.get("skill_id") == req.skill_id), None
        )
        skill_name = target_card.get("skill_name", req.skill_id) if target_card else req.skill_id
        skill_content_json = json.dumps(
            target_card.get("content", {}), ensure_ascii=False, indent=2
        ) if target_card else "{}"

    # 3. 取对话摘要（AnalysisResult）
    conv_summary = ""
    try:
        ar_q = await db.execute(
            select(AnalysisResult).where(
                AnalysisResult.session_id == uuid.UUID(req.session_id)
            )
        )
        ar = ar_q.scalar_one_or_none()
        if ar:
            conv_summary = ar.conversation_summary or ar.summary or ""
    except Exception as exc:
        logger.warning(f"[assistant] 取对话摘要失败: {exc}")

    # 4. 取记忆上下文（PostgreSQL KG，精准人物隔离，替代 mem0 向量搜索）
    memory_used = False
    memory_context = ""
    try:
        from services.knowledge_graph import get_ai_context_kg
        if req.message in ("__INIT__", "__SWITCH__"):
            # INIT/SWITCH：用对话摘要检索背景
            mem_query = conv_summary[:200] or skill_name
        else:
            mem_query = req.message
        memory_context = await asyncio.wait_for(
            get_ai_context_kg(mem_query, user_id, db),
            timeout=3.0,
        )
        memory_used = bool(memory_context)
    except asyncio.TimeoutError:
        logger.warning("[assistant] KG 记忆检索超时(3s)，跳过")
    except Exception as exc:
        logger.warning(f"[assistant] KG 记忆获取失败: {exc}")

    # 5. 加载 skill_notes（Tier 1 必现层 + baseline 初始化检测）
    baseline_text = ""
    needs_baseline_init = False
    _baseline_phase = "ask"   # "ask" | "save"
    baseline_init_note = ""
    history_turns = len(req.history) // 2   # 提前计算，Step 6 也使用
    _SYSTEM_SKILLS = {"emotion_recognition", "depression_prevention"}

    # baseline 检查使用「有效技能 ID」：优先取 strategy_analysis 里第一个非系统技能，
    # 避免 iOS turn=1 仍在用默认 emotion_recognition 导致检查被跳过
    _strategy_skill_id = req.skill_id
    if strategy:
        _non_system_cards = [
            c for c in (strategy.skill_cards or [])
            if c.get("skill_id") not in _SYSTEM_SKILLS
        ]
        if _non_system_cards:
            _strategy_skill_id = _non_system_cards[0]["skill_id"]

    # 串行匹配结果优先（Groq 刚写入的 strategy_analysis 可能还未在本 db session 可见）
    if _matched_tags:
        _first_non_sys = next(
            (t for t in _matched_tags if t["skill_id"] not in _SYSTEM_SKILLS),
            None
        )
        if _first_non_sys:
            _strategy_skill_id = _first_non_sys["skill_id"]
            logger.info(f"[CHAT:{req.session_id[:8]}] effective_skill from Groq | {_strategy_skill_id}")

    logger.info(
        f"[CHAT:{req.session_id[:8]}] baseline_check | req_skill={req.skill_id} "
        f"effective_skill={_strategy_skill_id} history_turns={history_turns}"
    )

    try:
        from sqlalchemy import text as sa_text
        _bn_row = await db.execute(
            sa_text(
                "SELECT baseline_text, baseline_complete FROM skill_notes "
                "WHERE user_id = :uid AND skill_id = :sid"
            ),
            {"uid": uuid.UUID(user_id), "sid": _strategy_skill_id},
        )
        _bn = _bn_row.fetchone()
        _bn_complete = bool(_bn[1]) if _bn else False
        baseline_text = (_bn[0] or "") if _bn_complete else ""

        if baseline_text:
            logger.info(
                f"[CHAT:{req.session_id[:8]}] baseline_text loaded | skill={_strategy_skill_id} chars={len(baseline_text)}"
            )
        elif not _bn_complete and _strategy_skill_id not in _SYSTEM_SKILLS and history_turns >= 1:
            # 首次使用该技能（无 baseline），注入引导模板
            _note = _load_skill_note(_strategy_skill_id)
            if _note:
                needs_baseline_init = True
                baseline_init_note = _note
                _baseline_phase = "ask" if history_turns == 1 else "save"
                logger.info(
                    f"[CHAT:{req.session_id[:8]}] baseline_init | skill={_strategy_skill_id} phase={_baseline_phase}"
                )
    except Exception as exc:
        logger.warning(f"[CHAT:{req.session_id[:8]}] baseline load failed: {exc}")

    # 6. 加载技能 resource.md（turn < 3 时注入，超过则省略节省 token）
    skill_resource = _load_skill_resource(req.skill_id) if history_turns < 3 else ""
    if skill_resource:
        logger.info(f"[CHAT:{req.session_id[:8]}] skill_resource loaded | skill={req.skill_id} chars={len(skill_resource)}")

    # 7. 组装 prompt
    prompt = _build_prompt(
        skill_name=skill_name,
        skill_content_json=skill_content_json,
        conversation_summary=conv_summary,
        memory_context=memory_context,
        history=req.history,
        message=req.message,
        user_language=req.user_language,
        skill_resource=skill_resource,
        baseline_text=baseline_text,
        baseline_init_note=baseline_init_note,
    )

    # 6. SSE 生成器
    async def event_generator():
        # skill_tags 第一个推出（在 meta 之前），iOS 立刻更新 currentSkillId
        if _matched_tags:
            yield _sse({"type": "skill_tags", "tags": _matched_tags})
            logger.info(f"[CHAT:{req.session_id[:8]}] skill_tags pushed (serial) | tags={[t['skill_id'] for t in _matched_tags]}")

        # 元数据事件
        yield _sse({"type": "meta", "skill_name": skill_name, "memory_used": memory_used})

        # baseline ask 阶段：直接输出 note 问题文本，跳过 Gemini
        if needs_baseline_init and _baseline_phase == "ask":
            _note_text = _extract_note_questions(baseline_init_note)
            if _note_text:
                logger.info(f"[CHAT:{req.session_id[:8]}] baseline_ask: streaming note questions directly | chars={len(_note_text)}")
                yield _sse({"type": "token", "content": _note_text})
                yield _sse({"type": "baseline_init", "skill_id": _strategy_skill_id, "phase": "ask"})
                logger.info(f"[CHAT:{req.session_id[:8]}] baseline_init SSE | skill={_strategy_skill_id} phase=ask")
                yield _sse({"type": "done"})
                return
            else:
                # note.md 中没有找到问卷段落，fall through 到 Gemini 生成回复
                logger.warning(f"[CHAT:{req.session_id[:8]}] baseline_ask: no question section in note.md, falling through to Gemini")

        full_text_parts = []
        suggestions_raw = ""
        in_suggestions = False
        pending_buffer = ""   # 用于检测 [SUGGESTIONS] 前缀

        MARKER_START = "[SUGGESTIONS]"
        MARKER_END = "[/SUGGESTIONS]"

        async for event_type, content in _stream_gemini(prompt, image_base64_list=req.image_base64_list):
            if event_type == "error":
                yield _sse({"type": "error", "content": content})
                return

            if event_type == "done":
                break

            # — token —
            if in_suggestions:
                suggestions_raw += content
                continue

            pending_buffer += content

            # 检查是否出现 [SUGGESTIONS] 起始标记
            if MARKER_START in pending_buffer:
                idx = pending_buffer.index(MARKER_START)
                before = pending_buffer[:idx]
                if before:
                    full_text_parts.append(before)
                    yield _sse({"type": "token", "content": before})
                suggestions_raw = pending_buffer[idx + len(MARKER_START):]
                pending_buffer = ""
                in_suggestions = True
                continue

            # 安全输出：保留可能是 MARKER 前缀的尾部
            safe_len = max(0, len(pending_buffer) - len(MARKER_START))
            if safe_len > 0:
                safe_chunk = pending_buffer[:safe_len]
                full_text_parts.append(safe_chunk)
                yield _sse({"type": "token", "content": safe_chunk})
                pending_buffer = pending_buffer[safe_len:]

        # 输出剩余 pending（不含 SUGGESTIONS）
        if pending_buffer and MARKER_START not in pending_buffer:
            full_text_parts.append(pending_buffer)
            yield _sse({"type": "token", "content": pending_buffer})

        full_text = "".join(full_text_parts)

        # 猜你想问：主流结束后用 full_text 启动独立调用，基于AI本次回复
        if req.message not in ("__INIT__", "__SWITCH__") and full_text:
            try:
                _sugg_items = await asyncio.wait_for(
                    _generate_suggested_questions(
                        req.message or "",
                        full_text,
                        list(req.history or []),
                        skill_name,
                        req.user_language or "en",
                    ),
                    timeout=8.0,
                )
                if _sugg_items:
                    yield _sse({"type": "suggestions", "items": _sugg_items})
                    logger.info(f"[CHAT:{req.session_id[:8]}] suggested_questions sent | count={len(_sugg_items)}")
            except asyncio.TimeoutError:
                logger.warning(f"[CHAT:{req.session_id[:8]}] suggested_questions timeout, skipping")

        # 解析 [MEME:category]（隐藏在 suggestions_raw 末尾，不会出现在用户可见文本中）
        if req.message not in ("__INIT__", "__SWITCH__"):
            meme_match = re.search(r"\[MEME:(\w+)\]", suggestions_raw)
            if meme_match:
                meme_cat = meme_match.group(1)
                if meme_cat != "none":
                    try:
                        gif_url = await asyncio.wait_for(
                            _fetch_klipy_gif(meme_cat), timeout=3.0
                        )
                        if gif_url:
                            yield _sse({"type": "meme", "url": gif_url, "category": meme_cat})
                            logger.info(f"[meme] 发送梗图 category={meme_cat}")
                    except asyncio.TimeoutError:
                        logger.warning("[meme] Tenor 请求超时(3s)，跳过")
                    except Exception as exc:
                        logger.warning(f"[meme] 梗图获取失败: {exc}")

        # baseline_init 事件：必须在 done 之前发送，iOS 收到 done 后会关闭连接
        if needs_baseline_init:
            yield _sse({"type": "baseline_init", "skill_id": req.skill_id, "phase": _baseline_phase})
            logger.info(f"[CHAT:{req.session_id[:8]}] baseline_init SSE | skill={req.skill_id} phase={_baseline_phase}")

        yield _sse({"type": "done"})

        # save 阶段：解析 AI 输出的 [BASELINE_DATA] 并写库（在 done 后执行，纯服务端）
        if needs_baseline_init and _baseline_phase == "save":
            _bd_match = re.search(
                r"\[BASELINE_DATA\](.*?)\[/BASELINE_DATA\]", suggestions_raw, re.DOTALL
            )
            if _bd_match:
                _bd_str = _bd_match.group(1).strip()
                try:
                    _bd_obj = json.loads(_bd_str)
                    _bd_lines = [f"{k}: {v}" for k, v in _bd_obj.items() if v]
                    _new_baseline = "\n".join(_bd_lines)
                    if _new_baseline:
                        asyncio.create_task(_write_skill_baseline(user_id, req.skill_id, _new_baseline))
                        logger.info(
                            f"[CHAT:{req.session_id[:8]}] baseline_captured | skill={req.skill_id} chars={len(_new_baseline)}"
                        )
                except Exception as _bd_err:
                    logger.warning(
                        f"[CHAT:{req.session_id[:8]}] baseline_data parse failed: {_bd_err}"
                    )

        # 对话结束后，异步写入 PostgreSQL KG（fire-and-forget，不阻塞 SSE）
        if full_text and req.message not in ("__INIT__", "__SWITCH__"):
            try:
                from services.knowledge_graph import save_kg_from_chat
                history_text = "\n".join(
                    f"{'User' if h.role == 'user' else 'AI'}: {h.content}"
                    for h in req.history[-6:]
                )
                round_content = (
                    f"Skill context: {skill_name}\n"
                    f"Conversation summary: {conv_summary[:200]}\n"
                    f"---\n{history_text}\n"
                    f"User: {req.message}\nAI: {full_text[:500]}"
                )
                asyncio.create_task(
                    save_kg_from_chat(
                        content=round_content,
                        user_id=user_id,
                        session_id=req.session_id,
                        skill_id=req.skill_id,
                        skill_name=skill_name,
                    )
                )
                _log_pfx = f"[CHAT:{req.session_id[:8]}]" if req.is_chat_session else "[KG]"
                logger.info(f"{_log_pfx} KG write triggered | session_id={req.session_id}")
            except Exception as sm_err:
                logger.warning(f"[KG] assistant 触发失败: {sm_err}")

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


# ─── /chat-audio：语音输入版 /chat ──────────────────────────────────────────────

@router.post("/assistant/chat-audio")
async def assistant_chat_audio(
    session_id: str = Form(...),
    skill_id: str = Form(...),
    history_json: str = Form("[]"),
    is_chat_session: bool = Form(True),
    user_language: Optional[str] = Form("en"),
    audio: UploadFile = File(...),
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """
    语音输入版 /chat：接收 multipart/form-data 原始音频（m4a），
    直接传给 Gemini inline_data（无 base64 转换），返回与 /chat 相同格式的 SSE 流。
    """
    # 0. 解析 history
    history: List[ChatHistoryItem] = []
    try:
        history = [ChatHistoryItem(**h) for h in json.loads(history_json)]
    except Exception:
        pass

    # 0. 轮数限制
    _CHAT_LIMITS = {"free": 10, "pro": 50}
    _user_q = await db.execute(select(User).where(User.id == uuid.UUID(user_id)))
    _user = _user_q.scalar_one_or_none()
    if _user:
        _tier = getattr(_user, "subscription_tier", None) or "free"
        _expires = getattr(_user, "subscription_expires_at", None)
        if _tier == "pro" and _expires:
            _exp = _expires if _expires.tzinfo else _expires.replace(tzinfo=timezone.utc)
            if _exp < datetime.now(timezone.utc):
                _tier = "free"
        _max_turns = _CHAT_LIMITS.get(_tier, _CHAT_LIMITS["free"])
        if len(history) // 2 >= _max_turns:
            raise HTTPException(status_code=403, detail="chat_limit_reached")

    # 读取音频 bytes
    audio_bytes = await audio.read()
    audio_mime = audio.content_type or "audio/m4a"
    logger.info(f"[AUDIO:{session_id[:8]}] received | size={len(audio_bytes)} mime={audio_mime}")

    if not audio_bytes:
        raise HTTPException(status_code=400, detail="Empty audio file")

    # 1. Strategy
    strategy_q = await db.execute(
        select(StrategyAnalysis).where(StrategyAnalysis.session_id == uuid.UUID(session_id))
    )
    strategy = strategy_q.scalar_one_or_none()
    if not strategy:
        skill_name = "Emotion Recognition"
        skill_content_json = "{}"
    else:
        skill_cards: list = strategy.skill_cards or []
        target_card = next((c for c in skill_cards if c.get("skill_id") == skill_id), None)
        skill_name = target_card.get("skill_name", skill_id) if target_card else skill_id
        skill_content_json = (
            json.dumps(target_card.get("content", {}), ensure_ascii=False, indent=2)
            if target_card else "{}"
        )

    # 2. 对话摘要
    conv_summary = ""
    try:
        ar_q = await db.execute(
            select(AnalysisResult).where(AnalysisResult.session_id == uuid.UUID(session_id))
        )
        ar = ar_q.scalar_one_or_none()
        if ar:
            conv_summary = ar.conversation_summary or ar.summary or ""
    except Exception as exc:
        logger.warning(f"[AUDIO:{session_id[:8]}] conv summary failed: {exc}")

    # 3. Memory context（用摘要或技能名作为查询 key，因为音频内容服务器侧未知）
    memory_used = False
    memory_context = ""
    try:
        from services.knowledge_graph import get_ai_context_kg
        mem_query = conv_summary[:200] or skill_name
        memory_context = await asyncio.wait_for(
            get_ai_context_kg(mem_query, user_id, db),
            timeout=3.0,
        )
        memory_used = bool(memory_context)
    except asyncio.TimeoutError:
        logger.warning(f"[AUDIO:{session_id[:8]}] KG timeout，跳过")
    except Exception as exc:
        logger.warning(f"[AUDIO:{session_id[:8]}] KG failed: {exc}")

    # 4. Skill resource + baseline text
    history_turns = len(history) // 2
    skill_resource = _load_skill_resource(skill_id) if history_turns < 3 else ""

    baseline_text = ""
    _SYSTEM_SKILLS = {"emotion_recognition", "depression_prevention"}
    _strategy_skill_id = skill_id
    if strategy:
        _non_sys = [c for c in (strategy.skill_cards or []) if c.get("skill_id") not in _SYSTEM_SKILLS]
        if _non_sys:
            _strategy_skill_id = _non_sys[0]["skill_id"]
    try:
        from sqlalchemy import text as sa_text
        _bn_row = await db.execute(
            sa_text("SELECT baseline_text, baseline_complete FROM skill_notes WHERE user_id = :uid AND skill_id = :sid"),
            {"uid": uuid.UUID(user_id), "sid": _strategy_skill_id},
        )
        _bn = _bn_row.fetchone()
        if _bn and _bn[1]:
            baseline_text = _bn[0] or ""
    except Exception as exc:
        logger.warning(f"[AUDIO:{session_id[:8]}] baseline load failed: {exc}")

    # 5. Build prompt（message="__VOICE__" → _build_prompt 里的专用 branch）
    prompt = _build_prompt(
        skill_name=skill_name,
        skill_content_json=skill_content_json,
        conversation_summary=conv_summary,
        memory_context=memory_context,
        history=history,
        message="__VOICE__",
        user_language=user_language,
        skill_resource=skill_resource,
        baseline_text=baseline_text,
    )

    # 6. SSE 生成器
    async def event_generator():
        yield _sse({"type": "meta", "skill_name": skill_name, "memory_used": memory_used})

        # 先转写音频 → 发 transcript 事件给 iOS，iOS 用来更新语音消息内容，
        # 这样 generate-image-from-chat 收到的 conversation 就是真实文字而非占位符
        transcribed_text = ""
        try:
            transcribed_text = await asyncio.wait_for(
                _transcribe_audio(audio_bytes, audio_mime), timeout=15.0
            )
            if transcribed_text:
                yield _sse({"type": "transcript", "text": transcribed_text})
                logger.info(f"[AUDIO:{session_id[:8]}] transcript yielded | len={len(transcribed_text)}")
        except Exception as _exc:
            logger.warning(f"[AUDIO:{session_id[:8]}] transcription failed: {_exc}")

        full_text_parts = []
        suggestions_raw = ""
        in_suggestions = False
        pending_buffer = ""
        MARKER_START = "[SUGGESTIONS]"
        MARKER_END = "[/SUGGESTIONS]"

        async for event_type, content in _stream_gemini_with_audio(prompt, audio_bytes, audio_mime):
            if event_type == "error":
                logger.error(f"[AUDIO:{session_id[:8]}] Gemini error: {content}")
                yield _sse({"type": "error", "content": content})
                return
            if event_type == "done":
                break

            if in_suggestions:
                suggestions_raw += content
                continue

            pending_buffer += content
            if MARKER_START in pending_buffer:
                idx = pending_buffer.index(MARKER_START)
                before = pending_buffer[:idx]
                if before:
                    full_text_parts.append(before)
                    yield _sse({"type": "token", "content": before})
                suggestions_raw = pending_buffer[idx + len(MARKER_START):]
                pending_buffer = ""
                in_suggestions = True
                continue

            safe_len = max(0, len(pending_buffer) - len(MARKER_START))
            if safe_len > 0:
                safe_chunk = pending_buffer[:safe_len]
                full_text_parts.append(safe_chunk)
                yield _sse({"type": "token", "content": safe_chunk})
                pending_buffer = pending_buffer[safe_len:]

        if pending_buffer and MARKER_START not in pending_buffer:
            full_text_parts.append(pending_buffer)
            yield _sse({"type": "token", "content": pending_buffer})

        full_text = "".join(full_text_parts)

        # 猜你想问：主流结束后用 full_text 启动独立调用
        _sugg_msg = transcribed_text or ""
        if _sugg_msg and full_text:
            try:
                _sugg_items = await asyncio.wait_for(
                    _generate_suggested_questions(
                        _sugg_msg[:200],
                        full_text,
                        list(history or []),
                        skill_name,
                        user_language or "en",
                    ),
                    timeout=8.0,
                )
                if _sugg_items:
                    yield _sse({"type": "suggestions", "items": _sugg_items})
                    logger.info(f"[AUDIO:{session_id[:8]}] suggested_questions sent | count={len(_sugg_items)}")
            except asyncio.TimeoutError:
                logger.warning(f"[AUDIO:{session_id[:8]}] suggested_questions timeout, skipping")

        yield _sse({"type": "done"})

        # KG write（用转写文本替代 "[Voice message]" 占位符）
        if full_text:
            try:
                from services.knowledge_graph import save_kg_from_chat
                history_text = "\n".join(
                    f"{'User' if h.role == 'user' else 'AI'}: {h.content}"
                    for h in history[-6:]
                )
                round_content = (
                    f"Skill context: {skill_name}\n"
                    f"Conversation summary: {conv_summary[:200]}\n"
                    f"---\n{history_text}\n"
                    f"User: {transcribed_text or '[Voice message]'}\nAI: {full_text[:500]}"
                )
                asyncio.create_task(
                    save_kg_from_chat(
                        content=round_content,
                        user_id=user_id,
                        session_id=session_id,
                        skill_id=skill_id,
                        skill_name=skill_name,
                    )
                )
                logger.info(f"[AUDIO:{session_id[:8]}] KG write triggered")
            except Exception as exc:
                logger.warning(f"[AUDIO:{session_id[:8]}] KG write failed: {exc}")

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


# ─── Phase 3：退出后处理 ────────────────────────────────────────────────────────

async def _call_gemini_finalize(session_id: str, conversation: list) -> dict:
    """
    单次 Gemini Flash 调用：从完整对话生成 card_title / summary / mood_state / emotion_type / intensity。
    返回解析后的 dict；失败时 raise。
    """
    # 只取用户发言，排除 AI 回复，避免 AI 平和语气稀释情绪信号
    user_msgs = [m for m in conversation if m.get('role') == 'user']
    if not user_msgs:
        return {
            "card_title": "A brief chat session",
            "summary": "A short conversation.",
            "mood_state": "Neutral",
            "emotion_type": "general_venting",
            "intensity": 5,
        }
    conv_text = "\n".join(
        f"User: {m.get('content', '')}"
        for m in user_msgs[:20]
    )

    prompt = f"""You are analyzing what a user shared during a conversation with an AI wellness assistant.

USER'S MESSAGES:
{conv_text}

Based on what the user said, generate a JSON response with exactly these 5 fields:
1. card_title: First-person English title, MAX 15 words, starting with "I"
2. summary: First-person English summary, MAX 40 words, starting with "Today"
3. mood_state: Exactly one of: Happy | Excited | Content | Neutral | Anxious | Frustrated | Sad | Angry | Overwhelmed
4. emotion_type: Exactly one of: workplace_stress | relationship_tension | family_conflict | academic_pressure | self_reflection | general_venting
5. intensity: Integer 1-10

Return ONLY valid JSON, no markdown fences:
{{
  "card_title": "...",
  "summary": "...",
  "mood_state": "...",
  "emotion_type": "...",
  "intensity": 7
}}"""

    genai.configure(api_key=GEMINI_API_KEY)
    model = genai.GenerativeModel(
        ASSISTANT_MODEL,
        generation_config=genai.GenerationConfig(
            temperature=0.3,
            max_output_tokens=2048,
            response_mime_type="application/json",
        ),
    )
    response = await model.generate_content_async(prompt)

    # 安全取 text（finish_reason != STOP 时 .text 可能抛异常）
    try:
        raw = response.text.strip()
    except Exception:
        candidate = response.candidates[0] if response.candidates else None
        raw = ""
        if candidate and candidate.content and candidate.content.parts:
            raw = "".join(p.text for p in candidate.content.parts if hasattr(p, "text")).strip()

    # 剥除 markdown 代码块
    raw = re.sub(r"^```(?:json)?\s*", "", raw)
    raw = re.sub(r"\s*```$", "", raw)
    raw = raw.strip()

    # 用 regex 直接提取 {...} 块，容错 Gemini 可能在 JSON 前后附加文字
    m = re.search(r"\{.*\}", raw, re.DOTALL)
    if m:
        raw = m.group(0)

    # 尝试 json.loads；失败时逐字段 regex 提取，避免截断导致整体失败
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        logger.warning(f"[finalize] json.loads failed, trying field extraction | raw_head={raw[:80]!r}")
        _VALID_MOODS = {"Happy", "Excited", "Content", "Neutral", "Anxious", "Frustrated", "Sad", "Angry", "Overwhelmed"}
        _VALID_EMOTIONS = {"workplace_stress", "relationship_tension", "family_conflict", "academic_pressure", "self_reflection", "general_venting"}

        def _extract_str(key: str) -> str:
            m2 = re.search(rf'"{key}"\s*:\s*"([^"]*)"', raw)
            return m2.group(1) if m2 else ""

        def _extract_int(key: str, default: int) -> int:
            m2 = re.search(rf'"{key}"\s*:\s*(\d+)', raw)
            return int(m2.group(1)) if m2 else default

        card_title  = _extract_str("card_title") or "A chat session"
        summary_txt = _extract_str("summary") or "A brief conversation."
        mood        = _extract_str("mood_state")
        if mood not in _VALID_MOODS:
            mood = "Neutral"
        emo         = _extract_str("emotion_type")
        if emo not in _VALID_EMOTIONS:
            emo = "general_venting"
        intensity   = _extract_int("intensity", 5)
        return {
            "card_title":   card_title,
            "summary":      summary_txt,
            "mood_state":   mood,
            "emotion_type": emo,
            "intensity":    intensity,
        }


async def _async_session_finalize(session_id: str, conversation: list, user_id: str) -> None:
    """
    fire-and-forget：退出时一次 Gemini 调用生成 card_title / summary / mood_state，写回 DB。
    内部自建 AsyncSessionLocal，不依赖 handler 的 db session。
    """
    from database.connection import AsyncSessionLocal
    from sqlalchemy import update as sa_update, func as sa_func

    id8 = session_id[:8]
    logger.info(f"[CHAT:{id8}] finalize started | conv_len={len(conversation)}")

    # ── Step 1: 写入 skill_executions（独立于 Gemini，不受其失败影响）──
    try:
        async with AsyncSessionLocal() as db:
            sa_row = (await db.execute(
                select(StrategyAnalysis).where(StrategyAnalysis.session_id == uuid.UUID(session_id))
            )).scalar_one_or_none()

            if sa_row and sa_row.applied_skills:
                _SKIP_SKILLS = {"emotion_recognition", "depression_prevention"}
                _scene = sa_row.scene_category or "personal_growth"
                _written = 0
                for applied in sa_row.applied_skills:
                    _sid = applied.get("skill_id") if isinstance(applied, dict) else None
                    if not _sid or _sid in _SKIP_SKILLS:
                        continue
                    db.add(SkillExecution(
                        session_id=uuid.UUID(session_id),
                        skill_id=_sid,
                        scene_category=_scene,
                        confidence_score=0.8,
                        execution_time_ms=0,
                        success=True,
                    ))
                    _written += 1
                await db.commit()
                logger.info(f"[CHAT:{id8}] skill_executions written | count={_written} scene={_scene}")
    except Exception as _e:
        logger.error(f"[CHAT:{id8}] skill_executions write failed | error={_e}")

    # ── Step 2: Gemini 生成 card_title / summary / mood（可独立失败）──
    try:
        result = await _call_gemini_finalize(session_id, conversation)
        card_title    = result.get("card_title", "")
        summary       = result.get("summary", "")
        mood_state    = result.get("mood_state", "Neutral")
        emotion_type  = result.get("emotion_type", "general_venting")
        intensity     = int(result.get("intensity", 5))

        # mood_state → mood_score 整数，供 /weekly-stats mood_series 使用
        _MOOD_TO_SCORE = {
            "Excited": 90, "Happy": 82, "Content": 68, "Neutral": 50,
            "Anxious": 32, "Frustrated": 28, "Sad": 22, "Angry": 18, "Overwhelmed": 15,
        }
        mood_score = _MOOD_TO_SCORE.get(mood_state, 50)

        async with AsyncSessionLocal() as db:
            # UPSERT analysis_results（session 可能已有记录，防重）
            stmt = pg_insert(AnalysisResult).values(
                id=uuid.uuid4(),
                session_id=uuid.UUID(session_id),
                dialogues=[],
                card_title=card_title,
                summary=summary,
                mood_score=mood_score,
            ).on_conflict_do_update(
                index_elements=["session_id"],
                set_={
                    "card_title": card_title,
                    "summary": summary,
                    "mood_score": mood_score,
                    "updated_at": sa_func.now(),
                },
            )
            await db.execute(stmt)

            # UPDATE sessions
            await db.execute(
                sa_update(Session)
                .where(Session.id == uuid.UUID(session_id))
                .values(
                    mood_state=mood_state,
                    emotion_type=emotion_type,
                    emotion_intensity=intensity,
                    finalize_status="completed",
                )
            )
            await db.commit()

        logger.info(
            f"[CHAT:{id8}] finalize done | mood={mood_state} "
            f"emotion_type={emotion_type} intensity={intensity} "
            f"card_title_len={len(card_title)}"
        )

    except Exception as e:
        logger.error(f"[CHAT:{id8}] finalize failed | error={str(e)}")
        try:
            from database.connection import AsyncSessionLocal
            from sqlalchemy import update as sa_update
            async with AsyncSessionLocal() as db:
                await db.execute(
                    sa_update(Session)
                    .where(Session.id == uuid.UUID(session_id))
                    .values(finalize_status="failed")
                )
                await db.commit()
        except Exception:
            pass


class CloseChatSessionRequest(BaseModel):
    session_id: str
    conversation: List[ChatHistoryItem] = []


@router.post("/assistant/close-chat-session")
async def close_chat_session(
    req: CloseChatSessionRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    from sqlalchemy import update as sa_update

    id8 = req.session_id[:8]
    logger.info(f"[CHAT:{id8}] close_chat_session received | conv_len={len(req.conversation)}")

    # 1. DB 立即归档（不等后处理，接口快速返回）
    await db.execute(
        sa_update(Session)
        .where(Session.id == uuid.UUID(req.session_id))
        .values(status="archived", finalize_status="pending")
    )
    await db.commit()
    logger.info(f"[CHAT:{id8}] session archived | finalize_status=pending")

    # 2. 保存对话历史到 strategy_analysis（UPSERT，供重入时加载）
    conversation_dicts = [{"role": h.role, "content": h.content} for h in req.conversation]
    try:
        from sqlalchemy import func as sa_func
        stmt = pg_insert(StrategyAnalysis).values(
            id=uuid.uuid4(),
            session_id=uuid.UUID(req.session_id),
            visual_data=[],
            strategies=[],
            applied_skills=[],
            skill_cards=[],
            scene_images=[],
            conversation=conversation_dicts,
        ).on_conflict_do_update(
            index_elements=["session_id"],
            set_={"conversation": conversation_dicts, "updated_at": sa_func.now()},
        )
        await db.execute(stmt)
        await db.commit()
        logger.info(f"[CHAT:{id8}] conversation saved to strategy_analysis | len={len(conversation_dicts)}")
    except Exception as _e:
        logger.warning(f"[CHAT:{id8}] save conversation failed (non-fatal) | error={_e}")

    # 3. fire-and-forget：退出后处理
    asyncio.create_task(
        _async_session_finalize(req.session_id, conversation_dicts, user_id)
    )

    # 4. fire-and-forget：更新 skill_notes.dynamic_kg_ids
    asyncio.create_task(
        _async_update_dynamic_kg(req.session_id, user_id)
    )
    logger.info(f"[CHAT:{id8}] dynamic_kg update triggered")

    # 5. 立即返回 200
    return {"status": "ok", "session_id": req.session_id}


# ─── Phase 4：对话转图片 ────────────────────────────────────────────────────────

class GenerateImageFromChatRequest(BaseModel):
    session_id: str
    conversation: List[ChatHistoryItem] = []
    style_key: str = "spider_verse"


@router.post("/assistant/generate-image-from-chat", status_code=202)
async def generate_image_from_chat(
    req: GenerateImageFromChatRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    from sqlalchemy import update as sa_update
    from database.models import Profile

    id8 = req.session_id[:8]
    logger.info(
        f"[CHAT:{id8}] generate_image_from_chat | conv_len={len(req.conversation)} style={req.style_key}"
    )

    # ── 配额检查：image 次数 ─────────────────────────────────────────────────
    quota = await _get_quota_status(user_id, db)
    if quota["used_image"] >= quota["image_limit"]:
        logger.warning(
            f"[CHAT:{id8}] image_limit_reached | user={user_id[:8]} "
            f"used={quota['used_image']} limit={quota['image_limit']} plan={quota['plan']}"
        )
        raise HTTPException(status_code=403, detail="image_limit_reached")
    # ────────────────────────────────────────────────────────────────────────

    # 1. 构造 synthetic_transcript（仅最后一条 role=="user" 消息）
    #    只取最新一轮用户输入，防止历史轮次内容主导场景提取，确保每轮生图反映当前输入
    _all_user_msgs = [h for h in req.conversation if h.role == "user"]
    _last_user = _all_user_msgs[-1:] if _all_user_msgs else []
    synthetic_transcript = [
        {"text": h.content, "is_me": True, "speaker": "Speaker_0"}
        for h in _last_user
    ]
    logger.info(
        f"[CHAT:{id8}] synthetic_transcript built | user_turns=1/{len(_all_user_msgs)} "
        f"mode=narration last_msg_preview={(_last_user[0].content[:50] if _last_user else '')!r}"
    )
    if not synthetic_transcript:
        raise HTTPException(status_code=400, detail="No user messages in conversation")

    # 2. 查 user profile（relationship_type="自己"/"Self"）→ speaker_mapping
    profile_q = await db.execute(
        select(Profile).where(
            Profile.user_id == uuid.UUID(user_id),
            Profile.relationship_type.in_(["自己", "Self", "self"]),
        ).limit(1)
    )
    profile = profile_q.scalar_one_or_none()
    profile_id = str(profile.id) if profile else None
    speaker_mapping = {"Speaker_0": profile_id} if profile_id else {}

    # 3. DB 更新：image_status="generating"，finalize_status="pending"
    await db.execute(
        sa_update(Session)
        .where(Session.id == uuid.UUID(req.session_id))
        .values(status="archived", image_status="generating", finalize_status="pending")
    )
    await db.commit()

    # 3b. Chat session 无 strategy_analysis，提前创建最小记录，
    #     让 generate_scene_images 能正常写入 scene_images（否则图片会因找不到记录而丢失）
    #     visual_data / strategies 为 NOT NULL，需传空 JSON 对象占位
    #     同时保存 conversation 供重入时加载
    _conv_dicts = [{"role": h.role, "content": h.content} for h in req.conversation]
    await db.execute(
        pg_insert(StrategyAnalysis)
        .values(
            id=uuid.uuid4(),
            session_id=uuid.UUID(req.session_id),
            visual_data={},
            strategies={},
            skill_cards=[],
            conversation=_conv_dicts,
        )
        .on_conflict_do_update(
            index_elements=["session_id"],
            set_={"conversation": _conv_dicts},
        )
    )
    await db.commit()
    logger.info(f"[CHAT:{id8}] strategy_analysis stub created | conv_len={len(_conv_dicts)}")

    # 4. fire-and-forget：生图任务
    from scene_image_generator import generate_scene_images as _gen_scene_imgs
    from main import generate_image_from_prompt as _gen_img_fn
    from main import _fetch_profile_image_from_oss as _fetch_prof_img_fn
    _gemini_model = os.getenv("GEMINI_FLASH_MODEL", ASSISTANT_MODEL)

    # Chat session 固定生成 1 张图片
    _max_images = 1

    asyncio.create_task(_gen_scene_imgs(
        transcript=synthetic_transcript,
        style_key=req.style_key,
        session_id=req.session_id,
        user_id=user_id,
        gemini_flash_model=_gemini_model,
        generate_image_fn=_gen_img_fn,
        fetch_profile_image_fn=_fetch_prof_img_fn,
        speaker_mapping=speaker_mapping,
        max_images=_max_images,
        comic_strip_mode=True,  # AI Chat：多场景合并为单张多格漫画
    ))
    logger.info(
        f"[CHAT:{id8}] scene_image triggered | style={req.style_key} "
        f"max_images={_max_images} comic_strip=True profile_id={profile_id[:8] if profile_id else 'none'}"
    )

    # 5. fire-and-forget：退出后处理（与 close-chat-session 路径相同）
    conversation_dicts = [{"role": h.role, "content": h.content} for h in req.conversation]
    asyncio.create_task(
        _async_session_finalize(req.session_id, conversation_dicts, user_id)
    )

    # 6. 立即返回 202
    return {"status": "generating", "session_id": req.session_id}


# ─── 获取 chat session 历史对话 ────────────────────────────────────────────────

@router.get("/assistant/chat-history/{session_id}")
async def get_chat_history(
    session_id: str,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """返回 chat session 的完整对话历史，用于 iOS 重入时加载。"""
    id8 = session_id[:8]
    logger.info(f"[CHAT:{id8}] get_chat_history requested | user={user_id[:8]}")

    row = (await db.execute(
        select(StrategyAnalysis).where(StrategyAnalysis.session_id == uuid.UUID(session_id))
    )).scalar_one_or_none()

    if row is None or not row.conversation:
        logger.info(f"[CHAT:{id8}] get_chat_history: no conversation found")
        return {"session_id": session_id, "conversation": []}

    logger.info(f"[CHAT:{id8}] get_chat_history: returning {len(row.conversation)} messages")
    return {"session_id": session_id, "conversation": row.conversation}
