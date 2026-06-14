# API 接口文档

Base URL：`https://34.74.150.225`（Nginx 80 端口）
本地开发：`http://localhost:8000`
交互式文档：`/docs`（Swagger）、`/redoc`

所有需要认证的接口在 Header 中传：`Authorization: Bearer <JWT>`

---

## 认证

### POST /api/v1/auth/login
手机号/邮箱登录，返回 JWT Token。

**请求：**
```json
{
  "phone": "13800138000",
  "password": "xxx"
}
```
**响应：**
```json
{"access_token": "eyJ...", "token_type": "bearer"}
```

### POST /api/v1/auth/register
注册新用户。

### POST /api/v1/auth/send-code
发送手机验证码。

---

## 音频上传与分析

### POST /api/v1/audio/upload ⭐
上传录音文件，触发异步 Gemini 分析。需认证。

**请求：** `multipart/form-data`
- `file`：音频文件（mp3/wav/m4a）
- `title`（可选）：录音标题

**响应：**
```json
{
  "code": 200,
  "data": {
    "session_id": "uuid",
    "status": "processing",
    "created_at": "2026-05-30T..."
  }
}
```

> 上传后立即返回，分析在后台执行。前端轮询 `GET /sessions/{id}/status`。

---

## 任务（Session）管理

### GET /api/v1/tasks/sessions
获取当前用户的录音列表，支持分页。

**Query：** `page`、`page_size`、`status`（可选过滤）

**响应：**
```json
{
  "sessions": [{
    "session_id": "uuid",
    "title": "与领导的谈话",
    "status": "completed",
    "emotion_score": 65,
    "speaker_count": 2,
    "card_title": "预算削减争议",
    "cover_image_url": "https://oss.../..."
  }],
  "pagination": {"total": 100, "page": 1, "page_size": 20}
}
```

### GET /api/v1/tasks/sessions/{session_id}
获取录音详情，包含完整对话和分析结果。

**响应关键字段：**
```json
{
  "status": "completed",
  "dialogues": [{"speaker": "Speaker_0", "content": "...", "tone": "愤怒"}],
  "risks": ["PUA行为检测"],
  "conversation_summary": "今天和领导谈了预算问题...",
  "speaker_mapping": {"Speaker_0": "profile-uuid"},
  "speaker_names": {"Speaker_0": "张总（领导）"},
  "audio_url": "https://..."
}
```

### GET /api/v1/tasks/sessions/{session_id}/status
轮询分析进度。前端每 2-3 秒调用一次，直到 `status != "processing"`。

**响应：**
```json
{
  "status": "processing",
  "analysis_stage": "matching_skills",
  "analysis_stage_detail": {"skills_matched": 2}
}
```

**status 值：** `processing | completed | failed | archived`

### DELETE /api/v1/tasks/sessions/{session_id}
删除录音及相关分析结果（级联删除）。

### POST /api/v1/tasks/sessions/{session_id}/strategies ⭐
触发策略分析（场景分类 → 技能匹配 → 技能执行 → 图片生成）。
通常由前端在 status=completed 后自动调用。

**响应：**
```json
{
  "code": 200,
  "data": {
    "scene_category": "workplace",
    "skill_cards": [
      {
        "skill_id": "emotion_recognition",
        "content_type": "emotion",
        "content": {"mood_state": "Anxious", "mood_emoji": "😰", "mood_emoji_url": "..."}
      },
      {
        "skill_id": "workplace_jungle",
        "content_type": "strategy",
        "content": {
          "visual": [{"scene_description": "...", "scene_tag": "..."}],
          "strategies": [{"title": "...", "content": "..."}]
        }
      }
    ]
  }
}
```

### POST /api/v1/tasks/sessions/{session_id}/classify-scene
单独触发场景分类（调试用）。

---

## AI 助手

### POST /api/v1/assistant/chat ⭐
与 AI 助手对话，**SSE 流式响应**。需认证。

**请求：**
```json
{
  "session_id": "uuid",
  "skill_id": "workplace_jungle",
  "message": "他为什么要这么对我？",
  "history": [{"role": "user", "content": "..."}, {"role": "assistant", "content": "..."}],
  "image_base64_list": ["..."]
}
```

特殊 message 值：
- `"__INIT__"`：首次进入，AI 主动开场
- `"__SWITCH__"`：切换技能，AI 过渡引导

**SSE 事件流：**
```
data: {"type": "meta", "skill_name": "职场丛林法则", "memory_used": true}
data: {"type": "token", "content": "这是个"}
data: {"type": "token", "content": "典型的..."}
...
data: {"type": "suggestions", "items": ["他是故意的吗?", "我该怎么回应?", ...]}
data: {"type": "meme", "url": "https://klipy.../...", "category": "feel_you"}
data: {"type": "done"}
```

---

## 档案管理

### GET /api/v1/profiles
获取用户的所有人物档案。

### POST /api/v1/profiles
创建新档案（姓名、关系、照片等）。

### PUT /api/v1/profiles/{id}
更新档案信息。

### DELETE /api/v1/profiles/{id}
删除档案。

### POST /api/v1/profiles/{id}/upload-photo
上传档案照片（存 OSS）。

---

## 用户状态与情绪

### GET /api/v1/status/avatar
获取用户当前情绪头像状态（压力桶、mood_emoji 等）。

### POST /api/v1/status/vent
"打沙袋"解压操作，更新压力值。

### GET /api/v1/tasks/emotion-trend
获取情绪趋势折线图数据（按时间）。

---

## 图片与样式

### GET /api/v1/image-styles
获取可选的图片风格列表（pixar、ghibli、shinkai 等）。

### PUT /api/v1/users/me/preferences
更新用户偏好（如 image_style）。

### GET /api/v1/images/{session_id}/{image_index}
获取场景生成图片（代理返回 OSS 图片内容）。

### GET /api/v1/style-thumbnails/{style_key}
获取风格缩略图。

---

## 技能系统

### GET /api/v1/skills
获取技能列表（按 category 分类）。

### GET /api/v1/skills/{skill_id}
获取单个技能详情（含 prompt_template）。

### GET /api/v1/ability-scores
获取用户技能能力雷达图分数（基于历史 skill_executions）。

---

## 系统

### GET /health
```json
{"message": "音频分析服务正在运行", "status": "ok"}
```

### GET /test-gemini
测试 Gemini API 连通性（调试用，无需认证）。

### GET /api/v1/sessions/{session_id}/image-status
单独轮询图片生成状态（`pending/generating/completed/failed`）。

---

## 通用响应格式

```json
{
  "code": 200,
  "message": "success",
  "data": {...},
  "timestamp": "2026-05-30T12:00:00"
}
```

错误响应使用标准 HTTP 状态码 + FastAPI `HTTPException`：
```json
{"detail": "具体错误信息"}
```
