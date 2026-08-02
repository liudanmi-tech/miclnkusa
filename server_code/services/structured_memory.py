"""
结构化记忆服务（短期方案）

在 mem0 中写入带标签的结构化记忆：
  [PERSON:张三][TYPE:event][DATE:2024-05-01] 预算会议上方案被否定
  [PERSON:张三][TYPE:relationship] 亲密度4, 摩擦6, 上司关系
  [GOAL][PERSON:张三][STATUS:in_progress] 争取年度绩效支持

调用者：
  - main.py B 钩子（录音分析完成后）：asyncio.create_task
  - api/assistant.py（AI对话结束后）：asyncio.create_task
"""

import os
import json
import logging
from datetime import date
from typing import Optional

logger = logging.getLogger(__name__)

GEMINI_MODEL = os.getenv("GEMINI_FLASH_MODEL", "gemini-2.0-flash")


# ─── 抽取 Prompt ─────────────────────────────────────────────────────────────

_EXTRACT_PROMPT = """\
You are an information extraction assistant. Extract structured information from the following conversation or summary and output pure JSON (no markdown code blocks).

Today's date: {today}

Input content:
{content}

Please extract:
1. persons (people mentioned in the conversation)
   - name: person's name or title
   - relationship: relationship type (boss/colleague/friend/romantic/family/other)
   - relationship_desc: one-sentence description in English (e.g. "direct supervisor", "teammate in the same department")
   - intimacy: intimacy score 1-10
   - friction: friction score 1-10
   - power: superior/equal/subordinate (relative to the user)

2. events (key events, at most 2 most important ones per person)
   - person: person's name
   - date: event date (write "today" if unclear)
   - summary: one-sentence event summary in English (within 20 words)
   - sentiment: positive/neutral/negative
   - outcome: resolved/ongoing/escalated

3. goals (user's goals or tasks)
   - description: goal description in English (within 20 words)
   - person: related person (can be empty)
   - status: in_progress/completed/abandoned

Rules:
- If no specific person is mentioned, return an empty array for persons
- Do not include the user themselves in persons
- Only extract information explicitly supported by the conversation, do not infer

Output format (JSON only):
{{"persons": [...], "events": [...], "goals": [...]}}
"""


# ─── 主函数 ───────────────────────────────────────────────────────────────────

def extract_and_save_structured_memories(
    content: str,
    user_id: str,
    session_id: str,
    metadata_extra: Optional[dict] = None,
) -> bool:
    """
    同步执行：用 Gemini 抽取结构化信息，格式化为标签字符串，写入 mem0。
    调用者应用 asyncio.to_thread / asyncio.create_task 包裹，避免阻塞。
    """
    if not content or not content.strip():
        logger.info(f"[结构记忆] 跳过：content 为空 session={session_id}")
        return False

    # 1. Gemini 抽取
    extracted = _call_gemini_extract(content, session_id)
    if not extracted:
        return False

    # 2. 格式化为带标签字符串列表
    today_str = date.today().isoformat()
    tagged_items = _format_tagged(extracted, today_str)
    if not tagged_items:
        logger.info(f"[结构记忆] 抽取结果为空，无可写内容 session={session_id}")
        return False

    # 3. 批量写入 mem0
    base_meta = {"session_id": session_id, "type": "structured"}
    if metadata_extra:
        base_meta.update(metadata_extra)

    from services.memory_service import add_memory
    ok_count = 0
    for item in tagged_items:
        # infer=False: 直存原始带标签字符串，避免 LLM 提炼丢失 [TYPE:][DATE:] 等标签
        ok = add_memory(item, user_id, metadata=base_meta, enable_graph=False, infer=False)
        if ok:
            ok_count += 1

    logger.info(f"[结构记忆] 写入完成 session={session_id} total={len(tagged_items)} ok={ok_count}")
    return ok_count > 0


# ─── 内部工具 ─────────────────────────────────────────────────────────────────

