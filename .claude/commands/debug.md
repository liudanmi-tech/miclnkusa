# /debug — Session 日志诊断

**用法**：`/debug [sessionId] [可选：问题描述]`

**示例**：
- `/debug 36add431`
- `/debug 36add431-1efa-4d9c-b9c5-4f68a3ccbfe9 skill_tags 没有收到`
- `/debug 36add431 图片没有生成`

---

## 执行流程

### Step 1 — 识别 Session 类型

从参数中提取 sessionId（支持完整 UUID 或前8位缩写）。

先判断 session 类型（chat / review / live），决定用哪套诊断流程：

```bash
# SSH 到测试服（默认），如明确是正式服则用 34.74.150.225
ssh -i ~/.ssh/google_compute_engine liudanmi@34.74.255.48 \
  "grep '{sessionId}' ~/gemini-audio-service.log | head -5"
```

- 日志含 `[CHAT:{id}]` 前缀 → **chat session 诊断流程**（见下方）
- 日志含 `analyze_audio` / `upload` 等 → **review session 诊断流程**（原有）

---

### Step 2A — Chat Session 诊断

抓取全量日志，按流程节点分组：

```bash
ssh -i ~/.ssh/google_compute_engine liudanmi@34.74.255.48 \
  "grep '\[CHAT:{id8}\]' ~/gemini-audio-service.log | cat"
```

按以下阶段归类输出：

```
【Chat Session 诊断报告】
Session ID: {sessionId}
─────────────────────────────
🟦 阶段1：会话创建
  session created | user_id=xxx  ✅ / ❌ 缺失

🟦 阶段2：对话轮次（共 N 轮）
  Turn 1:
    /chat received | is_chat=True  ✅ / ❌
    KG lookup | memory_used=true elapsed_ms=xxx  ✅ / ❌ / ⚠️ 超时
    gemini stream started | skill_id=xxx  ✅ / ❌
    first token | ttft_ms=xxx  ✅(< 500ms) / ⚠️(500-1000ms) / ❌(> 1000ms)
    stream done | total_ms=xxx  ✅ / ❌
    skill_matching started  ✅ / ❌ 缺失（第1轮应有）
    strategy_analysis written  ✅ / ❌ 缺失
    skill_tags pushed  ✅ / ❌ / ⚠️ skill_tags dropped（SSE 已断开）
  Turn 2+：
    ...（strategy_analysis found=True）

🟦 阶段3：退出
  选择路径：close / generate_image / empty_delete（根据日志判断）
  close_chat_session received  ✅ / ❌ 缺失（可能强退）
  session archived  ✅ / ❌
  finalize started  ✅ / ❌
  finalize done | mood=xxx card_title=xxx  ✅ / ❌
  mood_state written | finalize_status=completed  ✅ / ❌

🖼️ 阶段4（如有）：生图
  generate_image_from_chat | conv_len=N style=xxx  ✅ / ❌
  synthetic_transcript built | user_turns=N mode=narration  ✅ / ❌
  scene_image triggered  ✅ / ❌
  scene_image done | url=xxx  ✅ / ❌
  scene_image failed | error=xxx  ❌

⚠️ 错误 & 警告（全部）
  {行号} {ERROR/WARNING 内容}

📊 最终状态：
  DB 查询（SSH 执行）：
  SELECT status, finalize_status, mood_state, image_status FROM sessions WHERE id='{id}';

─────────────────────────────
```

---

### Step 2B — Review Session 诊断（原有）

```bash
ssh -i ~/.ssh/google_compute_engine liudanmi@34.74.255.48 \
  "grep -n '{sessionId}' ~/gemini-audio-service.log | cat"
```

```
【Review Session 诊断报告】
Session ID: {sessionId}
─────────────────────────────
📥 上传阶段
  {时间} 文件大小 / 上传结果

🤖 Gemini 分析阶段
  Call #1 转录：{成功/失败/耗时}
  Call #2 日记：{成功/失败}
  策略生成：{技能数 / 耗时}

🖼️ 图片生成阶段
  image_status: {pending/generating/completed/failed}
  生成张数：{n}

⚠️ 错误 & 警告（如有）
  {行号} {ERROR/WARNING 内容}

📊 最终状态：{completed / failed / analyzing}
─────────────────────────────
```

---

### Step 3 — 问题定位

如果用户提供了问题描述（或诊断报告中发现异常），结合日志分析：

- 定位出错的具体步骤和日志行号
- 判断是代码 bug / 配置问题 / 外部服务（Gemini/DB）问题
- 给出根本原因结论

输出格式：

```
【问题定位】
现象：{用户描述 或 日志异常点}
根本原因：{分析结论}
出错位置：{文件:函数名 或 日志行号}
建议修复方案：{具体描述}
─────────────────────────────
```

---

### Step 4 — 影响评估（定位出问题后必须执行）

**4A — 修复方案的跨模块影响分析**

