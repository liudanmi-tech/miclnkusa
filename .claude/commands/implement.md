# /implement — 对话式交互分阶段编码

**用法**：`/implement` 或 `/implement Phase3`

不带参数：自动检测当前进度，定位到下一个未完成 Phase。
带参数（如 `Phase3`）：直接跳到指定阶段。

---

## 执行流程（按顺序，不可跳过）

### Step 1 — 读取设计文档

必须读取以下文件：
- `~/Desktop/0226new/doc/对话式交互0613.md`（完整方案）
- `~/Desktop/0226new/doc/CLAUDE.md`（编码规范）

从文档中提取：当前 Phase 的**改动文件列表**、**关键日志规范**、**验证命令**。

---

### Step 2 — 检测当前代码进度

执行以下检查，判断哪些 Phase 已完成：

```
Phase 0（DB 迁移）：
  检查：sessions 表是否有 finalize_status 列
  方法：ssh 到测试服执行 \d sessions

Phase 1（init-chat-session）：
  检查：api/assistant.py 是否有 init_chat_session 函数
  方法：grep "init_chat_session" server_code/api/assistant.py

Phase 2（/chat is_chat_session + _init_skill_matching）：
  检查：assistant.py 是否有 _init_skill_matching 函数 + is_chat_session 参数处理
  方法：grep "_init_skill_matching\|is_chat_session" server_code/api/assistant.py

Phase 3（close-chat-session + _async_session_finalize）：
  检查：assistant.py 是否有 close_chat_session + _async_session_finalize
  方法：grep "close_chat_session\|_async_session_finalize" server_code/api/assistant.py

Phase 4（generate-image-from-chat）：
  检查：assistant.py 是否有 generate_image_from_chat
  方法：grep "generate_image_from_chat" server_code/api/assistant.py

Phase 5（GET session 新增字段）：
  检查：tasks.py 返回是否含 finalize_status
  方法：grep "finalize_status" server_code/api/tasks.py（或 main.py）

Phase 6（iOS Task.swift + NetworkManager.swift）：
  检查：Task.swift 是否有 sessionType / coverType 字段
  方法：grep "sessionType\|coverType" Models.swift/WorkSurvivalGuide/WorkSurvivalGuide/Models/Task.swift

Phase 7（iOS ChatAIAssistantViewModel）：
  检查：文件是否存在
  方法：ls Models.swift/WorkSurvivalGuide/WorkSurvivalGuide/ViewModels/ChatAIAssistantViewModel.swift

Phase 8（iOS ChatAIAssistantView）：
  检查：文件是否存在
  方法：ls Models.swift/WorkSurvivalGuide/WorkSurvivalGuide/Views/ChatAIAssistantView.swift

Phase 9（iOS 录音入口改造）：
  检查：RecordingViewModel 是否有 createChatSession
  方法：grep "createChatSession" Models.swift/WorkSurvivalGuide/WorkSurvivalGuide/ViewModels/RecordingViewModel.swift

Phase 10（iOS Moment 列表联调）：
  检查：TaskCardView 是否有 chat session 分支
  方法：grep "sessionType.*chat\|chat.*sessionType" Models.swift/WorkSurvivalGuide/WorkSurvivalGuide/Views/TaskCardView.swift
```

---

### Step 3 — 输出进度报告（等待用户确认，不可跳过）

格式：

```
【实施进度报告】
设计文档：对话式交互0613.md（已读）

✅ Phase 0：DB 迁移 — 已完成
✅ Phase 1：init-chat-session — 已完成
⏳ Phase 2：/chat is_chat_session + _init_skill_matching — 未完成 ← 当前
⬜ Phase 3：close + finalize — 未开始
⬜ Phase 4：generate-image-from-chat — 未开始
⬜ Phase 5：GET session 新增字段 — 未开始
⬜ Phase 6：iOS 数据层 — 未开始
⬜ Phase 7：iOS ViewModel — 未开始
⬜ Phase 8：iOS View + 退出 — 未开始
⬜ Phase 9：iOS 录音入口 — 未开始
⬜ Phase 10：iOS Moment 联调 — 未开始

─────────────────────────────
【当前 Phase 2 改动计划】
涉及文件：
  - server_code/api/assistant.py（修改 /chat endpoint，新增 _init_skill_matching）

改动内容摘要：
  1. /chat 新增 is_chat_session 参数，第1条消息时不 raise 404
  2. 新增 _init_skill_matching()：fire-and-forget，UPSERT 写 strategy_analysis
  3. SSE 新增 skill_tags 事件

关键日志节点（完成后可 grep 验证）：
  [CHAT:xxx] /chat received | is_chat=True
  [CHAT:xxx] skill_matching started
  [CHAT:xxx] strategy_analysis written
  [CHAT:xxx] skill_tags pushed | tags=...

验证命令（改完后执行）：
  curl -N -X POST http://34.74.255.48/api/v1/assistant/chat \
    -H "Authorization: Bearer <token>" \
    -H "Accept: text/event-stream" \
    -d '{"session_id":"<id>","skill_id":"emotion_recognition","message":"今天被领导批评了","history":[],"is_chat_session":true,"skill_mode":"auto"}'
  期望：SSE 流最后出现 skill_tags 事件

─────────────────────────────
确认进入 Phase 2 编码？（确认后我创建分支并开始改动）
```

---

### Step 4 — 创建 Git 分支

```bash
git checkout -b feat/chat-phase{N}-{描述}
```

例：`feat/chat-phase2-skill-matching`

---

### Step 5 — 最小化编码（严格按文档）

- **只实现当前 Phase 的内容**，不跨 Phase 做下一步
- 每个关键节点必须有日志，格式严格按照文档第十五章规范
- 不顺手重构无关代码
- 改完输出 diff 摘要

---

### Step 6 — 输出改动摘要，等待用户确认

格式：

```
【Phase N 改动摘要】
改动文件：
  - server_code/api/assistant.py（+85 行，-3 行）

新增函数：
  - _init_skill_matching()

修改函数：
  - chat_stream()：新增 is_chat_session 分支

日志节点已全部覆盖：✅

请执行验证命令后告诉我日志是否符合预期，确认后我 commit。
```

---

### Step 7 — 用户验证日志后 Commit

用户确认日志绿灯后：

```bash
git add server_code/api/assistant.py
git commit -m "feat: chat phase2 — is_chat_session + _init_skill_matching + skill_tags SSE"
```

**不自动推送到远端，等用户指令。**

---

## 硬性规则

- 每次只做一个 Phase，完成验证后才进下一个
- Step 3 和 Step 6 必须等用户确认
- 日志节点不得省略，按文档第十五章格式写
- 不改已完成 Phase 的代码（除非发现 bug）
- 发现文档与代码不一致时，**先报告，等用户决策，不擅自选择**
