# 后端模块文档

## 文件结构

```
~/（服务器根目录 = 项目根）
├── main.py                 # FastAPI 主入口，5400+ 行，包含所有核心路由
├── models.py               # SQLAlchemy ORM 模型（独立于 database/ 目录）
├── profiles.py             # 档案管理路由（已迁移到 api/profiles.py，此为服务器上的旧版本）
├── assistant.py            # AI 助手 SSE 流式对话路由
├── scene_image_generator.py # 场景图片生成器
├── gen_emoji_presets.py    # 情绪头像预生成脚本
├── gemini-audio-service/
│   └── .env               # 环境变量配置
└── gemini-audio-service.log
```

---

## main.py 模块分区

`main.py` 是单体文件，内部按功能分区，以注释 `# ===` 分隔：

| 行范围（约） | 功能 |
|---|---|
| 1–200 | 导入、日志配置、lifespan（DB 初始化 + 技能初始化） |
| 200–500 | Pydantic 数据模型（AudioAnalysisResponse、Call1/2Response 等） |
| 500–1600 | Gemini 分析核心逻辑（analyze_audio_from_path） |
| 1600–1820 | 旧版 /analyze-audio 兼容接口 + 任务管理数据模型 |
| 1820–2400 | POST /api/v1/audio/upload（含声纹匹配、KG A-hook） |
| 2400–2900 | GET 任务列表/详情（sessions API） |
| 2900–3600 | POST /strategies（场景分类、技能并行执行、skill_cards 构建） |
| 3600–4200 | 图片相关 API（image-styles、images/{id}/{idx}、style-thumbnails） |
| 4200–5000 | 用户状态 API（avatar、vent、压力桶） |
| 5000–5434 | 技能雷达、周/月 recap、启动入口 |

---

## 关键子模块

### analyze_audio_from_path（核心分析函数）

位于 main.py ~500–1600 行，完整的 Gemini 分析流程：

1. 文件分片（>20MB 自动切割，Gemini 文件 API 限制）
2. 上传到 Gemini Files API（临时存储，分析后删除）
3. Call #1 Prompt：要求 Gemini 输出 JSON，包含：
   - `speaker_count`：说话人数量
   - `dialogues`：每句对话（speaker/content/tone）
   - `risks`：风险点
   - `transcript`：带时间戳的逐句转录（含 is_me 布尔标记）
   - `card_title`：核心主题短标题
4. 解析 JSON 响应（带重试和清洗逻辑）
5. 返回 `(AudioAnalysisResponse, Call1Response)`

**关键参数：**
- 模型：`GEMINI_TEXT_MODEL`（`gemini-2.0-flash`）
- 超时：Gemini 文件 API 无内置超时，依赖 uvicorn worker timeout

---

### 策略生成流程（POST /strategies）

位于 main.py ~2900–3600 行：

```python
# 1. 场景分类
scene = await classify_scene(transcript)  # Gemini 输出 scene_category + confidence

# 2. 技能匹配
matched_skills = await match_skills(scene, transcript, db)

# 3. 并行执行（关键：所有技能同时跑，不串行）
results = await asyncio.gather(*[execute_skill(skill, ...) for skill in matched_skills])

# 4. 构建 skill_cards
for result in results:
    if result.emotion_insight:
        card = {"content_type": "emotion", ...}
    elif result.visual and result.strategies:
        card = {"content_type": "strategy", ...}
```

**技能卡片类型：**
- `emotion`：情绪洞察（mood_state、sigh_count、haha_count、mood_emoji_url）
- `strategy`：策略建议（visual 场景描述 + strategies 行动建议列表）

---

### AI 助手（assistant.py）

`POST /api/v1/assistant/chat` — SSE 流式输出：

**SSE 事件序列：**
```
data: {"type": "meta", "skill_name": "...", "memory_used": true}
data: {"type": "token", "content": "..."}  ← 多次，流式
data: {"type": "suggestions", "items": ["q1","q2","q3","q4"]}
data: {"type": "meme", "url": "...", "category": "feel_you"}  ← 可选
data: {"type": "done"}
```

**Gemini 流式技巧：**
由于 `google-generativeai` SDK 的流式生成是同步阻塞的，通过 `threading.Thread` + `asyncio.Queue` 桥接到 async 上下文。

**SUGGESTIONS 解析：**
Gemini 在回复末尾输出 `[SUGGESTIONS]{...}[/SUGGESTIONS][MEME:category]`，SSE 生成器实时过滤，不推送给用户，只解析为结构化字段。

---

### Knowledge Graph 服务（services/knowledge_graph.py）

替代 mem0ai，直接用 PostgreSQL 实现结构化记忆：

| 函数 | 触发时机 | 写入表 |
|---|---|---|
| `save_kg_from_transcript` | 音频分析完成（A-hook） | kg_persons, kg_events, kg_event_persons |
| `save_kg_from_skills` | 策略生成完成（C-hook） | kg_skills |
| `save_kg_from_chat` | AI 助手每轮对话后（fire-and-forget） | kg_persons, kg_events |
| `get_ai_context_kg` | AI 助手 prompt 构建前 | 只读，3s 超时 |

所有写入均通过 `asyncio.create_task` 异步执行，不阻塞主流程。

---

### 场景图片生成（scene_image_generator.py）

- 使用 `google-genai` 新版 SDK（`genai_new`）调用 Imagen
- 每个 `VisualItem`（场景描述）生成一张图
- 图片以 base64 返回后上传到 OSS，写入 `StrategyAnalysis.scene_images`
- `Session.image_status`：`pending → generating → completed/failed`

---

## 环境变量

| 变量 | 说明 |
|---|---|
| `GEMINI_API_KEY` | Google Gemini API Key |
| `DATABASE_URL` | PostgreSQL 连接串（asyncpg 格式） |
| `PROXY_URL` | Gemini 出站代理地址（Nginx `/secret-channel`） |
| `PROXY_FORCE_LOCALHOST` | `true` 则强制走本机代理 |
| `ALIYUN_ACCESS_KEY_ID` | OSS 访问密钥 |
| `ALIYUN_ACCESS_KEY_SECRET` | OSS 访问密钥 |
| `OSS_BUCKET_NAME` | OSS Bucket 名 |
| `OSS_ENDPOINT` | OSS 端点 URL |
| `JWT_SECRET_KEY` | JWT 签名密钥 |
| `KLIPY_APP_KEY` | KLIPY GIF API Key（AI 助手梗图） |
| `UVICORN_PORT` | 服务监听端口（默认 8000） |

---

## 启动流程

```python
# lifespan() 启动钩子：
1. 检查代理连通性（3s 超时探测）
2. await init_db()         # 创建所有表（如不存在）
3. 预热连接池              # SELECT 1
4. await initialize_skills(db)  # 扫描 skills/ 目录，将 SKILL.md 写入 skills 表
```
