# AI Chat 技术架构梳理（2026-07-10）

---

## 一、整体流程概览

```
iOS 用户操作
    │
    ▼
1. 创建会话          POST /assistant/init-chat-session
    │
    ▼
2. 发送消息/音频     POST /assistant/chat
                     POST /assistant/chat-audio   ← SSE 流式返回
    │
    ▼
3. 触发生图          POST /assistant/generate-image-from-chat  ← 202 立即返回
    │
    ▼
4. 关闭会话          POST /assistant/close-chat-session
    │
    ▼
5. iOS 轮询          GET  /api/v1/tasks/sessions/{id}   ← 拿 cover_image_url
```

---

## 二、接口详细说明

### 2.1 `POST /assistant/init-chat-session`

**作用**：创建一条 session_type="chat" 的会话记录

**配额检查**：
- Free：5次（终身）
- Weekly：30次/7天
- Monthly：100次/30天
- Yearly：无限制

**数据库写入**：
- `sessions` 表：`session_type="chat"`, `status="processing"`, `finalize_status="pending"`

**返回**：
```json
{ "session_id": "uuid", "created_at": "ISO8601" }
```

---

### 2.2 `POST /assistant/chat`（文字输入 SSE 流）

**模型**：Groq `llama-3.1-8b-instant`（技能匹配） + **Gemini `gemini-2.5-flash`**（AI 回复）

**处理节点（顺序执行）**：

```
① 从 DB 查用户信息（配额校验：Free=10轮, Pro=50轮）
② 查 StrategyAnalysis（拿技能卡内容）
③ 查 AnalysisResult（拿对话摘要）
④ 查 KG 记忆（get_ai_context_kg, 独立 session, timeout=3s）  ← 已修复 [见 §五]
⑤ 查 skill_notes（baseline 文本）
⑥ 组装 Prompt（_build_prompt）
⑦ Groq 技能匹配（_match_skills_serial, 250ms）→ SSE 推送 skill_tags 事件
⑧ Gemini 流式回复（_stream_gemini）→ 逐 token 推送 token 事件
⑨ 解析 [SUGGESTIONS]...[/SUGGESTIONS] 标记
⑩ 生成猜你想问（_generate_suggested_questions, Gemini, timeout=8s）→ 推送 suggestions 事件
```

**SSE 事件顺序**：
```
skill_tags  → { tags: [{skill_id, skill_name}] }
meta        → { skill_name, memory_used }
token       → { content: "文字片段" }   ← 多条
suggestions → { items: ["问题1", "问题2", "问题3"] }
done        →（流结束标志）
```

---

### 2.3 `POST /assistant/chat-audio`（语音输入 SSE 流）

**模型**：**Gemini `gemini-2.5-flash`**（转写 + AI 回复，两次独立调用）

**处理节点（顺序执行，在 event_generator 内部）**：

```
① 读取音频 bytes（multipart/form-data 中的 audio 字段）
② 从 DB 查用户/策略/摘要/KG记忆/baseline（同 /chat）
③ 组装 Prompt
④ ─────────── event_generator 启动 ───────────
⑤ 【转写】await asyncio.wait_for(
              _transcribe_audio(audio_bytes), timeout=15s
           )
           → Gemini non-streaming 调用，等完整文字返回
           → 成功：推送 transcript 事件
           → 失败（超时/异常）：跳过，transcribed_text=""
⑥ 【AI 回复】_stream_gemini_with_audio(prompt, audio_bytes)
           → Gemini streaming 调用，stream=True
           → 在独立 Thread 中运行，Queue 桥接到协程
           → 逐 token 推送 token 事件
⑦ 生成猜你想问（条件：transcribed_text 不为空 AND full_text 不为空）
           → 推送 suggestions 事件
⑧ 推送 done 事件
⑨ fire-and-forget：KG 写入（asyncio.create_task(save_kg_from_chat)）
```

**SSE 事件顺序**：
```
meta        → { skill_name, memory_used }
transcript  → { text: "用户说的话" }     ← 仅转写成功时有
token       → { content: "..." }         ← 多条
suggestions → { items: [...] }           ← 仅 transcribed_text 不为空时有
done        →
```

---

### 2.4 `POST /assistant/generate-image-from-chat`