读取 `~/Desktop/0226new/doc/对话式交互0613.md` 中的模块清单（第四章），分析该 bug 修复会波及哪些模块：

```
【跨模块影响分析】
修复涉及文件：{文件列表}

直接影响模块：
  - {模块名}：{影响说明}

可能间接影响：
  - {模块名}：{影响说明，如"调用方接口签名变化"}
  - 无影响：{模块名列表}

需要联动验证的功能：
  - {功能1}：{验证方式}
  - {功能2}：{验证方式}
```

**4B — 风险评级**

综合以下维度评级（高/中/低）：

| 维度 | 说明 |
|---|---|
| 改动范围 | 改几个文件、几个函数 |
| 接口兼容性 | 是否改了接口签名或 DB schema |
| 测试覆盖 | 是否有现成验证手段（curl / 日志） |
| 回滚难度 | git revert 能否一键还原 |
| 影响用户数 | 所有用户必经路径 vs 边缘路径 |

输出格式：

```
【风险评级】
等级：🔴 高 / 🟡 中 / 🟢 低

理由：
  - 改动范围：{说明}
  - 接口兼容性：{说明}
  - 回滚方式：git revert {预估 commit hash} 或手动还原
  - 验证手段：{curl 命令 或 日志 grep}
```

评级标准：
- **🔴 高**：改了接口签名 / DB schema / 影响所有用户的必经路径 / 回滚困难
- **🟡 中**：改了内部函数逻辑 / 影响部分流程 / 可用日志验证
- **🟢 低**：只加日志 / 修复边缘 case / 改动局限在单函数内 / 一键 revert

---

### Step 5 — 架构一致性检查

读取设计文档，检查修复方案是否与文档一致：

```
【架构一致性检查】
参考文档：对话式交互0613.md

✅ 一致项：
  - {改动点}：符合文档 Section X.X 的设计

⚠️ 偏差项（如有）：
  - {改动点}：与文档 Section X.X 描述不一致
    文档要求：{文档内容}
    实际修复：{修复内容}
    建议：① 按文档改修复方案 / ② 更新文档以反映新设计

❌ 冲突项（如有）：
  - {改动点}：与文档设计矛盾，需用户决策
    冲突描述：{说明}
```

---

### Step 6 — 等待用户确认是否修复

```
─────────────────────────────
以上分析完成。

风险等级：{高/中/低}
架构一致性：{一致 / 有偏差，需确认}

需要我按照建议方案修复吗？
（确认后走 /change 流程：建分支 → 最小化改动 → diff 确认 → commit）
```

**必须等用户确认后才能改代码。**

如果用户确认修复，走 `/change` 流程：
- `git checkout -b fix/{描述}`
- 最小化改动，严格按文档
- 输出 diff 等待确认
- commit

---

## 服务器信息

| 环境 | 地址 | SSH 用户 |
|---|---|---|
| 测试服（默认） | `34.74.255.48` | `liudanmi` |
| 正式服 | `34.74.150.225` | `liudanmi` |

- **SSH Key**：`~/.ssh/google_compute_engine`
- **日志路径**：`~/gemini-audio-service.log`
- **服务目录**：`/opt/gemini-audio-service/`

默认 SSH 到测试服。如果 sessionId 在测试服日志里找不到，再试正式服。

---

## Chat Session 常见错误速查

| 日志关键词 | 含义 | 常见原因 |
|---|---|---|
| `_init_skill_matching failed` | 技能匹配整体失败 | classify_and_score 超时 / DB 连接问题 |
| `skill_tags dropped` | SSE 已断开无法推送 | 正常（iOS 有补偿机制） |
| `strategy_analysis written` 缺失 | 技能写 DB 失败 | unique constraint（未用 UPSERT）|
| `KG timeout` | KG 查询超时 | 不影响主流程，静默跳过 |
| `finalize failed` | 退出后处理失败 | Gemini 调用失败 / DB 写入失败 |
| `scene_image failed` | 生图失败 | Imagen API / synthetic_transcript 为空 |
| `close_chat_session` 缺失 | 用户强退 | 正常，等服务端 cron 2小时后归档 |
| `gemini error` / `429` | Gemini 配额超限 | 当日免费额度已用完 |
| `JSON parse error` | Gemini 返回非法 JSON | prompt 问题 / 模型抖动，重试通常可解决 |

## Review Session 常见错误速查

| 关键词 | 含义 |
|---|---|
| `Gemini API error` / `429` | Gemini 配额超限 |
| `OSS upload failed` | 阿里云 OSS 上传失败 |
| `analyze_audio_from_path timeout` | 音频分析超时 |
| `image_status = failed` | 图片生成失败 |
| `JSON parse error` / `JSONDecodeError` | Gemini 返回非法 JSON |
| `subscription limit` / `429 Monthly` | 订阅次数超限 |
| `speaker_mapping` 相关 | 声纹匹配异常 |
