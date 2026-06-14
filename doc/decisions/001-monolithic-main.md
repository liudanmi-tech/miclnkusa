# ADR-001: 保持 main.py 单体结构

## 状态
已采纳

## 背景
项目快速迭代阶段，`main.py` 已超过 5400 行，包含路由、业务逻辑、Pydantic 模型、工具函数。

## 决策
不拆分，保持单文件结构，直到某个功能模块**稳定且逻辑边界清晰**后，再提取到独立模块（如 `assistant.py` 已独立）。

## 理由
- 部署方式是直接 `scp` 覆盖单文件，拆分增加部署复杂度
- 快速迭代时跨文件引用成本高
- Gemini 分析的核心逻辑高度耦合（分析 → 声纹 → KG → 策略），分离会引入复杂的上下文传递

## 已独立的模块
- `assistant.py`：AI 助手 SSE 对话（独立 router）
- `api/auth.py`、`api/skills.py`、`api/profiles.py`、`api/audio_segments.py`：已通过 `include_router` 挂载
- `services/knowledge_graph.py`：KG 服务
- `scene_image_generator.py`：图片生成

## 何时应该拆分
当 main.py 超过 8000 行，或某个功能需要独立测试时，优先提取对应功能到 `services/` 或 `api/`。