**作用**：触发生图，立即返回 202，生图在后台异步完成

**配额检查**：
- Free：5次（终身）
- Weekly：20次/7天
- Monthly：90次/30天
- Yearly：1100次/365天

**生图流程（fire-and-forget，asyncio.create_task）**：

```
① 取对话最后一条用户消息，构造 synthetic_transcript
② 调用 generate_scene_images()（scene_image_generator.py）
   │
   ├─ 场景提取（Gemini gemini-2.5-flash-lite）
   │   ├─ 场景1：多人对话 → 提取人物/动作/地点
   │   └─ 场景2：独白叙述 → 提取情绪场景描述
   │
   ├─ 档案图引用（查 profiles 表，拿头像 URL，最多2张参考图）
   │
   ├─ comic_strip_mode=True（当前 AI Chat 专用）
   │   └─ 多场景合并为单张漫画格式 prompt
   │
   └─ 图片生成（Gemini `gemini-3.1-flash-lite-image` aka "Nano Banana"）
       └─ 上传到 Cloudflare R2
③ 写回 DB：
   - sessions.cover_image_url = 图片URL
   - strategy_analysis.scene_images = [{scene_desc, image_url}]
```

**iOS 轮询**：每 3 秒调用 `GET /api/v1/tasks/sessions/{id}`，拿到 `cover_image_url` 后展示

---

### 2.5 `POST /assistant/close-chat-session`

**同步写 DB**：
- `sessions.status = "archived"`
- `sessions.finalize_status = "pending"`
- `strategy_analysis.conversation = [对话数组]`

**fire-and-forget 后台任务**：
1. `_async_session_finalize()`：Gemini 生成 `card_title` / `mood_state` / `emotion_type`，写回 sessions
2. `_async_update_dynamic_kg()`：更新 skill_notes.dynamic_kg_ids

**返回**：立即返回 `{status: "ok"}`

---

## 三、iOS 端触发逻辑

### 3.1 文字消息
```
send(text)
  ├─ messages.append(用户消息)
  ├─ streamRequest()          → 调用 /chat，接收 SSE
  └─ triggerAutoImageGeneration()   ← 立即并行触发，不等 AI 回复
```

### 3.2 语音消息
```
sendAudio(audioData)
  ├─ messages.append(语音气泡)
  └─ streamAudioRequest()     → 调用 /chat-audio，接收 SSE
        │
        onTranscript(text) 回调：
          ├─ 更新语音气泡内容为转写文字
          └─ triggerAutoImageGeneration()  ← 收到转写文字后触发
        │
        onDone 回调：
          └─ （当前无兜底触发）   ← ⚠️ 问题所在 [见 §四]
```

### 3.3 生图触发守卫
```
triggerAutoImageGeneration()
  guard !isExistingSession    ← 历史会话不生图
  guard !isImageGenerating    ← 防并发
  guard canGenerateImage      ← 配额检查
  → 追加骨架屏消息
  → POST /assistant/generate-image-from-chat
  → 每 3s 轮询 cover_image_url（最多 60s）
```

---

## 四、当前已发现的问题

### 问题 A：`/chat-audio` 转写超时 → 连锁导致无生图 + 无猜你想问

**定位**：

```
_transcribe_audio()
  └─ asyncio.to_thread(_run)
       └─ genai.GenerativeModel("gemini-2.5-flash").generate_content(...)
            └─ 非流式调用，等完整结果
               gemini-2.5-flash 含 thinking 机制
               非流式需等 thinking + 完整输出全部完成才返回
               → 耗时可能超过 15s timeout
```

**对比**：

| 调用方式 | 函数 | 模式 | 耗时 |
|--------|------|------|------|
| 转写 | `_transcribe_audio` | non-streaming，asyncio.to_thread | 可能 >15s |
| AI 回复 | `_stream_gemini_with_audio` | streaming，独立 Thread | 第一 token 极快 |

**连锁影响**：
1. 转写超时 → `transcribed_text = ""`
2. 服务端：`if _sugg_msg and full_text` 条件不满足 → **猜你想问不生成**
3. iOS：`onTranscript` 回调永不触发 → `triggerAutoImageGeneration()` 永不调用 → **不生图**

