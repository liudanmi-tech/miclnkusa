# 数据库结构

PostgreSQL 15+，通过 SQLAlchemy async ORM 操作。模型定义在 `models.py`。

---

## 业务表

### users

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID PK | |
| phone | String(11) unique | 手机号登录 |
| email | String(200) | 邮箱登录 |
| apple_user_id | String(255) unique | Apple Sign-In |
| password_hash | String(255) | 密码登录 |
| subscription_tier | String(50) | `free` / `pro` |
| subscription_expires_at | DateTime | 订阅到期时间 |
| is_active | Boolean | 账号状态 |

---

### sessions（核心业务表）

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID PK | |
| user_id | UUID FK→users | |
| title | String(255) | 录音标题 |
| status | String(50) | `processing / completed / failed / archived` |
| analysis_stage | String(100) | 当前分析阶段（前端轮询用） |
| analysis_stage_detail | JSONB | 阶段详情（如已匹配技能数） |
| error_message | Text | 失败时错误信息（展示给用户） |
| emotion_score | Integer | 情绪综合评分（0-100） |
| speaker_count | Integer | 说话人数量 |
| audio_url | String(500) | OSS 音频 URL |
| audio_path | String(500) | 本地音频路径（无 OSS 时） |
| image_status | String(20) | `pending / generating / completed / failed` |
| tags | ARRAY(String) | 自动生成标签 |
| duration | Integer | 录音时长（秒） |

---

### analysis_results

`sessions` 的 1:1 关联，存储 Gemini Call #1 和 Call #2 的输出。

| 字段 | 类型 | 说明 |
|---|---|---|
| session_id | UUID FK unique | |
| dialogues | JSONB | 对话数组 `[{speaker, content, tone}]` |
| risks | ARRAY(String) | 风险点列表 |
| transcript | Text | 带时间戳转录（JSON 序列化字符串） |
| call1_result | JSONB | Call #1 完整原始响应 |
| speaker_mapping | JSONB | `{"Speaker_0": "profile_uuid", ...}` |
| card_title | String(100) | 对话核心主题（≤30字） |
| conversation_summary | Text | 第一人称日记总结（Call #2） |
| summary | Text | 简短摘要 |
| mood_score | Integer | 情绪分 |

---

### strategy_analysis

| 字段 | 类型 | 说明 |
|---|---|---|
| session_id | UUID FK unique | |
| skill_cards | JSONB | 技能卡片数组（见下方结构） |
| scene_images | JSONB | 场景图片数组 `[{scene_description, image_url, index}]` |
| scene_category | String(50) | 场景类别（workplace/family/education/brainstorm） |
| scene_confidence | Float | 场景分类置信度 |
| applied_skills | JSONB | 应用的技能 `[{skill_id, priority}]` |
| visual_data | JSONB | 兼容旧版（从 skill_cards 聚合） |
| strategies | JSONB | 兼容旧版（从 skill_cards 聚合） |

**skill_cards 结构：**
```json
[
  {
    "skill_id": "emotion_recognition",
    "skill_name": "情绪识别",
    "content_type": "emotion",
    "category": "personal",
    "content": {
      "mood_state": "Anxious",
      "mood_emoji": "😰",
      "mood_emoji_url": "https://oss.../...",
      "sigh_count": 3,
      "haha_count": 1
    }
  },
  {
    "skill_id": "workplace_jungle",
    "skill_name": "职场丛林法则",
    "content_type": "strategy",
    "category": "workplace",
    "content": {
      "visual": [{...}],
      "strategies": [{...}]
    }
  }
]
```

---

### skills（技能库）

| 字段 | 类型 | 说明 |
|---|---|---|
| skill_id | String(100) PK | 如 `workplace_jungle` |
| name | String(200) | 技能名称 |
| category | String(50) | workplace/family/education/brainstorm/personal |
| skill_path | String(500) | 技能目录路径 |
| prompt_template | Text | Prompt 模板（从 SKILL.md 读入） |
| meta_data | JSONB | 关键词、适用场景等 |
| priority | Integer | 默认匹配优先级 |
| enabled | Boolean | 是否启用 |

---

### profiles（人物档案）

| 字段 | 类型 | 说明 |
|---|---|---|
| user_id | UUID FK | |
| name | String(100) | 档案姓名 |
| relationship | String(50) | 自己/领导/同事/朋友/家人等 |
| photo_url | String(500) | 照片 URL |
| audio_session_id | UUID FK→sessions | 关联的声纹来源录音 |
| audio_start_time / end_time | Integer | 声纹音频时间片段（秒） |
| emoji_type | String(50) | 情绪头像风格（self/dog/cat） |

---

### 其他业务表

- **skill_executions**：技能执行历史（session → skill，记录耗时和成功率）
- **verification_codes**：短信验证码（phone + code + expires_at）
- **user_skill_preferences**：用户对技能的启用偏好（user + skill unique 约束）
- **custom_skills**：用户自定义技能（预留扩展）

---

## Knowledge Graph 表

替代 mem0ai，实现结构化、精准隔离的用户记忆。

### kg_persons
人物节点，同名自动合并（user_id + name 联合唯一）。

| 字段 | 说明 |
|---|---|
| name | 人物姓名 |
| rel_type | boss/colleague/friend/family/romantic/other |
| intimacy | 亲密度 1-10（滑动平均更新） |
| friction | 摩擦值 1-10 |
| power | superior/equal/subordinate |
| profile_id | 关联 profiles 表（可选） |

### kg_events
事件节点，通过 `kg_event_persons` 关联多个人物（多对多）。

| 字段 | 说明 |
|---|---|
| summary | 事件摘要 |
| sentiment | positive/neutral/negative |
| outcome | resolved/ongoing/escalated |
| session_id | 来源录音 |

### kg_goals / kg_skills
- `kg_goals`：用户目标跟踪（in_progress/completed/abandoned）
- `kg_skills`：每次对话匹配的技能记录（含关联人物 person_ids 数组）

---

## 数据库连接

```python
# database/connection.py
DATABASE_URL = os.getenv("DATABASE_URL")  # postgresql+asyncpg://...
engine = create_async_engine(DATABASE_URL, pool_size=10, max_overflow=20)
AsyncSessionLocal = async_sessionmaker(engine, expire_on_commit=False)
```

连接串格式：`postgresql+asyncpg://user:pass@host:5432/gemini_audio_db`
