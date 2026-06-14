# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## 改代码前必须执行
1. git status 确认工作区干净
2. git checkout -b fix/描述性名字
3. 改完后 git diff 给我看，我确认再 commit
4. 每个独立功能一个 commit，不许攒

## 禁止行为
- 禁止在 main/master 直接改代码
- 禁止一次 commit 超过 3 个文件（除非是重构）
- 禁止改完不测试就说"好了"

这样最坏情况：git checkout main 一键回到安全状态。

---

## 每次改代码前必须回答
1. 这个文件被哪些其他文件 import？
2. 我改的函数/接口，调用方有哪些？
3. 改完后哪些功能需要手动验证？

不回答这三个问题，不许动代码。
实际用的时候，你问 Claude 之前先说：
"按照 CLAUDE.md 规定，先做影响分析再改"

---

## 改动范围控制
- 只改最小必要的代码，不顺手重构
- 不确定的逻辑加注释 TODO，不擅自改
- 新增功能优先新文件，不改已有文件
- 改接口必须保持向后兼容

Claude 最危险的习惯是顺手优化——你让它改 A，它顺便把 B、C 也重构了。

---

## 改完后必须手动验证
- [ ] 用户能正常登录
- [ ] 技能库能加载
- [ ] 图片生成流程跑通
- [ ] 改动直接相关的功能

---

## 让 Claude 自己 Review 自己

改完之后，新开一个对话，把 diff 贴进去：

```
你是代码审查员，不是写这段代码的人。
以下是刚刚的改动 diff：
[粘贴 git diff]

请检查：
1. 有没有引入新的 bug
2. 有没有破坏其他功能的风险
3. 有没有不必要的改动
```

新对话没有上下文包袱，更容易发现问题。

---

## 📂 必读文档路径

每次改代码前，除读取本文件外，还必须读取以下文档目录中的相关文件：

- 文档根目录：`~/Desktop/0226new/doc/`
- 架构总览：`~/Desktop/0226new/doc/architecture.md`
- 模块文档：`~/Desktop/0226new/doc/modules/[对应模块].md`

读取规则：根据本次修改涉及的模块，读取对应的模块文档。
若不确定读哪个，读取目录下所有文件的文件名，再判断。

---

## 项目结构速查

### 后端
- 主入口：`~/main.py`（单体，5400+ 行，部署在 GCP 34.74.150.225）
- 已独立模块：`assistant.py`、`scene_image_generator.py`、`api/`、`services/knowledge_graph.py`
- 部署方式：`scp` 直接覆盖，**服务器上没有 git**
- 日志：`~/gemini-audio-service.log`

### iOS 前端
- 真实 Xcode 项目路径：`Models.swift/WorkSurvivalGuide/WorkSurvivalGuide/`
- 备份目录（不要直接改这里）：`iOS_Code_Files/`
- NetworkManager.swift 是所有 API 调用的单一入口

### 关键注意
- 改 iOS 代码必须改 `Models.swift/WorkSurvivalGuide/` 下的文件，不是 `iOS_Code_Files/`
- 新增 API 调用必须同时在 `NetworkManager.swift` 添加对应方法
- main.py 中 `baseURL` 变量名为 `baseURLForRead`（不是 `baseURL`）
