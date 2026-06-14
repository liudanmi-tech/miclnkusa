# Suggestion 生成与推送方式

> 整理自 2026-06-11 架构讨论，针对 Live 模式实时建议的自适应触发机制设计
> 2026-06-11 细化：非对称升降级、平静 interval 改为 4、说话人三层识别、relevant 过滤

---

## 一、现状架构（As-Is）

### 1.1 触发逻辑（固定节奏，与局势无关）

```
每条 turn 到达
    ↓
on_turn_received(session_id, turn_index)
    └── 检查：距上次触发是否 >= 3 条 turn，或 >= 20 秒
            ↓ 满足条件
        fire-and-forget → _run_quick_suggestion()
```

**根本问题**：触发频率与对话紧张程度完全无关。
- 领导在追问数据 → 还是等 3 条才弹
- 闲聊天气 → 也是每 3 条弹一次

---

### 1.2 快速路径 Prompt 上下文（As-Is）

```
Layer 1：最近 8 条 turn（~400 tokens，滑动窗口）
Layer 2：当前 Segment running_context（≤300 tokens，增量滚动摘要）
─────────────────────────────────────────────────
合计输入：~700 tokens
```

**缺失**：没有说话人角色信息（谁在说话，是领导还是同事？）

---

### 1.3 当前 Gemini Flash 输出格式

```json
{
  "text": "建议（20字内）",
  "emotion_tag": "情绪标签（含emoji）",
  "skill_hint": "技能关键词"
}
```

**缺失**：
- 没有紧迫程度（`urgency_level`）
- 没有话语行为类型（`speech_act`，对方是在提问我/质疑我/陈述？）

---

### 1.4 当前 SSE Suggestion Payload

```json
{
  "type": "suggestion",
  "text": "...",
  "emotion_tag": "...",
  "skill_hint": "...",
  "turn_index": 5
}
```

iOS 侧所有 suggestion 气泡展示样式完全相同，无轻重之分。

---

## 二、问题与设计目标

| 场景 | 当前表现 | 目标表现 |
|------|---------|---------|
| 领导突然问我数据 | 等 3 条才弹，来不及 | 最多延迟 3 条，弹出高亮显示 |
| 同事向我发难/质疑 | 每 3 条弹 | 检测到后立即升级，每 1 条弹 |
| 闲聊、轻松对话 | 每 3 条弹（打扰） | 每 4 条弹，降低打扰 |
| 危急局面持续 | 始终 3 条 | 保持每 1 条直到局势缓解 |
| 背景噪音/无关对话 | 照常触发建议 | 过滤掉，不生成建议 |
| 声纹未识别的说话人 | 只显示"Speaker_2" | 靠内容推断角色，仍能判断 urgency |

**核心目标**：
1. 触发频率与对话局势动态挂钩——局势升级立即响应，局势平稳时降频减少干扰
2. 说话人身份尽量丰富——声纹匹配到则给名字和角色，匹配不到则靠内容推断
3. 无关内容直接过滤——不对背景噪音、不涉及我的对话生成建议

---

## 三、关键数据发现：现有数据已足够

| 需要的信号 | 数据位置 | 获取方式 |
|-----------|---------|---------|
| 说话人角色（声纹已匹配） | `profiles.relationship_type`（已有字段） | `speaker_label` → `live_speaker_mappings.profile_id` → `profiles.relationship_type` |
| 说话人角色（声纹未匹配） | Gemini 从对话内容推断 | 同一次 Gemini 调用，免费 |
| 内容是否与我相关 | Gemini 判断 `relevant_to_user` | 新增输出字段，免费 |
| 紧迫程度（urgency_level） | Gemini Flash 输出（新增字段） | 改 prompt，免费 |
| 话语行为（speech_act） | Gemini Flash 输出（新增字段） | 改 prompt，免费 |
| 模式状态机 | `_state[session_id]` 内存 dict（已有） | 在现有 state dict 加字段 |

**无需新建任何表、无需新增 API endpoint。**

---

## 四、To-Be 架构

### 4.1 三段式自适应触发模式

| 模式 | 建议间隔 | iOS 展示 |
|------|---------|---------|
| 平静模式（0） | 每 **4** 条 turn | 灰色气泡（当前样式） |
| 警觉模式（1） | 每 **3** 条 turn | 黄色左边框气泡 |
| 危急模式（2） | 每 **1** 条 turn | 橙红边框 + 字号+1 + 震动 |

### 4.2 模式状态机（非对称升降级）

**核心原则：升级瞬时，降级需确认。**

类比火警警报：探测到烟立刻拉响；烟消散后等确认安全了再解除。

```
初始状态：平静模式（last_urgency_level=0，interval=4）

每次 _run_quick_suggestion() 完成后执行：

  ── 升级（瞬时，1 次即生效）──────────────────────
  if urgency_level == 1:
      last_urgency_level = 1    # 立即进入警觉（interval=3）
      calm_streak = 0

  if urgency_level == 2:
      last_urgency_level = 2    # 立即进入危急（interval=1）
      calm_streak = 0

  ── 降级（需连续 3 次 calm 才生效）──────────────────
  if urgency_level == 0:
      calm_streak += 1
      if calm_streak >= 3:
          last_urgency_level = 0  # 降回平静（interval=4）
      # calm_streak < 3 时，last_urgency_level 保持不变（仍高频）
```

### 4.3 固有延迟说明

`on_turn_received()` 读取的是**上一次**建议周期写入的 `last_urgency_level`，判断发生在 `_run_quick_suggestion()` 里。这导致从"突发紧急事件发生"到"系统检测到并切模式"之间，有最多 **(interval - 1) 条 turn** 的盲窗：

| 当时所处模式 | interval | 最坏盲窗 | 举例 |
|------------|---------|---------|------|
| 平静（0） | 4 | **3 条** | 刚触发后第 1 条就来紧急事件，等 3 条才检测到 |
| 警觉（1） | 3 | **2 条** | 同上 |
| 危急（2） | 1 | **0 条** | 每条都触发，无盲窗 |

**接受这个延迟的理由**：20 秒超时兜底确保长时间沉默不会漏掉，且非对称升级确保一旦检测到立刻切到高频。平静期 3 条盲窗在实际快速对话（每 3-5 秒一条）中约为 10-15 秒，通常够用。

状态变化示意（非对称版）：
```
turn=0:  触发，Gemini 返回 urgency=0 → 平静(interval=4)，calm_streak=1
turn=4:  触发，Gemini 返回 urgency=0 → 平静(4)，calm_streak=2
         （turn=1 老板开始说话，但直到 turn=4 才检测到 ← 最坏 3 条盲窗）
turn=8:  触发，Gemini 返回 urgency=1 → 立即升警觉(interval=3)，calm_streak=0
turn=11: 触发，Gemini 返回 urgency=2 → 立即升危急(interval=1)，calm_streak=0
turn=12: ✅ 每条触发
turn=13: ✅ 每条触发，Gemini 返回 urgency=0 → calm_streak=1（但仍危急）
turn=14: ✅ 每条触发，Gemini 返回 urgency=0 → calm_streak=2（仍危急）
turn=15: ✅ 每条触发，Gemini 返回 urgency=0 → calm_streak=3 → 降回平静(interval=4)
turn=19: 触发（恢复平静节奏）
```

---

## 五、完整数据流（To-Be）

### 5.0 _state[session_id]：贯穿整个流程的内存记忆

```
┌─────────────────────────────────────────────────────────────────────┐
│  _state[session_id]  （Python 进程内存，服务重启清空）                │
│                                                                     │
│  {                                                                  │
│    "last_quick_turn_index": 12,   # 上次触发建议时的 turn_index       │
│    "last_quick_mono":  1234.5,    # 上次触发建议的单调时间戳           │
│    "last_urgency_level": 1,       # 当前模式：0平静 / 1警觉 / 2危急   │
│    "calm_streak":     0,          # 连续低urgency次数（降级用）        │
│    # ↑ 升级不再需要 urgency_streak（1次即生效）                       │
│  }                                                                  │
│                                                                     │
│  每个 session_id 独立一份，session 结束时 clear_session() 释放        │
└─────────────────────────────────────────────────────────────────────┘
```

**这个 dict 是"前一次建议结果"传递给"下一次触发决策"的唯一通道。**
- `on_turn_received()` **读** `last_urgency_level` → 换算 interval → 决定是否触发
- `_run_quick_suggestion()` **写** `last_urgency_level` + `calm_streak` → 供下次 turn 使用

---

### 5.1 主数据流（含状态机读写）

```
iOS PCM 音频帧（16kHz，16-bit，mono）
    │
    ▼ WebSocket
┌──────────────────────────────────────────────────────────────────────┐
│ live_audio.py  _gemini_to_ios()                                      │
│                                                                      │
│  Deepgram 转录完成一条发言                                            │
│  TranscribedTurn {                                                   │
│      speaker_label: "Speaker_2",   ← 匿名编号，Deepgram diarization  │
│      text:          "给我看数字",   ← 转录文本                        │
│      turn_index:    23             ← 本 session 第几条话，从 0 递增   │
│  }                                                                   │
│                                                                      │
│  ⚠️ speaker_label 只是编号，不知道这个人是谁                           │
│     → 说话人身份在 _run_quick_suggestion() 里三层查询解析             │
│         │                                                            │
│         ▼                                                            │
│  _write_turn_and_event()                                             │
│    ├── INSERT live_turns（持久化到 DB）                               │
│    └── INSERT live_events（event_type="transcript"，供 SSE 重放）     │
│         │                                                            │
│         ▼ db.commit()                                                │
│         │                                                            │
│         ├──────────────────────────────────────────────────────────▶ push SSE "transcript"
│         │                                                            │  → iOS 气泡立即显示
│         │                                                            │
│         ▼                                                            │
│  live_turn_processor.on_turn_received(session_id, turn_index=23)     │
│  （同步调用，不阻塞，fire-and-forget 创建后台 Task）                   │
│         │                                                            │
│         ▼                                                            │
│  live_segment_manager.on_turn_received(session_id, 23, "Speaker_2") │
│  （同步调用，fire-and-forget，每 10 条更新 running_context）           │
└──────────────────────────────────────────────────────────────────────┘
```

---

### 5.2 on_turn_received()：读 _state，决定是否触发

```
┌─────────────────────────────────────────────────────────────────────┐
│  live_turn_processor.on_turn_received(session_id, turn_index=23)    │
│                                                                     │
│  Step A：读 _state[session_id]（上一次建议周期写入的结果）            │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  last_urgency_level = 1  → interval = 3  （警觉模式）         │   │
│  │  last_quick_turn_index  = 20                                 │   │
│  │  last_quick_mono        = 上次时间戳                          │   │
│  │                                                              │   │
│  │  interval 映射：                                             │   │
│  │    last_urgency_level=0 → interval=4  （平静）               │   │
│  │    last_urgency_level=1 → interval=3  （警觉）               │   │
│  │    last_urgency_level=2 → interval=1  （危急）               │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  Step B：判断是否触发                                                │
│    turns_since = 23 - 20 = 3  >= interval(3)  → ✅ 触发             │
│    （或 now - last_quick_mono >= 20s 超时兜底，防止长时间沉默漏触发） │
│                                                                     │
│    更新 _state:                                                     │
│      last_quick_turn_index = 23                                     │
│      last_quick_mono       = now                                    │
│                                                                     │
│  Step C：创建后台 Task                                               │
│    asyncio.create_task(                                             │
│        _run_quick_suggestion(session_id, turn_index=23)             │
│    )                              ← 非阻塞，立即返回                 │
│                                                                     │
│  Step D：异步路径检查（独立，不影响快速路径）                          │
│    if (23 + 1) % 10 == 4  → 不触发                                  │
│    if (29 + 1) % 10 == 0  → 触发 _run_async_analysis()             │
└─────────────────────────────────────────────────────────────────────┘
```

---

### 5.3 _run_quick_suggestion()：调 Gemini，写回 _state

```
┌─────────────────────────────────────────────────────────────────────┐
│  _run_quick_suggestion(session_id, turn_index=23)                   │
│  （后台 Task，异步执行，约 1-2s 后完成）                               │
│                                                                     │
│  Step 1：取最近 8 条 turn（Layer 1，滑动窗口）                        │
│    SELECT * FROM live_turns                                         │
│    WHERE session_id=? ORDER BY turn_index DESC LIMIT 8              │
│    → turns[16..23]                                                  │
│                                                                     │
│  Step 2：取 running_context（Layer 2，当前 Segment 摘要）             │
│    SELECT running_context FROM live_segments                        │
│    WHERE session_id=? AND status='active'                           │
│    → "Q3预算讨论，张总对超支情况不满"                                 │
│                                                                     │
│  Step 3：说话人三层识别（新增，方案A 每次实时查）                      │
│                                                                     │
│  ┌── 第一层：声纹已匹配 ──────────────────────────────────────────┐  │
│  │  SELECT profile_id FROM live_speaker_mappings                 │  │
│  │    WHERE session_id=? AND speaker_label='Speaker_2'           │  │
│  │  → profile_id = "abc-123"（有结果）                           │  │
│  │  SELECT name, relationship_type FROM profiles WHERE id=?      │  │
│  │  → name="张总", relationship_type="领导"                      │  │
│  │  → speaker_desc = "张总（领导）"                              │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  ┌── 第二层：声纹未匹配，Gemini 从内容推断 ──────────────────────┐   │
│  │  SELECT profile_id FROM live_speaker_mappings → 无结果        │   │
│  │  → speaker_desc = "未识别说话人"                              │   │
│  │  → Gemini 凭对话内容判断 urgency_level 和 speech_act          │   │
│  │    （命令式语气/质问 → urgency≥1；闲聊 → urgency=0）           │   │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  ┌── 第三层：内容与我无关 → 过滤 ────────────────────────────────┐  │
│  │  Gemini 输出 relevant_to_user = false                        │  │
│  │  （背景噪音/别人和第三方说话/与用户工作生活完全无关）           │  │
│  │  → 跳过 Step 8/9（不写 suggestion，不推 SSE）                 │  │
│  │  → 跳过 Step 7（不更新状态机，噪音不影响模式判断）             │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  Step 4：组装 Prompt                                                │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ 背景：Q3预算讨论，对方对超支不满  （Layer 2 running_context）  │   │
│  │                                                              │   │
│  │ 最近对话（user=我，other=对方）：                             │   │
│  │   user:         主要是人员成本上涨了...                      │   │
│  │   张总（领导）: 给我看数字         ← 声纹已匹配时用真名       │   │
│  │   user:         ...                                          │   │
│  │   未识别说话人: 好的              ← 声纹未匹配时用通用描述    │   │
│  │                                                              │   │
│  │ 请判断：                                                     │   │
│  │   relevant_to_user: 这段对话是否与用户（user）相关？          │   │
│  │   urgency_level: 0平静 / 1警觉 / 2危急                       │   │
│  │   speech_act: neutral/question_to_me/challenge/command/affirm│   │
│  │   text: 给用户的建议（20字内）                                │   │
│  │   emotion_tag: 对方情绪标签（含emoji）                        │   │
│  │                                                              │   │
│  │ 输出严格单行JSON：                                           │   │
│  │ {"relevant_to_user":true,"urgency_level":2,                  │   │
│  │  "speech_act":"command","text":"...","emotion_tag":"..."}    │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  Step 5：调 Gemini Flash → 约 1-2s                                  │
│                                                                     │
│  Step 6：解析返回                                                    │
│    {                                                                │
│      "relevant_to_user": true,        ← 新增，false则跳过后续       │
│      "text":          "先给大概数字，再说需要核实",                  │
│      "emotion_tag":   "😤 对方施压",                                │
│      "skill_hint":    "数据防御",                                   │
│      "urgency_level": 2,              ← 新增                       │
│      "speech_act":    "command"       ← 新增                       │
│    }                                                                │
│                                                                     │
│  Step 6.5：relevant_to_user 过滤                                    │
│    if relevant_to_user == false:                                    │
│        return  ← 直接退出，不写 DB，不推 SSE，不更新 _state          │
│                                                                     │
│  Step 7：非对称写回 _state[session_id]          ← 关键循环！        │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  ── 升级（瞬时）──────────────────────────────────────────── │   │
│  │  if urgency_level >= 1:                                      │   │
│  │      last_urgency_level = urgency_level  # 立即生效           │   │
│  │      calm_streak = 0                                         │   │
│  │                                                              │   │
│  │  ── 降级（需连续 3 次）───────────────────────────────────── │   │
│  │  if urgency_level == 0:                                      │   │
│  │      calm_streak += 1                                        │   │
│  │      if calm_streak >= 3:                                    │   │
│  │          last_urgency_level = 0  # 降回平静                  │   │
│  │      # calm_streak < 3 时 last_urgency_level 不变            │   │
│  │                                                              │   │
│  │  本次返回 urgency=2：                                        │   │
│  │      last_urgency_level = 2，calm_streak = 0                 │   │
│  │  ↓                                                           │   │
│  │  下一条 turn=24 到达 → interval=1 → 每条立即触发              │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  Step 8：写 DB                                                      │
│    UPDATE live_turns SET suggestion=? WHERE turn_index=23           │
│    INSERT live_events (event_type="suggestion", ...)                │
│                                                                     │
│  Step 9：push SSE "suggestion"                                      │
│    payload = {                                                      │
│      "type":          "suggestion",                                 │
│      "text":          "先给出大概数字，再说需要核实",                 │
│      "emotion_tag":   "😤 对方施压",                                │
│      "skill_hint":    "数据防御",                                   │
│      "turn_index":    23,                                           │
│      "urgency_level": 2,            ← 新增，iOS 据此决定展示样式     │
│      "speech_act":    "command",    ← 新增                         │
│    }                                                                │
│    → live_pubsub.push_event() → iOS SSE 收到 → 气泡高亮 + 震动      │
└─────────────────────────────────────────────────────────────────────┘
```

---

### 5.4 _state 读写循环（跨多条 turn）

```
                   ┌──────────────────────────────────────────┐
                   │  _state[session_id]（内存，持续存在）       │
                   │  last_urgency_level = 0（初始平静）         │
                   └────────────────┬─────────────────────────┘
                                    │ 每条 turn 到达时 "读"
                                    ▼
turn_index=0  → on_turn_received → interval=6 → 不触发（turns_since=3<6）
turn_index=3  → on_turn_received → interval=6 → 不触发（turns_since=3<6）
turn_index=6  → on_turn_received → interval=6 → ✅触发
                   │
                   ▼ _run_quick_suggestion（后台）
                   Gemini返回 urgency_level=0
                   ↓ 写回 _state：calm_streak=1，urgency=0，interval 仍=6
                   │
turn_index=12 → on_turn_received → interval=6 → ✅触发
                   │
                   ▼ Gemini返回 urgency_level=1（领导开口提问）
                   ↓ 写回 _state：urgency_streak=1 → last_urgency_level=1，interval=3
                   │
turn_index=15 → on_turn_received → interval=3 → ✅触发（turns_since=3）
                   │
                   ▼ Gemini返回 urgency_level=2（领导追问数字）
                   ↓ 写回 _state：urgency_streak=2 → last_urgency_level=2，interval=1
                   │
turn_index=16 → on_turn_received → interval=1 → ✅触发（每条都触发）
turn_index=17 → on_turn_received → interval=1 → ✅触发
turn_index=18 → on_turn_received → interval=1 → ✅触发
                   │
                   ▼ Gemini返回 urgency_level=0（话题缓和）
                   ↓ calm_streak=1，but streak<3，last_urgency_level 仍=2
                   │
turn_index=19 → interval=1 → ✅触发（还没降回来）
                   ▼ urgency=0 → calm_streak=2
turn_index=20 → interval=1 → ✅触发
                   ▼ urgency=0 → calm_streak=3 → last_urgency_level=0，interval=6
                   │
turn_index=26 → on_turn_received → interval=6 → ✅触发（恢复平静节奏）
```

---

### 5.5 live_segment_manager（不变，并行运行）

```
每 10 条 turn（turn_index=9,19,29...）：
    取最近 20 条 turn + 旧摘要（~1300 tokens，恒定）
        │
        ▼ Gemini Flash（生成新摘要）
        │
        ▼ UPDATE live_segments SET running_context=?
        │
        ▼ push SSE "segment_context" → iOS 顶部摘要区更新
```

running_context 更新后，下一次 _run_quick_suggestion 的 Layer 2 自动使用最新摘要。

---

## 六、SSE Payload 变化

### suggestion（改动）

```json
{
  "type": "suggestion",
  "text": "先给大概数字，再说需要核实",
  "emotion_tag": "😤 对方施压",
  "skill_hint": "数据防御",
  "turn_index": 23,
  "urgency_level": 2,
  "speech_act": "command"
}
```

> `relevant_to_user=false` 的 turn 不产生 SSE，iOS 不会收到任何 suggestion 事件。
> 转录气泡（SSE "transcript"）不受影响，仍正常显示所有人的发言。

### analysis_ready（不变）

```json
{
  "type": "analysis_ready",
  "skill_cards": [...],
  "primary_scene": "workplace",
  "turn_range": [20, 29]
}
```

### segment_context（不变）

```json
{
  "type": "segment_context",
  "text": "..."
}
```

---

## 七、iOS 侧变化

### LiveSSEClient（不变）

`rawSuggestions: [[String: Any]]` 已是字典数组，`urgency_level` 和 `speech_act` 直接从 dict 读取，**无需改 Swift 数据模型**。

### LiveSessionView — InlineSuggestionBubble（改动）

`SuggestionData` 新增字段：
```swift
struct SuggestionData {
    let urgencyLevel: Int    // 0 / 1 / 2（新增，默认 0）
    let speechAct: String    // "neutral" / "question_to_me" / "challenge" / "command"（新增）
    // ... 原有字段不变
}
```

视觉差异：
```
urgency_level = 0  → 当前样式（灰色背景 Color(white: 0.18)）
urgency_level = 1  → 左边框黄色，背景略亮
urgency_level = 2  → 左边框橙红色 + 字号 +1pt + UIImpactFeedbackGenerator(.medium) 触觉反馈
```

---

## 八、改动文件清单

| 文件 | 改动内容 | 行数 |
|------|---------|------|
| `server_code/services/live_turn_processor.py` | ① `_QUICK_PROMPT` 扩展 urgency_level/speech_act/speaker_role_section；② `_get_state()` 加 urgency_streak/calm_streak/last_urgency_level；③ `on_turn_received()` 动态 interval；④ `_run_quick_suggestion()` 加 speaker role DB 查询 + 解析新字段 + 更新状态机 + 更新 SSE payload | +50~60 行 |
| `Models.swift/.../Views/LiveSessionView.swift` | `SuggestionData` 加 urgencyLevel/speechAct；`InlineSuggestionBubble` 视觉差异化 | +20 行 |

**共 2 个文件，无 DB Schema 改动，无新 API。**

---

## 九、边界情况处理

| 情况 | 处理方式 |
|------|---------|
| 声纹未识别，speaker role 未知 | speaker_desc="未识别说话人"，Gemini 凭内容判断 urgency，仍能正常工作 |
| `relevant_to_user=false`（背景噪音/无关对话） | 跳过 suggestion 生成，不更新状态机，转录气泡照常显示 |
| Gemini 返回格式错误，字段缺失 | `relevant_to_user` 默认 true，`urgency_level` 默认 0，`speech_act` 默认 neutral，不影响主流程 |
| 突发紧急事件恰好在刚触发后第 1 条 | 最多等 interval-1 条（平静模式最坏 3 条），20s 超时兜底 |
| 服务重启，_state 清空 | 重置到平静模式（interval=4），新 turn 到达后自适应重建状态 |
| `urgency=2` 但用户不看屏幕（戴眼镜场景） | 震动提醒（haptic），不依赖视觉注意力 |
| 连续多个 `relevant_to_user=false` | 状态机保持上一个有效模式，不会因噪音被强制降级 |

---

## 十、技能匹配现状与差距分析

### 10.1 当前两条路径的技能支撑

