# 技能匹配完整逻辑文档

> 更新时间：2026-06-19
> 对应代码：`server_code/skills/router.py`、`server_code/api/assistant.py`、`server_code/services/live_turn_processor.py`

---

## 一、触发入口（4个）

| 触发时机 | 接口 | 文件 | 函数 | 打分模型 |
|---------|------|------|------|---------|
| 录音结束后生成策略 | POST `/tasks/sessions/{id}/strategies` | `main.py` | `_generate_strategies_core()` | **Gemini** |
| AI Chat 每条消息 | POST `/assistant/chat` | `assistant.py` | `_match_skills_serial()` | **Groq llama-3.1-8b-instant** |
| Live 实时音频（每10轮） | WebSocket 转写 | `live_turn_processor.py` | `_run_async_analysis()` | **Gemini** |
| 仅分类场景 | POST `/tasks/sessions/{id}/classify-scene` | `main.py` | `classify_scene_endpoint()` | **Gemini** |

> ⚠️ **关键差异**：AI Chat 入口调用 `match_skills_v2(..., use_groq=True)`，使用 Groq llama-3.1-8b-instant（低延迟小模型）；其余入口走 `match_skills()` 兼容层（`use_groq=False` 默认值），使用 Gemini。Groq 调用失败时自动 fallback 到 Gemini。

---

## 二、主匹配函数：`match_skills_v2()`

### 函数签名

```python
async def match_skills_v2(
    transcript: list,          # 对话文本列表（含 speaker/text/is_me）
    profiles: list[dict] | None,  # 用户档案（含 relationship_type）
    user_id: str | None,
    db: AsyncSession,
    model=None,
    use_groq: bool = False,
) -> list[dict]
```

### 完整执行流程

```
Step 1  读取用户偏好
        _get_user_selected_skills(user_id, db)
        ↓
        查询 user_skill_preferences 表
        返回 (is_manual_mode: bool, selected_skill_ids: list)
        若无偏好记录 → 默认使用全部 43 个系统技能

Step 2  从档案强制推断分类（最高优先级）
        _forced_category_from_profiles(profiles)
        ↓
        扫描 profiles 的 relationship_type 字段：
          _WORKPLACE_REL_TYPES（领导/老板/上司/同事/下属/客户/HR/面试官...）→ 强制 work_life
          _FAMILY_REL_TYPES（老婆/丈夫/父母/孩子/兄弟姐妹/公婆...）→ 强制 family
        若匹配 → primary_category 固定，仍然调用 LLM 打分，但跳过 LLM 的分类判断

Step 3  关键词兜底猜测分类（档案无法判断时）
        _guess_category_from_transcript(transcript)
        ↓
        扫描全部对话文本关键词：
          work_life:      "老板/领导/同事/绩效/KPI/加班/薪资/上司..."    (≥1 个)
          family:         "老婆/丈夫/爸爸/妈妈/儿子/女儿/婆婆/公公..."   (≥1 个)
          campus_life:    "教授/老师/室友/论文/宿舍/导师/同学/作业..."    (≥1 个)
          relationships:  "男朋友/女朋友/分手/约会/暗恋/闺蜜/相亲..."    (≥1 个)
          life_skills:    "房东/医生/银行/客服/保险/租房/物业..."         (≥1 个)
          personal_growth:"自信/内耗/迷茫/焦虑/拖延/自我/成长..."        (≥2 个)

Step 4  分支：手动模式 vs 自动模式

   ┌── is_manual == True ──────────────────────────────────────┐
   │  _build_stubs_manual(selected_ids)                         │
   │  - 直接返回所有已选技能，按 iOS 分类分组                   │
   │  - 每个分类第一个技能 execute_now=True                     │
   │  - 无 LLM 调用，score=None                                │
   └───────────────────────────────────────────────────────────┘

   ┌── is_manual == False（默认）────────────────────────────── ┐
   │  classify_and_score(transcript, selected_ids, model)       │
   │  或                                                        │
   │  classify_and_score_groq(transcript, selected_ids)         │
   │  （见第三节：LLM 打分详情）                                │
   │      ↓                                                     │
   │  _build_stubs_auto(selected_ids, scores, primary_cat)     │
   │  （见第四节：过滤逻辑）                                    │
   └───────────────────────────────────────────────────────────┘

Step 5  追加固定技能
        _append_always_run(stubs, transcript)
        ↓
        ① emotion_recognition → 始终插入到第 0 位（always_run=True）
        ② depression_prevention → 条件触发（见下方）
```

---

## 三、LLM 打分：`classify_and_score()` / `classify_and_score_groq()`

### 模型选择

| 函数 | 模型 | 速度 | 质量 |
|------|------|------|------|
| `classify_and_score()` | Gemini 2.0 Flash | 较慢（~1-2s） | 高 |
| `classify_and_score_groq()` | Groq llama-3.1-8b-instant | 快（~250ms） | 低 |

### Prompt 结构（三步合一，单次调用）

