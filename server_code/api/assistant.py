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
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from datetime import datetime, timezone
from pydantic import BaseModel

from database.connection import get_db
from database.models import AnalysisResult, StrategyAnalysis, User, Session
from auth.jwt_handler import get_current_user_id

logger = logging.getLogger(__name__)
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
) -> str:
    """Build the complete prompt for Gemini"""
    mem_block = f"\nRelevant memory context:\n{memory_context}" if memory_context else ""
    summary_block = f"\nWork conversation summary:\n{conversation_summary}" if conversation_summary else ""

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

    return (
        f"SYSTEM REQUIREMENT: You MUST respond in English only. Do not use Chinese or any other language under any circumstances, even if the context below is in Chinese.\n\n"
        f"You are the user's workplace AI assistant who understands their work situation. Answer what they ask and follow the natural flow of conversation.\n\n"
        f"{skill_block}"
        f"{summary_block}"
        f"{mem_block}"
        f"{history_block}\n\n"
        f"{task_desc}"
        f"{suggestions_instruction}\n\n"
        f"IMPORTANT: Your ENTIRE response must be in English only. Do not write any Chinese characters."
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
                text = getattr(chunk, "text", None)
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


async def _generate_suggestions(context: str, skill_name: str) -> List[str]:
    """Generate follow-up suggestions based on the current reply (non-streaming, fast call)"""
    prompt = (
        f"Based on the following AI Assistant reply about the {skill_name} skill:\n\n"
        f'"{context[:600]}"\n\n'
        f"Generate 4 short follow-up questions the user might ask (in English, under 15 words each).\n"
        f"Output only a JSON array, no other content.\n"
        f'Example: ["question1","question2","question3","question4"]'
    )
    try:
        genai.configure(api_key=GEMINI_API_KEY)
        model = genai.GenerativeModel(ASSISTANT_MODEL, safety_settings=_GEMINI_SAFETY)
        resp = await asyncio.to_thread(model.generate_content, prompt)
        raw = resp.text.strip()
        # 去掉可能的 markdown 代码块
        if raw.startswith("```"):
            raw = raw.split("```")[1]
            if raw.startswith("json"):
                raw = raw[4:]
        items = json.loads(raw)
        if isinstance(items, list) and len(items) >= 4:
            return items[:4]
    except Exception as exc:
        logger.warning(f"[assistant] suggestions 生成失败: {exc}")
    return []


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


async def _init_skill_matching(
    session_id: str,
    message: str,
    user_id: str,
    sse_queue: asyncio.Queue,
) -> None:
    """
    fire-and-forget：第1轮对话结束后，异步执行技能匹配并 UPSERT strategy_analysis。
    匹配完成后向 sse_queue 推送 skill_tags 事件；失败时推送 None 以解除 generator 阻塞。
    """
    id8 = session_id[:8]
    logger.info(f"[CHAT:{id8}] skill_matching started")
    try:
        from database.connection import AsyncSessionLocal
        from skills.router import match_skills_v2
        from sqlalchemy import func as sa_func

        transcript_stub = [{"speaker": "user", "text": message}]

        async with AsyncSessionLocal() as db:
            stubs = await match_skills_v2(
                transcript=transcript_stub,
                profiles=None,
                user_id=user_id,
                db=db,
                model=None,
            )

        # 对话会话阈值 75（review 为 90，此处二次过滤保留 emotion_recognition 兜底）
        stubs = [
            s for s in stubs
            if (s.get("score") or 0) >= 75 or s.get("skill_id") == "emotion_recognition"
        ]

        skill_tags = [
            {"skill_id": s["skill_id"], "skill_name": s["skill_name"]}
            for s in stubs
        ]
        logger.info(f"[CHAT:{id8}] skill_matching done | tags={[t['skill_id'] for t in skill_tags]}")

        # UPSERT strategy_analysis（iOS 重试时不重复插入）
        async with AsyncSessionLocal() as db:
            stmt = pg_insert(StrategyAnalysis).values(
                id=uuid.uuid4(),
                session_id=uuid.UUID(session_id),
                visual_data=[],
                strategies=[],
                applied_skills=[{"skill_id": s["skill_id"], "priority": 100} for s in stubs],
                skill_cards=stubs,
                scene_category="chat",
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

        # 通知 SSE generator 推送 skill_tags
        await sse_queue.put({"type": "skill_tags", "tags": skill_tags})

    except Exception as e:
        logger.error(f"[CHAT:{id8}] _init_skill_matching failed | error={str(e)}")
        try:
            await sse_queue.put(None)  # 解除 generator 阻塞
        except Exception:
            pass


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

    _sse_skill_queue: Optional[asyncio.Queue] = None
    if req.is_chat_session and _session_turn == 0 and req.message not in ("__INIT__", "__SWITCH__"):
        _sse_skill_queue = asyncio.Queue()
        asyncio.create_task(
            _init_skill_matching(req.session_id, req.message, user_id, _sse_skill_queue)
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

    # 5. 组装 prompt
    prompt = _build_prompt(
        skill_name=skill_name,
        skill_content_json=skill_content_json,
        conversation_summary=conv_summary,
        memory_context=memory_context,
        history=req.history,
        message=req.message,
    )

    # 6. SSE 生成器
    async def event_generator():
        # 元数据事件（最先）
        yield _sse({"type": "meta", "skill_name": skill_name, "memory_used": memory_used})

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

        # 解析 suggestions
        suggestions: List[str] = []
        if MARKER_END in suggestions_raw:
            raw_json = suggestions_raw.split(MARKER_END)[0].strip()
            try:
                parsed = json.loads(raw_json)
                suggestions = parsed.get("items", []) if isinstance(parsed, dict) else parsed
            except Exception:
                pass

        # 若 Gemini 未输出 suggestions，单独调用生成
        if not suggestions and full_text:
            suggestions = await _generate_suggestions(full_text, skill_name)

        if suggestions:
            yield _sse({"type": "suggestions", "items": suggestions[:4]})

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

        yield _sse({"type": "done"})

        # 对话会话首轮：等待 skill_tags 推送（最多 8 秒）
        if _sse_skill_queue is not None:
            try:
                _tags_event = await asyncio.wait_for(_sse_skill_queue.get(), timeout=8.0)
                if _tags_event:
                    yield _sse(_tags_event)
                    logger.info(f"[CHAT:{req.session_id[:8]}] skill_tags pushed | tags={[t['skill_id'] for t in _tags_event.get('tags', [])]}")
            except asyncio.TimeoutError:
                logger.warning(f"[CHAT:{req.session_id[:8]}] skill_tags timeout(8s)，跳过")

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