def _call_gemini_extract(content: str, session_id: str) -> Optional[dict]:
    """调用 Gemini 抽取，返回解析后的 dict，失败返回 None"""
    try:
        import google.generativeai as genai
        genai.configure(api_key=os.getenv("GEMINI_API_KEY", ""))
        model = genai.GenerativeModel(GEMINI_MODEL)

        prompt = _EXTRACT_PROMPT.format(
            today=date.today().isoformat(),
            content=content[:3000],   # 截断避免 token 超限
        )
        resp = model.generate_content(prompt)
        raw = (resp.text or "").strip()

        # 去掉可能的 ```json ... ``` 包裹
        if raw.startswith("```"):
            raw = raw.split("```")[1]
            if raw.startswith("json"):
                raw = raw[4:]
        raw = raw.strip()

        data = json.loads(raw)
        logger.info(
            f"[结构记忆] Gemini 抽取成功 session={session_id} "
            f"persons={len(data.get('persons', []))} "
            f"events={len(data.get('events', []))} "
            f"goals={len(data.get('goals', []))}"
        )
        return data
    except json.JSONDecodeError as e:
        logger.warning(f"[结构记忆] Gemini 返回非 JSON session={session_id} error={e}")
        return None
    except Exception as e:
        logger.warning(f"[结构记忆] Gemini 抽取失败 session={session_id} error={e}")
        return None


def _format_tagged(data: dict, today_str: str) -> list[str]:
    """将抽取结果格式化为带标签的记忆字符串列表"""
    items = []

    # 人物关系记忆
    for p in data.get("persons", []):
        name = (p.get("name") or "").strip()
        if not name:
            continue
        rel_desc = p.get("relationship_desc") or p.get("relationship") or ""
        intimacy = p.get("intimacy", "?")
        friction = p.get("friction", "?")
        power = p.get("power", "")
        power_str = {"superior": "Superior", "equal": "Equal", "subordinate": "Subordinate"}.get(power, "")

        text = (
            f"[PERSON:{name}][TYPE:relationship] "
            f"Relationship: {rel_desc}"
            + (f", {power_str}" if power_str else "")
            + f", intimacy {intimacy}/10, friction {friction}/10"
        )
        items.append(text)

    # 事件记忆
    for e in data.get("events", []):
        person = (e.get("person") or "").strip()
        summary = (e.get("summary") or "").strip()
        if not summary:
            continue
        event_date = e.get("date") or today_str
        if event_date == "today":
            event_date = today_str
        sentiment = e.get("sentiment", "")
        outcome = e.get("outcome", "")

        tag_person = f"[PERSON:{person}]" if person else ""
        tag_sentiment = {"positive": "Positive", "negative": "Negative", "neutral": "Neutral"}.get(sentiment, "")
        tag_outcome = {"resolved": "Resolved", "ongoing": "Ongoing", "escalated": "Escalated"}.get(outcome, "")

        text = (
            f"{tag_person}[TYPE:event][DATE:{event_date}] {summary}"
            + (f", sentiment: {tag_sentiment}" if tag_sentiment else "")
            + (f", status: {tag_outcome}" if tag_outcome else "")
        )
        items.append(text)

    # 目标记忆
    for g in data.get("goals", []):
        desc = (g.get("description") or "").strip()
        if not desc:
            continue
        person = (g.get("person") or "").strip()
        status = g.get("status", "in_progress")
        status_str = {"in_progress": "In Progress", "completed": "Completed", "abandoned": "Abandoned"}.get(status, status)

        tag_person = f"[PERSON:{person}]" if person else ""
        text = f"[GOAL]{tag_person}[STATUS:{status}][DATE:{today_str}] {desc}, {status_str}"
        items.append(text)

    return items


# ─── 检索辅助：从文本中提取人名用于精准检索 ──────────────────────────────────

def build_structured_search_query(base_query: str, person_names: list[str] = None) -> str:
    """
    组装面向结构化记忆的检索词。
    若提供了人名列表，优先用 [PERSON:xxx] 格式检索。
    """
    if person_names:
        person_tags = " ".join(f"[PERSON:{n}]" for n in person_names[:3])
        return f"{person_tags} {base_query}"
    return base_query