```
Step 0：识别对话对象（13种）
  boss_or_superior / coworker_or_peer / subordinate /
  romantic_partner / parent_or_inlaw / child_or_teen /
  other_family / professor_or_teacher / classmate_or_roommate /
  close_friend / stranger_or_service / self_reflection / unknown

Step 1：场景分类（6个 iOS 分类）
  work_life      → Speaker B 有职场角色（老板/同事/客户/HR/面试官）
  campus_life    → 学术场景（教授/同学/室友）
  relationships  → 恋人/挚友
  family         → 家庭成员（父母/配偶/子女/兄弟姐妹）
  personal_growth→ 内部反思（焦虑/自我怀疑/拖延）
  life_skills    → 服务/实用（房东/医生/客服/银行）

Step 2：对所有选中技能逐一打分（0-100）
  80-100：高度相关，用户当前急需
  50-79 ：有一定相关性，可作背景参考
  0-49  ：基本无关
```

### 返回格式

```json
{
  "other_person_type": "boss_or_superior",
  "primary_category": "work_life",
  "scene_description": "员工就薪资问题与上级对话",
  "skill_scores": {
    "salary_negotiation": 95,
    "performance_reviews": 78,
    "difficult_boss": 45,
    "..."
  }
}
```

### JSON 解析容错（3种方式）

```
1. 直接 JSON.parse
2. 提取 markdown 代码块（```json ... ```）
3. 正则匹配花括号
```

### LLM 失败兜底

```
primary_category = 第一个选中技能的 iOS 分类
所有技能评分 = 50
```

---

## 四、自动模式过滤：`_build_stubs_auto()`

```
Step 1  按 iOS 分类分组所有技能

Step 2  计算每个分类的"代表分"= 该分类内的最高分

Step 3  计算贡献率，移除贡献率 < 5% 的分类（primary_category 除外）
        贡献率 = 该分类代表分 / 所有分类代表分之和

Step 4  排序并保留最多 3 个分类
        排序规则：primary_category 排第一，其余按代表分降序

Step 5  每个分类内过滤技能
        ✅ 只保留 score ≥ 90 的技能
        ✅ 每个分类最多保留 top 3
        ⚠️ 兜底：若 primary_category 内无 ≥90 分技能
           → 强制保留该分类最高分的 1 个技能（即使分数低于90）

Step 6  标记执行位
        每个分类第一个技能 execute_now = True
        其余 execute_now = False
```

### 关键阈值

| 参数 | 值 | 说明 |
|------|----|------|
| 技能执行最低分 | **90** | 低于此分不进入执行队列 |
| 每分类最多技能数 | **3** | 取 top 3 |
| 最多展示分类数 | **3** | 主分类 + 最多2个辅助 |
| 分类最低贡献率 | **5%** | 低于移除（主分类除外） |
| personal_growth 关键词数 | **≥ 2** | 其他分类 ≥ 1 即触发 |

---

## 五、分类优先级（完整链）

```
优先级 1：档案 relationship_type 强制推断
    领导/老板/同事... → work_life
    老婆/父母/孩子... → family
    ↓（若无匹配）

优先级 2：关键词扫描（兜底）
    扫描文本中各分类关键词数量
    ↓（若无匹配）

优先级 3：LLM 分类（classify_and_score Step 1 输出）
```

---

## 六、固定追加技能

### emotion_recognition（始终追加，插入第0位）

```
触发条件：无条件，每次必跑
执行位置：stubs[0]，always_run=True
输出内容：mood_state / mood_emoji / sigh_count / haha_count / char_count
```

### depression_prevention（条件触发，追加到末尾）

```
触发条件（满足任一）：
  危机词：  "不想活" / "想死" / "自杀" / "活不下去" / "死了算了"
            → 立即触发，crisis_alert=True

  普通负面词："焦虑" / "抑郁" / "压力" / "崩溃" / "没用" / "废物" / "我不配" ...
             + 用户文本字符数 ≥ 50
            → 触发，crisis_alert=False
```

---

## 七、Live 模式（简化版）：`_match_skills_fallback()`

```
触发条件：skills.router 不可用时的降级路径，或 live_turn_processor 直接调用

输入：
  scene_result  已分类的场景（primary_scene）
  transcript    最近 10 轮对话

流程：
  1. 查询 skills 表，enabled=True，按 priority DESC，取前 20 条
  2. 格式化技能列表：
     "1. skill_id=salary_negotiation name=Salary Negotiation category=work_life"
  3. 调用 Gemini Flash，Prompt：
     "对话场景={primary_scene}，从以下技能中选出最匹配的3个，只输出JSON数组"
  4. 解析 JSON 数组，返回 top 3

输出：
  [{"skill_id": "...", "skill_name": "...", "category": "...", "score": 85}]

注意：Live 简化版无 90 分过滤，直接返回 top 3，与主流程标准不统一
```

---

## 八、`match_skills()` 兼容层

