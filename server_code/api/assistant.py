"""
AI Assistant Chat API
POST /api/v1/assistant/chat  — SSE 流式对话
"""
import os
import json
import uuid
import asyncio
import threading
import logging
from typing import List, Optional

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


# ─── Request / Response Models ────────────────────────────────────────────────

class ChatHistoryItem(BaseModel):
    role: str    # "user" | "assistant"
    content: str

class AssistantChatRequest(BaseModel):
    session_id: str
    skill_id: str
    message: str          # "__INIT__" 表示首次自动触发
    history: List[ChatHistoryItem] = []


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
    summary_block = f"\n本次对话摘要：\n{conversation_summary}" if conversation_summary else ""

    history_block = ""
    if history:
        lines = []
        for h in history:
            prefix = "用户" if h.role == "user" else "AI"
            lines.append(f"{prefix}: {h.content}")
        history_block = "\n对话历史：\n" + "\n".join(lines)

    if message == "__INIT__":
        task_desc = (
            f"请基于以上分析生成一段友好开场白（2-3句话）：\n"
            f"1. 用一句话概括你注意到的对话关键点\n"
            f"2. 表达你可以帮助的方向\n"
            f"3. 以一个开放性问题结尾\n"
            f"语气亲切自然，像一个了解用户的朋友。"
        )
    else:
        task_desc = (
            f"用户说：{message}\n\n"
            f"请给出有针对性的回复，结合技能分析和用户情况，给出实用建议。"
        )

    suggestions_instruction = (
        "\n\n---\n"
        "在你的回复最后，另起一行，严格按以下格式输出4个用户可能追问的问题（不要包含编号）：\n"
        '[SUGGESTIONS]{"items":["问题1","问题2","问题3","问题4"]}[/SUGGESTIONS]\n'
        "问题需简洁（15字以内），与本次回复内容紧密相关。"
    )

    return (
        f"你是用户的 AI Assistant，正在帮助他处理一个真实对话场景。\n\n"
        f"技能分析结果（{skill_name}）：\n{skill_content_json}"
        f"{summary_block}"
        f"{mem_block}"
        f"{history_block}\n\n"
        f"{task_desc}"
        f"{suggestions_instruction}\n\n"
        f"用中文回复，语气友好自然。"
    )


async def _stream_gemini(prompt: str):
    """在线程中运行 Gemini 流式生成，通过 asyncio.Queue 桥接到协程"""
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()

    def _run():
        try:
            genai.configure(api_key=GEMINI_API_KEY)
            model = genai.GenerativeModel(ASSISTANT_MODEL)
            response = model.generate_content(prompt, stream=True)
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

    # 4. 取记忆上下文（含超时保护）
    memory_used = False
    memory_context = ""
    try:
        from services.memory_service import search_memory
        query = f"{skill_name} {conv_summary[:100]}"
        mem_results = await asyncio.wait_for(
            asyncio.to_thread(search_memory, query, user_id, limit=3),
            timeout=2.0,
        )
        if mem_results:
            memory_context = "\n".join(f"- {m}" for m in mem_results)
            memory_used = True
    except asyncio.TimeoutError:
        logger.warning("[assistant] 记忆检索超时(2s)，跳过")
    except Exception as exc:
        logger.warning(f"[assistant] 记忆获取失败: {exc}")

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

        async for event_type, content in _stream_gemini(prompt):
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

        yield _sse({"type": "done"})

        # 对话结束后，异步写入结构化记忆（fire-and-forget，不阻塞 SSE）
        if full_text and req.message != "__INIT__":
            try:
                from services.structured_memory import extract_and_save_structured_memories
                # 组装本轮对话内容（含历史 + 本轮问答）
                history_text = "\n".join(
                    f"{'用户' if h.role == 'user' else 'AI'}: {h.content}"
                    for h in req.history[-6:]   # 最近6条，控制长度
                )
                round_content = (
                    f"技能场景：{skill_name}\n"
                    f"对话摘要：{conv_summary[:200]}\n"
                    f"---\n{history_text}\n"
                    f"用户：{req.message}\nAI：{full_text[:500]}"
                )
                asyncio.create_task(asyncio.to_thread(
                    extract_and_save_structured_memories,
                    round_content,
                    user_id,
                    req.session_id,
                    {"source": "assistant_chat", "skill_id": req.skill_id},
                ))
                logger.info(f"[结构记忆] assistant 对话异步触发: session_id={req.session_id}")
            except Exception as sm_err:
                logger.warning(f"[结构记忆] assistant 触发失败: {sm_err}")

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )
