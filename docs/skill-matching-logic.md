# 技能匹配与输出整理逻辑

> 更新时间：2026-05-15

---

## 一、整体流程概览

```
用户语音 → 转录文本
    │
    ▼
[场景分类] classify_scene() — Gemini 一次调用
    │  → primary_category（6 个 iOS 分类之一）
    │  → scene_description（场景描述）
    │  → other_person_type（对话对象类型）
    │
    ▼
[技能匹配] match_skills_v2()
    │  → 对 43 个 iOS 技能 + 自定义技能评分 0-100
    │  → 过滤低分 / 用户偏好 / 手动模式
    │
    ▼
[并行执行] asyncio.gather()
    ├─ emotion_recognition   → 情绪洞察（每次必跑）
    ├─ depression_prevention → 心理健康分析（条件触发）
    └─ strategy 技能 × N    → 场景策略（Gemini 生成）
    │
    ▼
[组装 skill_cards] → 存入数据库
    │
    ▼
[客户端请求策略] → 渲染 Tab + 卡片
```

---

## 二、场景分类

### 2.1 六大 iOS 场景分类

| category | 适用场景 |
|---|---|
| `work_life` | 上下级、同事、客户、HR、面试官 |
| `campus_life` | 教授、同学、室友 |
| `relationships` | 恋人、挚友 |
| `family` | 父母、配偶、子女、兄弟姐妹 |
| `personal_growth` | 焦虑自省、拖延、自我怀疑 |
| `life_skills` | 房东、医生、客服、银行 |

### 2.2 对话对象类型（other_person_type）

```
boss_or_superior / coworker / subordinate / romantic_partner /
parent_or_inlaw / child_or_teen / other_family / professor_or_teacher /
classmate_or_roommate / close_friend / stranger_or_service /
self_reflection / unknown
```

---

## 三、技能匹配规则

### 3.1 自动模式（默认）

```
1. LLM 对全部技能评分 0-100
2. 按 iOS 分类分组
3. 过滤低分分类（贡献度 < 5% 的分类排除）
4. 强制保留 primary_category
5. 取分数最高的 ≤ 3 个分类
6. 每个分类内：分数 ≥ 90 的技能进入执行队列
   └─ 若主分类无 ≥ 90 的技能，保留最高分那个
7. 每个分类第一个技能标记 execute_now=True（立即执行）
```

关键阈值：

| 参数 | 值 |
|---|---|
| 技能执行最低分 | 90 |
| 每分类最多技能数 | 3 |
| 最多分类数 | 3 |
| 分类最低占比 | 5% |

### 3.2 手动模式

- 用户在 App 内手动选定技能，服务端只执行已选技能
- 始终保留：`emotion_recognition`、`depression_prevention`

### 3.3 情绪/心理触发条件

```
depression_prevention 触发条件（满足任一）：
- 文本含危机词（自杀、活不下去、绝望…）→ crisis_alert=True
- 文本含负面情绪词（焦虑、抑郁、压力…）→ 常规分析
```

---

## 四、skill_cards 数据结构

### 4.1 SkillCard 顶层

```json
{
  "skill_id":         "emotion_recognition",
  "skill_name":       "情绪识别",
  "content_type":     "emotion | mental_health | strategy | pending",
  "category":         "work_life | campus_life | relationships | family | personal_growth | life_skills",
  "dimension":        "role_position | scenario | psychology | career_stage | capability",
  "matched_sub_skill":"薪资谈判",
  "score":            95,
  "is_custom":        false,
  "content":          { ... }
}
```

### 4.2 content_type = "emotion"（情绪卡）

```json
{
  "sigh_count":     2,
  "haha_count":     5,
  "mood_state":     "高兴 | 焦虑 | 平常心 | 亢奋 | 悲伤",
  "mood_emoji":     "😊",
  "mood_emoji_url": "https://r2.cloudflarestorage.com/.../{user_id}/calm.png?presigned",
  "char_count":     1234
}
```

**mood_state → emoji 映射：**

| mood_state | emoji | R2 文件槽位 |
|---|---|---|
| 高兴 | 😊 | `happy.png` |
| 焦虑 | 😰 | `sad.png` |
| 平常心 | 😐 | `calm.png` |
| 亢奋 | 🤩 | `excited.png` |
| 悲伤 | 😢 | `sad.png` |

**mood_emoji_url 生成逻辑（Node 3/4）：**
```
1. 从 mood_state 映射出槽位名（happy/calm/sad/excited）
2. R2 key = emotion_avatars/{user_id}/{slot}.png
3. 生成 7 天有效期 presigned URL（无需鉴权）
4. 缓存策略返回时同步刷新 presigned URL（Node 4）
```

### 4.3 content_type = "mental_health"（心理健康卡）

```json
{
  "defense_energy_pct": 75,
  "dominant_defense":   "压抑",
  "status_assessment":  "整体状态尚稳定，但压力较大",
  "cognitive_triad": {
    "self":   { "status": "red | yellow | green", "reason": "自我评价偏低" },
    "world":  { "status": "yellow",               "reason": "感知外部有挑战" },
    "future": { "status": "green",                "reason": "对未来有期待" }
  },
  "insight":      "分析文字",
  "strategy":     "建议行动",
  "crisis_alert": false
}
```

**defense_energy_pct 颜色规则：**

| 范围 | 颜色 | 含义 |
|---|---|---|
| ≥ 70 | 🔴 红 | 心理负担重 |
| 40–69 | 🟡 黄 | 中等压力 |
| < 40 | 🟢 绿 | 状态良好 |