```python
# 旧接口，router.py 对外暴露，内部转发到 match_skills_v2
async def match_skills(
    scene_result: dict,
    db: AsyncSession,
    transcript: list = None,
    profiles: list[dict] | None = None,
    user_id: str | None = None,
    model=None,
) -> list[dict]:
    return await match_skills_v2(
        transcript=transcript or [],
        profiles=profiles,
        user_id=user_id,
        db=db,
        model=model,
        # use_groq 默认 False → 走 Gemini
    )
```

---

## 九、输出的 Stub 结构

```python
{
    "skill_id":      "salary_negotiation",   # iOS 技能 ID 或 custom_uuid
    "skill_name":    "Salary Negotiation",
    "category":      "work_life",            # iOS 分类
    "score":         95,                     # 0-100，手动模式为 None
    "execute_now":   True,                   # 每个分类第一个为 True
    "is_custom":     False,
    "always_run":    False,                  # emotion_recognition 为 True
    "exec_template": "_exec_work_life",      # Gemini prompt 模板 ID
    "exec_context":  {                       # 填充 prompt 的参数
        "focus":        "salary or compensation negotiation",
        "sub_skill_cn": "薪资谈判",
        "angle":        "how to anchor, counter-offer, and close"
    },
    "content_type":  "pending",
    "content":       None,
}
```

---

## 十、完整执行流程示例（薪资谈判场景）

```
输入：
  用户说"我想和我老板谈涨薪"
  档案：[{name: "张总", relationship_type: "领导"}]

Step 1  档案强制推断
        relationship_type = "领导" → 在 _WORKPLACE_REL_TYPES 中
        → primary_category 强制为 "work_life"

Step 2  LLM 打分（Gemini / Groq）
        other_person_type = "boss_or_superior"
        primary_category  = "work_life"（与强制结果一致）
        skill_scores:
          salary_negotiation: 95  ✅ ≥90
          performance_reviews: 72  ❌ <90
          difficult_boss: 45      ❌ <90
          ...其余技能均 <90

Step 3  _build_stubs_auto()
        work_life 代表分 = 95
        其余分类代表分 = 0（无相关对话）
        → 仅保留 work_life（贡献率100%）
        → salary_negotiation 进入执行队列，execute_now=True

Step 4  _append_always_run()
        → emotion_recognition 插入 stubs[0]
        → 无危机/负面关键词 → depression_prevention 不触发

最终 stubs：
  [
    {skill_id: "emotion_recognition",  execute_now: True,  always_run: True},
    {skill_id: "salary_negotiation",   execute_now: True,  score: 95}
  ]

后续：
  → main.py asyncio.gather() 并行执行两个 stub
  → 存入 StrategyAnalysis 表
  → 客户端渲染 Always Tab（情绪卡）+ Work Life Tab（薪资谈判策略卡）
```

---

## 十一、已知问题 & 潜在原因

| 问题 | 可能原因 |
|------|---------|
| AI Chat 技能匹配不准 | Groq llama-3.1-8b 模型能力弱，对复杂场景理解差 |
| 90分阈值太高，相关技能被过滤 | 分数低于90的技能即使相关也不执行 |
| 英文对话关键词兜底失效 | `_guess_category_from_transcript` 关键词列表全是中文 |
| 档案关系类型不准导致分类错误 | 强制推断优先级最高，档案错误会直接影响分类 |
| Live 简化版标准不一致 | `_match_skills_fallback` 无90分过滤，直接返回top 3 |

---

## 十二、系统技能清单（43个）

| 分类 | 技能 ID |
|------|---------|
| work_life (8) | salary_negotiation, difficult_boss, work_boundaries, performance_reviews, feedback, job_interviews, coworker_conflicts, remote_work |
| campus_life (8) | roommate_conflicts, professor_email, group_projects, making_friends, asking_extensions, academic_burnout, internship_interview, networking |
| relationships (8) | partner_communication, talking_stage, ghosting_rejection, situationship, dtr_conversation, breakups, friendship_conflicts, coming_out |
| family (6) | parent_boundaries, immigrant_family, family_money, coparenting, parent_teen, coming_out_family |
| personal_growth (8) | assertiveness, imposter_syndrome, social_anxiety, burnout_recovery, anger_management, friend_crisis, dealing_criticism, boundary_setting |
| life_skills (5) | healthcare_navigation, financial_literacy, consumer_rights, neighbor_disputes, moving_housing |
| 固定技能 | emotion_recognition, depression_prevention |

---

## 十三、相关代码文件索引

| 文件 | 核心函数 |
|------|---------|
| `server_code/skills/router.py` | `match_skills_v2`, `classify_and_score`, `classify_and_score_groq`, `_build_stubs_auto`, `_build_stubs_manual`, `_append_always_run`, `_forced_category_from_profiles`, `_guess_category_from_transcript` |
| `server_code/api/assistant.py` | `_match_skills_serial`（Chat 入口，use_groq=True） |
| `server_code/main.py` | `_generate_strategies_core`（录音入口，use_groq=False） |
| `server_code/services/live_turn_processor.py` | `_run_async_analysis`, `_match_skills_fallback`（Live 入口） |
| `server_code/skills_config.json` | 43个系统技能定义、exec_template、exec_context |