| 路径 | 触发频率 | 有技能库匹配？ | 技能来源 | 耗时 |
|------|---------|-------------|---------|------|
| 快速路径（建议气泡） | 每 1-4 条 turn | ❌ **没有** | `skill_hint` 是 Gemini 自由发挥的关键词 | ~1-2s |
| 异步路径（技能卡片） | 每 10 条 turn | ✅ 有 | 真实查 `skills` 表 → Gemini 选 top 3 | ~2.5-4.5s |

### 10.2 异步路径技能匹配流程

```
Step 1：场景分类（Gemini Flash）
  → {"primary_scene": "social", "confidence": 0.8}
  （仅 5 类：workplace / family / education / social / other）

Step 2：DB 查询（无场景预过滤）
  SELECT * FROM skills WHERE enabled=True ORDER BY priority DESC LIMIT 20
  → 返回优先级最高的 20 个技能（不区分场景）

Step 3：Gemini Flash 选 top 3（结合当前场景 + 对话内容）
  → [{"skill_name":"主动倾听","advice":"...","reminder":"..."},...]

Step 4：通过 SSE "analysis_ready" 推给 iOS 展示技能卡片
```

耗时分解：场景分类 ~1s + DB查 ~5ms + 技能选取 ~1s + 建议生成 ~1-1.5s = **共 ~3-4.5s**

### 10.3 情侣/双方沟通场景能匹配到技能吗？

**能，但有两个限制：**

1. **场景分类粒度粗**：情侣沟通 → 被归为 `"social"` 或 `"family"`，不是精确的"情侣"标签，Gemini 需要从对话内容自己判断
2. **技能优先级决定命运**：查的是 `priority DESC LIMIT 20`，不按场景预过滤。情侣沟通技能需要 `enabled=True` 且优先级够高才能进入候选池

### 10.4 核心差距（Gap）

**快速路径（高频）没有技能库支撑，全靠 LLM 即兴发挥。**

```
用户实际体验：
  每条建议 → "先给大概数字，再说需要核实"  （没有技能框架，纯经验）
  每 10 条   → 弹出技能卡片：「非暴力沟通」「主动倾听」（有专业框架）

问题：两者脱节。建议气泡不知道技能卡片的存在，技能卡片也不被建议气泡引用。
```

### 10.5 快速路径技能接入（待决策）

**方案 A（轻量）**：异步路径完成后缓存已匹配技能，快速路径 prompt 注入技能名称
```
_state[session_id]["active_skills"] = ["主动倾听", "非暴力沟通"]
↓
快速路径 prompt 增加一行：
"当前可用技能：主动倾听、非暴力沟通。若适用，请在建议中引用。"
```
- 优点：快速路径不增加 Gemini 调用，零额外耗时
- 缺点：第一个 10 turn 之前无可用技能缓存（前 10 条建议仍无技能支撑）

**方案 B（激进）**：快速路径每次也查 DB，用 Gemini 一次输出 suggestion + 匹配技能
- 优点：每条建议都有技能支撑
- 缺点：prompt 变长，耗时增加 0.3-0.5s，成本增加

**当前决策：暂不改快速路径的技能逻辑，优先实现状态机和说话人识别（Phase 1-3），技能接入作为 Phase 4 再决策。**

---

## 十一、分阶段实现计划

### Phase 1 — 后端状态机核心（最高优先级）

**目标**：实现自适应触发频率 + urgency 信号传给 iOS

**改动文件**：`server_code/services/live_turn_processor.py`（仅此 1 个文件）

**改动内容**：
1. `_QUICK_PROMPT`：新增 `relevant_to_user`、`urgency_level`、`speech_act` 输出字段
2. `_get_state()`：新增 `last_urgency_level`（默认 0）、`calm_streak`（默认 0）字段
3. `on_turn_received()`：根据 `last_urgency_level` 动态计算 interval（0→4条，1→3条，2→1条）
4. `_run_quick_suggestion()`：解析新字段 → 执行非对称状态机更新 → SSE payload 加 urgency/speech_act
5. `relevant_to_user=false` 时提前 return，不推 SSE，不更新状态机

**风险**：低。无 DB 改动，无 iOS 改动，无新 API。
**可独立验证**：看服务端日志中 interval 是否随 urgency 变化。

---

### Phase 2 — 后端说话人三层识别

**目标**：prompt 里能看到"张总（领导）"而非"Speaker_2"

