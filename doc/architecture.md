# 整体架构

## 产品定位

用户录制职场对话 → AI 转录并分析情绪/风险 → 匹配教练技能 → 生成策略建议 + 场景图片 → AI 助手对话跟进。

---

## 技术栈

| 层 | 技术 |
|---|---|
| 后端框架 | FastAPI (async) |
| AI 模型 | Google Gemini 2.0 Flash（文本）/ Imagen（图片） |
| 数据库 | PostgreSQL 15+（asyncpg + SQLAlchemy async ORM） |
| 存储 | 阿里云 OSS（S3 兼容）—— 音频文件、生成图片 |
| 认证 | JWT（python-jose） |
| 记忆系统 | 自研 PostgreSQL Knowledge Graph（替代 mem0ai） |
| GIF | KLIPY API（AI 助手回复梗图） |
| 前端 | iOS Swift / SwiftUI（MVVM） |
| 部署 | Google Cloud VM（34.74.150.225）+ Nginx 反代 |

---

## 存储模块

> 详细分析见 [cunchu.md](./cunchu.md)

| 存储位置 | 实际地址 | 存什么 |
|---|---|---|
| PostgreSQL | **127.0.0.1:5432**（本机，非 RDS） | 全部结构化数据（15 张表，含 5 张 KG 表） |
| Cloudflare R2 | 私有 Bucket | 录音音频（新）、AI 场景图片、情绪头像 |
| 服务器本地磁盘 | `/opt/gemini-audio-service/data/` | 旧录音音频（迁 R2 前的历史数据，约 94 MB） |

**注意**：`architecture.md` 中"Aliyun RDS"的描述已过时，数据库实际运行在本机。当前 DB 仅 12 MB，承载上限约 50,000 活跃用户（磁盘限制），实际瓶颈为 Gemini API（~200 DAU 免费额度）。

---

## 系统架构图

```
iOS App
   │
   │ HTTPS
   ▼
Nginx (port 80)
   │ proxy_pass → 8000
   ▼
FastAPI (main.py)          ← 单体，5400+ 行
   ├── /api/v1/auth          auth/jwt_handler.py
   ├── /api/v1/skills        api/skills.py
   ├── /api/v1/profiles      api/profiles.py
   ├── /api/v1/audio-segments api/audio_segments.py
   ├── /api/v1/assistant/chat  assistant.py  ← SSE 流式
   └── 其余路由              main.py 内联
        │
        ├── Google Gemini API ←── Nginx outbound proxy
        │      ├── Call #1  转录 + 情绪/风险分析
        │      ├── Call #2  对话日记总结
        │      ├── Call #3  场景分类
        │      ├── Call #4+ 技能并行执行
        │      └── Imagen   场景图片生成
        │
        ├── PostgreSQL (127.0.0.1 本机，非 RDS)
        │      ├── 业务表（users/sessions/...）
        │      └── KG 表（kg_persons/kg_events/...）
        │
        └── Cloudflare R2（私有 Bucket）
               ├── 原始音频文件（新录音）
               ├── 生成场景图片
               └── 情绪头像（emotion_avatars/）
```

---

## 核心流程：音频上传分析

```
POST /api/v1/audio/upload
  │
  ├─ 1. 存文件（OSS 或本地临时）
  ├─ 2. 创建 Session（status=processing）
  ├─ 3. Gemini Call #1：转录 + 说话人/情绪/风险/is_me 标注
  ├─ 4. 写 AnalysisResult（dialogues, risks, transcript）
  ├─ 5. 声纹匹配：is_me → speaker_mapping → 写回 AnalysisResult
  ├─ 6. Gemini Call #2：第一人称日记总结（conversation_summary）
  ├─ 7. KG A-hook：从 transcript 提取人物/事件写入 kg_persons/kg_events
  └─ 8. Session.status = completed

（前端轮询到 completed 后，触发：）
POST /api/v1/tasks/sessions/{id}/strategies
  │
  ├─ 1. Gemini：场景分类（workplace/family/education/...）
  ├─ 2. 技能匹配：按场景 + 关键词，从 skills 表筛选
  ├─ 3. asyncio.gather 并行执行所有匹配技能（每技能一次 Gemini）
  ├─ 4. 构建 skill_cards（emotion 卡 | strategy 卡）
  ├─ 5. 并行：scene_image_generator 生成场景图（OSS 存储）
  ├─ 6. 写 StrategyAnalysis（skill_cards, scene_images）
  └─ 7. KG C-hook：kg_skills 记录本次技能匹配
```

---

## Nginx 双重代理

Nginx 承担两个角色：

1. **入站反代**：`80 → 8000`（iOS 访问 API）
2. **出站代理**：`/secret-channel → generativelanguage.googleapis.com`（GCP 服务器访问 Gemini，无需特殊网络）

---

## 部署方式

服务器上**没有 git 仓库**，代码通过 `scp` 直接覆盖部署。主入口：`~/main.py`，由 systemd 或手动 uvicorn 进程运行。

日志路径：`~/gemini-audio-service.log`