**受影响的 session**：`c7895ea1-ab59-4202-8c88-38bb65d7828f`（2026-07-11 11:19）

---

### 问题 B：多接口 500 错误（已修复）

**定位**：

```
时间线：
11:00:51  第一个脏连接出现（asyncpg: "another operation is in progress"）
11:01:07  /subscription/status 500 + /tasks/sessions 500 + /device/token 延迟 16s
11:02:27  /chat-audio 500（立即失败，duration=0.020s）
```

**根本原因**（追溯到 `connection.py` + `assistant.py`）：

```python
# 问题代码（/chat 和 /chat-audio 两处）
memory_context = await asyncio.wait_for(
    get_ai_context_kg(mem_query, user_id, db),   # ← db 是 DI session
    timeout=3.0,
)
```

**触发链**：
```
asyncio.wait_for 3s 超时
  → CancelledError 注入 get_ai_context_kg 协程
  → asyncpg 正在执行 SQL，被强制中断
  → db 连接处于"操作进行中"脏状态
  → get_db() 最后 await session.commit()
      → asyncpg: "cannot perform operation: another operation is in progress"
      → IllegalStateChangeError: close() called while commit() in progress
  → 脏连接归还连接池
  → 后续所有请求拿到此连接 → 立即 500
```

**修复方案（已上线）**：

```python
# connection.py
engine = create_async_engine(
    ...,
    pool_reset_on_return="rollback",  # 新增：归还前强制 rollback
)

async def get_db():
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
        # 删除了 finally: await session.close()（与 async with 双重 close 冲突）

# assistant.py
async def _get_kg_context_isolated(mem_query, user_id):
    """使用独立 session，与 DI db 完全隔离"""
    async with AsyncSessionLocal() as _kg_db:
        return await get_ai_context_kg(mem_query, user_id, _kg_db)

# /chat 和 /chat-audio 两处改为：
memory_context = await asyncio.wait_for(
    _get_kg_context_isolated(mem_query, user_id),  # ← 独立 session
    timeout=3.0,
)
```

---

## 五、模型使用一览

| 环节 | 模型 | 调用方式 | 超时/限制 |
|------|------|---------|---------|
| 技能匹配 | Groq `llama-3.1-8b-instant` | 同步，Groq SDK | 无显式 timeout |
| 文字 AI 回复 | `gemini-2.5-flash` | streaming，独立 Thread | 无 |
| 语音转写 | `gemini-2.5-flash` | **non-streaming，asyncio.to_thread** | 15s ⚠️ |
| 语音 AI 回复 | `gemini-2.5-flash` | streaming，独立 Thread | 无 |
| 猜你想问 | `gemini-2.5-flash` | asyncio.to_thread | 8s |
| 会话 Finalize | `gemini-2.5-flash` | asyncio.to_thread | 无 |
| 场景提取 | `gemini-2.5-flash-lite` | asyncio.to_thread | 无 |
| 图片生成 | `gemini-3.1-flash-lite-image`（Nano Banana） | asyncio.to_thread | 无 |
| KG 记忆检索 | 纯 SQL（无 LLM） | 异步 DB 查询 | 3s |

---

## 六、数据库写入路径

```
init-chat-session   → sessions（insert）
/chat               → strategy_analysis（UPSERT skill_cards）
/chat-audio         → strategy_analysis（UPSERT，同上）
close-chat-session  → sessions（update status/finalize_status）
                    → strategy_analysis（UPSERT conversation）
_async_finalize     → sessions（update card_title/mood_state/emotion_type）
generate-image      → sessions（update cover_image_url）
                    → strategy_analysis（update scene_images）
KG 写入             → kg_persons / kg_events / kg_goals（UPSERT）
```

---

## 七、待解决问题

| 问题 | 影响 | 状态 |
|------|------|------|
| 语音转写超时（非流式 gemini-2.5-flash） | 无猜你想问 + 无生图 | **未修复** |
| iOS `onDone` 无生图兜底 | 转写失败时生图完全丢失 | **未修复** |
| 服务端 suggested_questions 条件依赖转写文字 | 转写失败时猜你想问丢失 | **未修复** |
| DB 连接池脏连接（asyncio.wait_for + DI session） | 级联 500 | ✅ 已修复 |