**改动文件**：`server_code/services/live_turn_processor.py`（仍仅此 1 个文件）

**改动内容**：
1. `_run_quick_suggestion()` 开头：按 `speaker_label` 批量查 `live_speaker_mappings` → `profiles`
2. 组装 `speaker_map = {"Speaker_2": "张总（领导）", "Speaker_1": "我"}`
3. 格式化 prompt 时替换 speaker label 为真实描述

**前提**：Phase 1 已完成（在同一函数里加几行 DB 查询）

**风险**：低。新增 2 次 DB 查询（每次 suggestion 触发），数据已存在。

---

### Phase 3 — iOS 视觉差异化

**目标**：危急建议橙红边框+震动，警觉建议黄色边框，平静建议保持原样

**改动文件**：`Models.swift/.../Views/LiveSessionView.swift`（仅此 1 个文件）

**改动内容**：
1. `SuggestionData`：加 `urgencyLevel: Int`（默认 0）、`speechAct: String`（默认 "neutral"）
2. 从 SSE payload 解析新字段（`rawSuggestions` 已是字典，直接读取）
3. `InlineSuggestionBubble`：按 urgencyLevel 切换边框颜色 + 字号 + haptic

**前提**：Phase 1 已完成（服务端开始输出 urgency_level 字段）

**风险**：低。纯 UI 变化，逻辑无变化。旧数据无 urgency_level 字段默认为 0，兼容。

---

### Phase 4 — 快速路径技能接入（待定）

**目标**：每条建议气泡能引用技能库（"用主动倾听：..."）

**推荐方案 A**（缓存注入，零额外耗时）：
1. 异步路径完成后，在 `_state[session_id]["active_skills"]` 写入已匹配技能名称
2. 快速路径 prompt 末尾注入一行 `当前推荐技能：[名称列表]`
3. Gemini 在建议中选择性引用

**改动文件**：`live_turn_processor.py`（异步路径写缓存 + 快速路径读缓存）

**时机**：Phase 1-3 稳定后再做，因为要先有 urgency 信号才能评估技能引用的效果。

---

### 实现顺序总结

```
Phase 1（1-2天）── live_turn_processor.py 状态机
    │ 完成后可独立测试后端自适应触发
    ▼
Phase 2（0.5天）── live_turn_processor.py 说话人识别
    │ 完成后可测试 prompt 里出现"张总（领导）"
    ▼
Phase 3（0.5天）── LiveSessionView.swift 视觉差异化
    │ 完成后用户在 iOS 上能看到危急/警觉/平静三种气泡样式
    ▼
Phase 4（待定）── 快速路径技能库接入
    前提：Phase 1-3 稳定；需要和产品确认技能引用的 UX 表达
```

**Phase 1 + Phase 2 共改 1 个文件（`live_turn_processor.py`），可以一次 PR 完成。**
**Phase 3 改 1 个文件（`LiveSessionView.swift`），可以独立 PR。**

---

## 十二、验证方法

### Phase 1 验证（后端日志）

1. **平静模式降频**：连续轻松对话，日志中 interval=4，约每 4 条触发一次（不再是固定 3 条）
2. **升级瞬时**：Gemini 第一次返回 urgency=1，日志下一条 turn interval 立即=3
3. **危急升级瞬时**：Gemini 第一次返回 urgency=2，下一条 turn interval=1（每条都触发）
4. **降级需 3 次**：话题缓和，连续 3 次 urgency=0 后才降，期间日志 interval 仍=1
5. **噪音过滤**：relevant_to_user=false，日志无 SSE push，_state 不变

### Phase 2 验证（后端日志）

6. **声纹已匹配**：Speaker_2 对应张总，日志 prompt 里出现"张总（领导）"，urgency≥1
7. **声纹未匹配**：无档案的说话人，prompt 里显示"未识别说话人"，urgency 正常判断

### Phase 3 验证（iOS 真机）

8. **视觉差异**：urgency=2 气泡橙红边框 + 震动；urgency=1 黄色边框；urgency=0 灰色原样
9. **普通会话不受影响**：非 live session 的建议展示样式不变（兼容旧数据无 urgency 字段）