### 4.4 content_type = "strategy"（策略卡）

```json
{
  "visual": [
    {
      "transcript_index": 2,
      "speaker":      "Speaker_0",
      "image_prompt": "Ghibli-style illustration...",
      "emotion":      "焦虑",
      "subtext":      "情境简述",
      "context":      "场景背景",
      "my_inner":     "我的内心想法",
      "other_inner":  "对方的内心想法"
    }
  ],
  "strategies": [
    {
      "id":      "strategy_001",
      "title":   "Stay Calm",
      "label":   "沟通技巧",
      "emoji":   "🧘",
      "content": "详细建议内容"
    }
  ]
}
```

**visual 生成规则：**
- 最少 3 条，最多 5 条
- transcript_index 必须对应真实对话段落
- 不足 3 条时用策略场景图补充
- 所有文字输出强制英文

---

## 五、客户端渲染逻辑

### 5.1 Tab 结构

```
Tab 1（固定）：Always 类型
  └─ EmotionCard（情绪卡，必有）
  └─ MentalHealthCard（心理健康卡，条件显示）

Tab 2–N（动态）：按 iOS 分类一个 Tab
  └─ StrategyCard × 若干（含图片轮播 + 策略列表）
```

### 5.2 情绪卡（EmotionCard）渲染

```
┌─────────────────────────────────┐
│  [圆形头像 56×56]               │  ← 优先 moodEmojiUrl（R2 presigned）
│  或 😐（fallback Unicode emoji）│    降级 moodEmoji 文字
│                                 │
│  Calm（mood_state）             │
│  ─────────────────────────────  │
│  叹气 2 次   大笑 5 次          │  ← sigh_count / haha_count
│  共说 1,234 字                  │  ← char_count
└─────────────────────────────────┘
```

### 5.3 心理健康卡（MentalHealthCard）渲染

```
[crisis_alert=true 时显示]
┌─────────────────────────────────┐
│  ⚠️  建议寻求专业支持...        │
└─────────────────────────────────┘

防御负荷
[████████░░░░░░░░░░░░] 75% · 压抑

认知三角
┌──────────┬──────────┬──────────┐
│ 🔴 自我  │ 🟡 世界  │ 🟢 未来  │
│ 自评偏低 │ 有挑战   │ 有期待   │
└──────────┴──────────┴──────────┘

[洞察] 分析文字...
[建议] 行动建议...
```

### 5.4 策略卡（StrategyCard）渲染

```
┌─────────────────────────────────┐
│  [场景图片轮播]                 │  ← visual[] → Gemini 生成图片
│  emotion + subtext 字幕         │
└─────────────────────────────────┘

策略列表（最多 4 条）
┌─────────────────────────────────┐
│  🧘 Stay Calm           ›       │  ← 点击展开详情 Sheet
│  💬 Active Listening    ›       │
│  ...                            │
└─────────────────────────────────┘
```

---

## 六、关键字段映射速查

| content_type | 字段 | 用途 | 格式 |
|---|---|---|---|
| emotion | `moodEmoji` | 大表情 | Unicode 字符 |
| emotion | `moodState` | 情绪标签 | 文本 |
| emotion | `moodEmojiUrl` | 千人千面头像 | presigned URL，7天有效 |
| emotion | `sighCount` | 叹气次数 | 整数 |
| emotion | `hahaCount` | 大笑次数 | 整数 |
| emotion | `charCount` | 发言字数 | 整数 |
| mental_health | `crisisAlert` | 危机预警 | Bool → 红色横幅 |
| mental_health | `defenseEnergyPct` | 心理防御度 | 0-100 进度条 |
| mental_health | `dominantDefense` | 主要防御机制 | 文本标签 |
| mental_health | `cognitiveTriad.*.status` | 认知状态 | red/yellow/green |
| mental_health | `insight` | 分析洞察 | 段落文字 |
| mental_health | `strategy` | 行动建议 | 段落文字 |
| strategy | `visual[].imagePrompt` | 图片生成 | Gemini 图片提示词 |
| strategy | `visual[].emotion` | 情绪标注 | 文本 |
| strategy | `visual[].myInner` | 我的内心 | 文本 |
| strategy | `visual[].otherInner` | 对方内心 | 文本 |
| strategy | `strategies[].title` | 策略标题 | 英文 |
| strategy | `strategies[].content` | 策略详情 | 英文段落 |

---

## 七、服务端 → 客户端 完整示例

```
录音上传
  ↓
Gemini 转录
  ↓
classify_scene()
  → primary_category = "work_life"
  → scene_description = "员工就薪资问题与上级对话"
  ↓
match_skills_v2() + LLM 评分
  → emotion_recognition: 固定执行
  → salary_negotiation: score=95, execute_now=True
  → performance_review: score=91, execute_now=False
  ↓
asyncio.gather() 并行执行
  ├─ emotion_recognition
  │    → sigh=2, haha=0, mood_state="焦虑", mood_emoji="😰"
  │    → presigned URL → emotion_avatars/{uid}/sad.png
  │
  └─ salary_negotiation
       → Gemini 生成 visual[3] + strategies[4]
  ↓
skill_cards = [
  { content_type: "emotion",   ... },
  { content_type: "strategy",  category: "work_life", score: 95, ... }
]
  ↓
存入数据库
  ↓
客户端请求 /strategy
  → Node 4 刷新 presigned URL
  → 返回 skill_cards
  ↓
客户端渲染
  Tab: Always → EmotionCard（圆形头像 + 叹气/字数）
  Tab: Work   → StrategyCard（场景图轮播 + 薪资谈判策略）
```
