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
from pydantic import BaseModel

from database.connection import get_db
from database.models import AnalysisResult, StrategyAnalysis
from auth.jwt_handler import get_current_user_id

logger = logging.getLogger(__name__)
router = APIRouter()

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
ASSISTANT_MODEL = "gemini-2.0-flash"

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
    """组装发给 Gemini 的完整 prompt"""
    mem_block = f"\n相关历史记忆：\n{memory_context}" if memory_context else ""
    summary_block = f"\n职场对话摘要：\n{conversation_summary}" if conversation_summary else ""

    history_block = ""
    if history:
        lines = []
        for h in history:
            prefix = "用户" if h.role == "user" else "AI"
            lines.append(f"{prefix}: {h.content}")
        history_block = "\n对话历史：\n" + "\n".join(lines)

    # 技能内容：轮次少时完整展示，多轮后仅保留名称节省token
    history_turns = len(history) // 2  # 每轮 = 1条用户 + 1条AI
    if history_turns < 3:
        skill_block = f"职场背景参考（{skill_name}）：\n{skill_content_json}"
    else:
        skill_block = f"职场背景参考（{skill_name}）：[已知该技能场景，不再重复展开]"

    if message == "__INIT__":
        task_desc = (
            f"请基于以上背景生成一段友好开场白（2-3句话）：\n"
            f"1. 用一句话概括你注意到的对话关键点\n"
            f"2. 表达你可以帮助的方向\n"
            f"3. 以一个开放性问题结尾\n"
            f"语气亲切自然，像一个了解用户的朋友。"
        )
    elif message == "__SWITCH__":
        task_desc = (
            f"用户刚从之前的话题切换到了「{skill_name}」这个技能。\n"
            f"请用1-2句话自然地承接，简要说明「{skill_name}」能帮到用户的核心点，"
            f"不要重复之前对话的内容，最后以一个针对性的问题结尾。语气轻快自然。"
        )
    else:
        task_desc = (
            f"用户说：{message}\n\n"
            f"请直接回应用户的问题。"
            f"如果问题与职场背景相关，可结合背景给出更有针对性的建议；"
            f"如果用户问的是其他事情，就直接帮他解决，不要强行往背景参考上靠。"
        )

    suggestions_instruction = (
        "\n\n---\n"
        "在你的回复最后，另起一行，严格按以下格式输出4个用户可能追问的问题（不要包含编号）：\n"
        '[SUGGESTIONS]{"items":["问题1","问题2","问题3","问题4"]}[/SUGGESTIONS]\n'
        "问题需简洁（15字以内），与本次回复内容紧密相关。\n\n"
        "然后在[/SUGGESTIONS]之后，紧接着另起一行，根据本次回复的情感氛围输出一个梗图标签：\n"
        "[MEME:category] 或 [MEME:none]（不合适时输出none）\n"
        "category 可选值及适用场景：\n"
        "  feel_you=用户被怼/委屈/遭遇不公  hang_in_there=鼓励用户坚持/加油\n"
        "  this_is_fine=无奈接受职场现实     mind_blown=恍然大悟/关键洞察\n"
        "  seriously=调侃/吐槽职场荒唐事     celebration=用户达成目标/好消息\n"
        "  same=共鸣/同感                    thinking=深度思考/策略建议\n"
        "【不发梗图的情况】：用户情绪崩溃、严肃的利益冲突、回复超过3段时，输出[MEME:none]"
    )

    return (
        f"你是用户的职场 AI 助手，了解用户的职场处境。用户问什么你答什么，跟随对话自然走向。\n\n"
        f"{skill_block}"
        f"{summary_block}"
        f"{mem_block}"
        f"{history_block}\n\n"
        f"{task_desc}"
        f"{suggestions_instruction}\n\n"
        f"用中文回复，语气友好自然。"
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
            model = genai.GenerativeModel(ASSISTANT_MODEL)
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
                hint = f"（用户同时发送了{count}张图片，请结合图片内容回应用户。）"
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
    """基于当前回复内容，生成猜你想问（非流式，快速调用）"""
    prompt = (
        f"基于以下 AI Assistant 对 {skill_name} 技能的回复：\n\n"
        f'"{context[:600]}"\n\n'
        f"生成4个用户可能继续追问的简短问题（中文，每个不超过15字）。\n"
        f"只输出 JSON 数组，不要任何其他内容。\n"
        f'示例：["问题1","问题2","问题3","问题4"]'
    )
    try:
        genai.configure(api_key=GEMINI_API_KEY)
        model = genai.GenerativeModel(ASSISTANT_MODEL)
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

@router.post("/assistant/chat")
async def assistant_chat(
    req: AssistantChatRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    # 1. 取策略分析
    strategy_q = await db.execute(
        select(StrategyAnalysis).where(
            StrategyAnalysis.session_id == uuid.UUID(req.session_id)
        )
    )
    strategy = strategy_q.scalar_one_or_none()
    if not strategy:
        raise HTTPException(status_code=404, detail="Strategy not found")

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

        # 对话结束后，异步写入 PostgreSQL KG（fire-and-forget，不阻塞 SSE）
        if full_text and req.message not in ("__INIT__", "__SWITCH__"):
            try:
                from services.knowledge_graph import save_kg_from_chat
                history_text = "\n".join(
                    f"{'用户' if h.role == 'user' else 'AI'}: {h.content}"
                    for h in req.history[-6:]
                )
                round_content = (
                    f"技能场景：{skill_name}\n"
                    f"对话摘要：{conv_summary[:200]}\n"
                    f"---\n{history_text}\n"
                    f"用户：{req.message}\nAI：{full_text[:500]}"
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
                logger.info(f"[KG] assistant 对话异步触发: session_id={req.session_id}")
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
