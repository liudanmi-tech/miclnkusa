# UGC 造梦 Demo（最小可行链路）

把《UGC 做梦者流程 · 细化方案》里的主线跑通一遍：

**上传一组照片 → 预处理 → 人物澄清 → 故事草稿 → 造梦师对话补全（充足度判定）→ 造梦（封面场景背景 + 画格）→ 首映 → 静止状态**

独立于 WorkSurvivalGuide 主工程，不依赖 `server_code/`、数据库和 iOS 端。

## 需要什么

只需要一个 **Gemini API Key**（Google AI Studio 申请）。视觉识别、对话抽取、写分镜、生图都走它：

| 用途 | 默认模型 | 每个梦境大约调用 |
| --- | --- | --- |
| 照片解析（框人、地点、活动、情绪、年代、安全标记） | `gemini-2.5-flash` | 1 次（所有照片一起） |
| 每轮回答 → 结构化更新 | `gemini-2.5-flash` | 每轮 1 次，约 6–10 次 |
| 首映分镜 / 心声 / 物件 / 初始记忆 | `gemini-2.5-flash` | 1 次 |
| 背景（以封面照片为参考，去人、风格化） | `gemini-3.1-flash-image-preview` | 1 次 |
| 画格（在背景上按外观描述画人物） | `gemini-3.1-flash-image-preview` | 1 次 |

生图模型一般需要开通付费的 key。没有 key 时自动进入**模拟模式**，整条流程用假数据也能点通。

## 运行

```bash
cd dream_demo
pip install -r requirements.txt
cp .env.example .env        # 填 GEMINI_API_KEY；国内网络再填 HTTPS_PROXY
uvicorn app:app --port 8765
# 浏览器打开 http://localhost:8765
```

数据存在 `dream_demo/data/<梦境id>/`（已被 .gitignore 忽略），每个梦境的完整状态在 `dream.json` 里。

## 方案里的每一步在哪里

| 方案章节 | 实现 | 简化了什么 |
| --- | --- | --- |
| 预处理：读取拍摄信息、去重、事件分组、排时间线、选封面 | `pipeline.py` `load_photo / dedupe / split_events`，`app.py` `_analyze` | 经纬度只用来切事件，不做反查地名，地点名由视觉模型从画面判断；多个事件时只取照片最多的一段 |
| 安全扫描 | 视觉模型输出 `safety`，裸露直接拒绝，疑似未成年进入保护模式 | 没有违法内容哈希比对 |
| 人物澄清 5 步 | 视觉模型框人 + 写外观 + 按衣着归组；"哪个是你"→ 点选标注 → 主要人物追问 | 不做人脸识别；主要人物按出现次数选，最多 4 个 |
| 故事草稿（节拍 + 空白） | `pipeline.py` `_build_scenes / _build_beats` | 两张照片间隔 ≥ 90 分钟算空白 |
| 充足度（关系 / 情感 / 行为 / 环境，权重 0.3/0.3/0.25/0.15） | `pipeline.py` `readiness` | 四项最低要求 + 总分 ≥ 0.75 时造梦师主动提议开始 |
| 下一个问题怎么选 | `pipeline.py` `next_question` | **Jev 用规则替代**：情绪价值 × 不确定性；用户提到的人和事 ×1.3；连续两个文字题后优先点选题；最多 8 题 |
| 回答 → 数据（带来源标记） | `llm.py` `extract_updates` + `pipeline.py` `apply_updates` | 能顺着话头追问（如"那一声喊的是什么"） |
| "就这样吧" | `fill_inferred`：缺的部分按常见情形补全并标记 `inferred` | — |
| 造梦：梦境规格、记忆复原剧本（锚点 + 自由时段） | `pipeline.py` `build_spec / build_script` | 只生成封面这一个场景的图 |
| 组装人物 | 画格提示词里按外观描述画人物，脸只用通用漫画脸 | **没有形象部件库**，人物直接由生图模型画；照片里的人像不作为人物的参考图 |
| 首映 | 前端按分镜逐格播放旁白和台词，触发物那一格停留更久，最后停在封面 | 8–12 格只有文字，配同一张画格 |
| 静止状态 | 点人物听心声、点物件看细节、看初始记忆 | 没有多镜头切换 |
| 循环 / 开拓 | 未实现 | 剧本已输出，是循环状态的骨架 |

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/dreams` | 上传照片（multipart `files`，1–20 张），后台解析 |
| GET | `/api/dreams/{id}` | 梦境完整状态（含 `pending` 当前问题、`readiness`） |
| POST | `/api/dreams/{id}/self` | `{group_id}` 点选自己，`null` = 照片里没有我 |
| POST | `/api/dreams/{id}/groups/{gid}` | `{action: name/passerby/exclude, text}` 标注人物 |
| POST | `/api/dreams/{id}/answer` | `{text}` / `{choice}` / `{stop: true}` |
| POST | `/api/dreams/{id}/build` | 开始造梦，后台生成 |
