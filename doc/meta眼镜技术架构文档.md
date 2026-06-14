# Meta 眼镜实时模式技术架构文档

> 版本：v0.5（主链路已跑通）
> 更新时间：2026-06-09
> 状态：SSE 实时推送 + 技能分析链路已验证，图片生成修复中

---

## 模块全景与接口索引

> 快速定位：每个模块的接口清单、新增/复用状态、文档章节。

### 服务端模块

| 模块 | 接口 | 新增/复用 | 实现状态 |
|---|---|---|---|
| **A. Session 管理** | `POST /api/v1/live/sessions` | 🆕 新增 | ✅ 已实现 |
| | `POST /api/v1/live/sessions/{id}/end` | 🆕 新增 | ✅ 已实现 |
| | `GET /api/v1/live/sessions/{id}/summary-status` | 🆕 新增 | ✅ 已实现 |
| **B. 音频代理 WebSocket** | `WS /api/v1/live/sessions/{id}/audio-stream?token=JWT` | 🆕 新增 | ✅ 已实现 |
| | GeminiProxySession（原子切换 + 15 分钟续期）| 🆕 新增 | ✅ 已实现 |
| **C. Turn 实时处理** | `POST /api/v1/live/sessions/{id}/turn`（兜底）| 🆕 新端点 | ✅ 已实现 |
| | 技能匹配 `match_skills()` | ✅ 复用线上 | ✅ 已实现（SDK 兼容修复见下方）|
| | Gemini 快速建议 prompt | ✅ 复用线上 | ✅ 已实现 |
| | 3B 异步触发（per-turn LLM 检测）| 🆕 新增 | ✅ 已实现 |
| **D. SSE 推送** | `GET /api/v1/live/sessions/{id}/events?token=JWT` | 🆕 新增 | ✅ 已实现 |
| | live_events 表 + Last-Event-ID 重放 | 🆕 新增 | ✅ 已实现 |
| **E. Segment 管理** | 自动分段检测（沉默 / 换人 / 背景音）| 🆕 新增 | ✅ 已实现 |
| | 每 10 turns 重写 running_context（Task A）| 🆕 新增 | ✅ 已实现 |
| **F. Speaker 确认** | `POST /api/v1/live/sessions/{id}/confirm-speaker` | 🆕 新增 | ⬜ 待实现 |
| | `POST /api/v1/live/sessions/{id}/update-speaker` | 🆕 新增 | ⬜ 待实现 |
| | `POST /api/v1/live/sessions/{id}/voiceprint-intent` | 🆕 新增 | ⬜ 待实现 |
| | `POST /api/v1/profiles`（新建档案）| ✅ 复用线上 | — |
| **G. 录音结束后处理** | Task 1 Summary 汇总（Segment 聚合）| 🆕 新聚合逻辑 | ⬜ 待实现 |
| | Task 2 图片生成 `generate_scene_images()` | ✅ 复用，新增跨 Segment 编排 | ⬜ 待实现 |
| | Task 3 技能按 Segment 分类整理 | 🆕 新分组逻辑 | ⬜ 待实现 |
| | 任务持久化（live_summary_tasks + heartbeat）| 🆕 新增 | ⬜ 待实现 |

### iOS 客户端模块

| 模块 | 内容 | 新增/复用 | 实现状态 |
|---|---|---|---|
| **A. 直播会话控制器** | LiveSessionManager（WS 连接 + 麦克风 PCM 流）| 🆕 新增 | ✅ 已实现 |
| **B. SSE 监听** | LiveSSEClient（事件解析 + 断线重连）| 🆕 新增 | ✅ 已实现（缓冲修复见下方）|
| **C. 实时 UI** | 浮动建议气泡、实时技能显示、Speaker 标签 | 🆕 新增 | ✅ 已实现 |
| **D. 停止录音弹窗** | 二次确认 → Step 2 Speaker 确认 → 生成中弹窗 | 🆕 新增 | ✅ 已实现 |
| **E. 卡片状态** | 处理中 → 可点击（封面图 + 轮询）| ✅ 复用线上 loading UI，扩展轮询 | ✅ 已实现 |
| **F. Detail 详情页** | 进入后与线上完全一致 | ✅ 完全复用 | — |

### 编码顺序

```
Step 1  DB Schema 变更（所有模块依赖）          ← 当前
Step 2  服务端 A - Session 管理
Step 3  服务端 B - WS 音频代理 + GeminiProxySession
Step 4  服务端 D - SSE Push
Step 5  iOS A + B - WS 发流 + SSE 接收（跑通主链路）
Step 6  服务端 C - Turn 实时处理（技能 + 建议）
Step 7  服务端 E - Segment 管理
Step 8  服务端 F - Speaker 确认
Step 9  服务端 G - 结束后处理
Step 10 iOS C + D - 实时 UI + 停止弹窗
Step 11 iOS E - 卡片状态扩展
```

---

## 实现记录（已上线修复）

### Fix-1：iOS SSE 缓冲问题（2026-06-09）

**问题**：`URLSession.bytes(for:)` + `AsyncBytes.lines` 在 HTTP/HTTPS 下存在内部缓冲，SSE 事件数据堆积到连接关闭后才一次性交付，导致 Hints/Skills/Segments 全部为 0。

**验证方式**：Debug Panel 新增 `SSE Recv` 计数器，在 `parseSSELines` 入口埋点，确认 `SSE Recv=0` 即字节未实时到达。

**解决方案**：`LiveSSEClient.swift` 替换为 `URLSessionDataDelegate` 实现。

核心原理：`didReceive(data:)` 每收到一块数据立即回调，无任何内部缓冲，通过 `AsyncStream<SSEMessage>` 桥接到 `async/await` 消费端。

```swift
// 新架构（LiveSSEClient.swift）
private final class SSEDelegate: NSObject, URLSessionDataDelegate {
    // didReceive(data:) 立即 yield 到 AsyncStream，零缓冲
}

private func makeSSEStream(request: URLRequest) -> AsyncStream<SSEMessage> {
    AsyncStream { continuation in
        let delegate = SSEDelegate(continuation: continuation)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        // onTermination 时 task.cancel() + session.invalidateAndCancel()
    }
}
```

**验证结果**：`SSE Recv=23, Hints=6, Skills=2, Segments=1`，链路完全跑通。

**关联配置**：
- `AppConfig.sseBaseURL`（测试环境）：`https://test-api.yohomie.art`（Cloudflare HTTPS）
- nginx `location /`：已加 `add_header X-Accel-Buffering "no" always;`

---

### Fix-2：skills/router.py SDK 不兼容（2026-06-09）

**问题**：`skills/router.py` 使用老版 `import google.generativeai as genai`，新版 `google-genai 2.x` 中 `genai.GenerativeModel(...)` 返回 `Client` 对象，而非 `GenerativeModel`，导致 `model.generate_content(prompt)` 抛出 `AttributeError`。

**影响链**：`classify_and_score` 失败 → 策略分析流水线中断 → `StrategyAnalysis` 未写入 DB → 图片生成成功但无法关联 → 客户端看不到图片。

**修复**（服务端 `/opt/gemini-audio-service/skills/router.py`）：

```python
# 改前
import google.generativeai as genai
model = genai.GenerativeModel(GEMINI_FLASH_MODEL)
response = model.generate_content(prompt)

# 改后
from google import genai
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
model_name = model if isinstance(model, str) else GEMINI_FLASH_MODEL
_client = genai.Client(api_key=GEMINI_API_KEY)
response = _client.models.generate_content(model=model_name, contents=prompt)
```

**影响范围**：仅 `classify_and_score` 和 `classify_scene` 两个函数，其他模块不受影响。修复前这两个函数 100% 报错，无正常工作路径被破坏。

---

## 一、整体定位

### 两种模式并存，完全隔离

```
用户打开 App
     │
     ├─ 检测到 Meta 眼镜在线（iOS 蓝牙已配对 + HFP 设备在线）
     │       └─ 进入【实时模式 Live Mode】← 新分支
     │
     └─ 未检测到眼镜 / 用户手动选择录音
             └─ 进入【录音复盘模式 Review Mode】← 现有主分支，不改动
```

**核心原则：**
- 现有录音复盘流程零改动
- 新增代码全部在新文件中
- 共享后端的 Gemini 分析能力，但通过新入口进入
- 两种模式产生的 session 在历史列表中视觉区分

---

## 二、iOS 连接方案：HFP 标准蓝牙（App Store 可上架）

### 方案选择与原因

| 方案 | App Store 上架 | 连接方式 | 音频质量 | 状态 |
|---|---|---|---|---|
| **HFP 标准蓝牙（当前采用）** | ✅ 完全合规 | 直连，不需要 Meta AI App 常驻 | 单声道 16kHz | **已确定** |
| DAT SDK（备选/未来） | ❌ 当前被苹果拒绝（MFi 未授权） | 需要 Meta AI App 作为中间层 | 5麦阵列 Float32 | 等待 Meta+苹果谈妥 |

**选择 HFP 的核心原因：功能必须上架 App Store。**

DAT SDK 因使用 ExternalAccessory 框架，苹果审核要求 Meta 提供 MFi Product Plan ID，Meta 目前尚未提供，所有开发者提交均被拒。HFP 是标准 iOS 蓝牙音频协议，与眼镜品牌无关，审核流程与普通录音 App 完全一致。

---

### 三个核心结论

**结论 1：不需要 Meta AI App 常驻后台**

```
DAT SDK 连接方式：眼镜 ↔ Meta AI App（必须运行）↔ Chatton
HFP 连接方式：   眼镜 ↔ iOS 蓝牙系统 ↔ Chatton（直接）
```

用户首次配对时需要打开 Meta AI App（硬件必须步骤，无法绕过）。配对完成后，Chatton 直接连眼镜，Meta AI App 无需打开。Chatton 是主角，眼镜是外设。

**结论 2：不需要唤醒词，直接连接**

HFP 蓝牙配对后，iOS 将眼镜识别为标准蓝牙耳机（portType = `.bluetoothHFP`）。用户在 Chatton 里点击按钮即可开始录音，无需 "Hey Meta"，无需任何 Meta 授权。

**结论 3：App Store 审核只需标准隐私权限**

```
Info.plist 必须声明（与普通录音 App 完全相同）：
  NSMicrophoneUsageDescription  = "用于实时录制对话，提供场景建议"
  NSBluetoothAlwaysUsageDescription = "用于连接蓝牙设备采集音频"

PrivacyInfo.xcprivacy（苹果 2024年5月起强制要求）：
  声明麦克风数据用途
```

无需 Meta 审核，无需苹果额外授权，无 MFi 限制。

---

### 音频采集路径

Ray-Ban 眼镜以标准蓝牙 HFP 设备接入 iOS，物理上仍戴在用户脸上，麦克风距用户嘴部约 5cm：

```
HFP 蓝牙音频流（单声道，最高 16kHz，wSBC 编解码）
    │
    ▼（AVAudioSession，已内置软件降噪）
Int16 PCM 音频流
    │
    ▼（重采样，若需要）
16kHz mono，约 100ms 一个 chunk
    │
    ├─ → Gemini Live WebSocket（管线 A，实时转录 + Diarization）
    └─ → [VAD 过滤] → 声纹比对队列（管线 B，身份识别）
```

**Gemini Live 返回（含 Speaker Diarization，单声道音频同样支持）：**

```json
{ "speaker": "Speaker_0", "text": "你觉得这个方案怎么样？", "is_user": true  },
{ "speaker": "Speaker_1", "text": "我觉得预算有点高",          "is_user": false }
```

> Gemini Live 的 Speaker Diarization 基于声纹特征，不依赖多麦克风。单声道是其标准输入格式，完全兼容。

---

### 用户声音的自然区分优势

HFP 单声道不代表说话人难以区分。眼镜戴在脸上，物理距离决定了信噪比：

```
用户嘴部距麦克风：约 5cm  → 相对音量 100%（基准）
对方说话距离：   约 1m   → 相对音量 ~0.25%（衰减约 26dB）
```

用户自己的声音天然最响，Gemini Diarization 极易将其标为 Speaker_0（is_user=true）。

---

### iOS 开发环境要求

| 要求 | 版本/说明 |
|---|---|
| iOS 最低版本 | 15.0+（HFP 蓝牙音频，更早版本也支持） |
| Xcode | 14.0+ |
| 无需引入任何第三方 SDK | 纯 iOS AVAudioSession + AVAudioEngine |
| 所需权限 | 麦克风、蓝牙 |
| AVAudioSession 模式 | `.voiceChat`（启用内置软件降噪） |
| AVAudioSession 选项 | `.allowBluetooth`（启用 HFP 输入） |

---

### DAT SDK 保留为未来升级路径

当前阶段不引入 DAT SDK，但架构层面预留兼容：
- MetaSDKManager 接口设计为音频数据提供者，具体来源（HFP / DAT SDK）对上层透明
- 待 Meta 和苹果完成 MFi 授权流程后，可在 MetaSDKManager 内部切换实现，LiveSessionViewModel 及后端无需改动
- 参考实现：VisionClaw（https://github.com/Intent-Lab/VisionClaw），DAT SDK + Gemini Live 全链路已验证可行

---

## 三、数据流总览

```
┌─────────────────────────────────────────────────────────┐
│  Ray-Ban Meta 眼镜                                       │
│  单声道麦克风 · HFP 16kHz PCM · 无需唤醒词              │
└────────────────────────┬────────────────────────────────┘
                         │ HFP Bluetooth
                         ▼
┌─────────────────────────────────────────────────────────┐
│  iPhone — Chatton App                                    │
│                                                          │
│  MetaSDKManager（AVAudioSession HFP + AVAudioEngine）    │
│   ├─ AVAudioSession：.voiceChat + .allowBluetooth       │
│   ├─ AVAudioEngine：Int16 PCM，100ms chunks             │
│   └─ 输出 → 后端 WebSocket（上行音频）                  │
│                                                          │
│  LiveSessionViewModel                                    │
│   ├─ 订阅 SSE：接收实时建议 / 漫画就绪事件              │
│   └─ 订阅 WS 下行：接收转录文字用于展示字幕             │
└────────┬──────────────────────────┬─────────────────────┘
         │                          │
  WS 上行（PCM 音频）          SSE 下行（分析结果）
  wss://.../audio-stream        GET .../events
         │                          │
         ▼                          │
┌─────────────────────────────────────────────────────────┐
│  后端 FastAPI                                            │
│                                                          │
│  WS Handler（S-1 核心链路）                              │
│   ├─ 接收 iOS PCM → 透传 Gemini Live WebSocket          │
│   ├─ 接收 Gemini 转录结果（含 Speaker_X 标签）          │
│   ├─ 写入 live_turns（turn_index 后端分配，幂等）        │
│   ├─ 下行推送转录文字给 iOS（字幕展示）                  │
│   ├─ 内部触发快速路径 / 异步路径分析                    │
│   └─ 管理 Gemini Live 续期（15min 到期自动换 token）    │
│                                                          │
│  live_session_service.py                                 │
│   ├─ 快速路径：轻量 Gemini 调用 → 1条实时建议 → SSE    │
│   └─ 异步路径：复用现有策略生成 → skill_cards + 漫画   │
│                                                          │
│  复用现有逻辑（不改动）：                               │
│   classify_scene() / match_skills_v2()                  │
│   _generate_strategies_core() / generate_scene_images() │
└─────────────────────────────────────────────────────────┘
                          │
                SSE push（实时建议 / 漫画就绪）
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│  LiveSessionView（新 UI）                                │
│   ├─ 实时建议卡（快速路径，每 3 turn 刷新）             │
│   └─ 漫画区（异步浮现，结束后逐张加载）                 │
└─────────────────────────────────────────────────────────┘

关键变化（S-1）：
  ❌ 旧图：iOS → Gemini Live 直连（与 C-1 决策矛盾）
  ✅ 新图：iOS → 后端 WS → Gemini Live（后端代理，C-1 确认方案）
  ❌ 旧图：iOS POST /turn 驱动分析
  ✅ 新图：后端 WS Handler 收到转录后直接内部写 turn + 触发分析
```

---

## 四、后端服务设计

### 4.1 新增文件（不改动现有文件）

```
~/（服务器根目录）
├── main.py                      ← 不改动
├── models.py                    ← 只加1个字段（session_type）
├── live_session_service.py      ← 全新文件，所有 live 逻辑
└── api/
    └── live.py                  ← 全新路由文件
```

### 4.2 新增 API 端点

所有新端点前缀：`/api/v1/live/`

#### POST /api/v1/live/sessions
创建新 live session，返回 session_id 和 SSE 订阅 URL。

```json
// 请求
{ "title": "与张总的会议（可选）" }

// 响应
{
  "session_id": "uuid",
  "sse_url": "/api/v1/live/sessions/{id}/events",
  "created_at": "2026-06-06T..."
}
```

#### WS /api/v1/live/sessions/{id}/audio-stream ⭐ 音频代理链路（核心，S-1 补充）

iOS 与后端建立 WebSocket 长连接，后端同时持有 Gemini Live WebSocket，形成双向音频代理管道。**这是 Live Mode 最核心的链路，所有其他端点依赖此连接建立后才有意义。**

**连接建立（JWT 通过 query param 传入，WebSocket 不支持自定义 Header）：**

```
wss://api.yohomie.art/api/v1/live/sessions/{session_id}/audio-stream?token={JWT}

// 握手成功，后端返回 JSON 文本帧
{
  "type": "ready",
  "gemini_session_id": "...",
  "session_resumption_token": "...",   // 存 DB，用于 15min 到期续期
  "turn_index_offset": 0               // 断线重连时告知 iOS 从哪个 turn 继续
}
```

**上行：iOS → 后端（二进制帧，PCM 音频）**

```
格式：原始 PCM 二进制数据（不做 base64，减少开销）
编码：Int16，16kHz，单声道
块大小：约 100ms ≈ 3200 字节/块
后端处理：直接透传给 Gemini Live WebSocket，不做额外处理
```

**下行：后端 → iOS（JSON 文本帧，转录结果 + 控制消息）**

```json
// 每个 turn 转录完成（Gemini Live → 后端 → iOS）
{
  "type": "transcript",
  "speaker_label": "Speaker_1",    // Gemini Diarization 原始标签，iOS 显示字幕用
  "text": "我觉得预算有点高",
  "is_user": false,
  "turn_index": 5,                 // 后端分配，全局单调递增，保证顺序一致
  "timestamp_ms": 1234567890
}

// Gemini Live 会话即将到期（到期前 60s 推送）
{ "type": "session_warning", "expires_in_seconds": 60 }

// 后端已自动续期完成（iOS 无感知，音频流不中断）
{ "type": "session_renewed", "new_gemini_session_id": "..." }

// 后端无法恢复连接（3次重连失败后推送）
{ "type": "error", "code": "gemini_unavailable", "message": "建议结束本次对话" }

// 心跳（每 15s，与 SSE ping 独立）
{ "type": "ping" }
```

**Gemini Live 会话生命周期管理（后端负责，iOS 无感知）：**

```
Session 创建时：
  后端向 Gemini Live 发起 WebSocket 连接
  保存 session_resumption_token → live_sessions.gemini_token（DB 持久化）

Gemini Live 15 分钟到期前 60s：
  Gemini 推送到期预警 → 后端检测到
  → 向 iOS 推送 session_warning（可选，用于 debug）
  → 后端用 session_resumption_token 发起新 Gemini Live 会话
  → 新会话建立 → 更新 DB token → 向 iOS 推送 session_renewed
  → 音频流切换到新 Gemini 会话，iOS 无任何感知，对话不中断

Gemini Live 意外断线：
  后端自动重连（最多 3 次，退避 1s/2s/4s）
  重连成功 → 携带 session_resumption_token 恢复上下文，继续代理
  重连失败 → 向 iOS 推送 error，iOS 提示用户
```

**iOS 断线重连（网络切换 / 进后台）：**

```
iOS WS 重连：携带相同 session_id + JWT
后端查 DB 恢复 Gemini Live 连接状态
握手响应中 turn_index_offset = 上次处理到的最后 turn_index
iOS 从 turn_index_offset 继续，本地 transcript 不丢失
```

**turns 写入分工（与 /turn 端点的关系）：**

```
Gemini Live 转录结果到达后端 WS Handler：
  ① 后端直接写入 live_turns 表（turn_index 由后端分配，顺序可保证）
  ② 同时判断触发快速路径 / 异步路径分析
  ③ 转录结果下行推送给 iOS（iOS 只展示字幕，不需要再 POST /turn）

结论：后端 WS Handler 承担 turn 存储职责，/turn HTTP 端点仅作为
      断线恢复时 iOS 补报离线期间 turns 的降级路径（非常态）
```

---

#### POST /api/v1/live/sessions/{id}/turn（降级补报接口，S-2 更新）

> 正常链路下 turn 由 WS Handler 写入，此端点仅用于 WS 断线重连后 iOS 补报离线期间缺失的 turn。

```json
// 请求（S-2：新增 speaker_label / segment_id 字段）
{
  "speaker": "user" | "other",
  "speaker_label": "Speaker_1",    // ← 新增：Gemini Diarization 原始标签
  "text": "你觉得这个方案怎么样？",
  "timestamp_ms": 1234567890,
  "turn_index": 5,                 // 必填：后端用于幂等去重（UNIQUE session_id+turn_index）
  "segment_id": "uuid | null"      // ← 新增：iOS 告知所属 Segment（null 则后端自动归入活跃段）
}

// 响应（同步，< 500ms）
{
  "turn_saved": true,
  "duplicated": false,             // turn_index 已存在时为 true，幂等处理不报错
  "analysis_triggered": false
}
```

**speaker_label 和 segment_id 的用途：**

| 字段 | 后端用途 |
|---|---|
| `speaker_label` | 写入 `live_turns.speaker_label`；驱动 SpeakerMapping 更新；检测说话人集合变化（Segment 边界信号）；3B trigger 按 speaker 分组 |
| `segment_id` | 确定 turn 归属的 Segment；null 时后端归入 `sessions.active_segment_id` |

**幂等保护（同一 turn_index 重复提交）：**

```sql
-- live_turns 表唯一约束（S-2 补充的 DB 变更）
ALTER TABLE live_turns
ADD CONSTRAINT uq_live_turns_session_turn
    UNIQUE (session_id, turn_index);

-- 后端 upsert（重复提交不报错，只更新 updated_at）
INSERT INTO live_turns (...) VALUES (...)
ON CONFLICT (session_id, turn_index) DO UPDATE
    SET updated_at = NOW();
```

**正常链路下的触发规则（WS Handler 内部执行）：**
- 累积满 3 个 turn → 触发快速分析
- 距上次分析超过 20s → 触发快速分析
- 累积满 10 个 turn → 额外触发异步完整分析

#### GET /api/v1/live/sessions/{id}/events（SSE，H-1 更新：支持断连 replay）

iOS 建立长连接，后端主动推送事件。**每个事件写入 `live_events` 表持久化，断连重连时按 `Last-Event-ID` 补发。**

**SSE 响应格式（新增 `id:` 字段，符合 SSE 规范）：**

```
// 快速建议（快速路径，1-2s 内）
id: 1042
data: {"type":"suggestion","text":"对方在防御，避免追问，换个角度切入","emotion_tag":"⚠️ 防御情绪","skill_hint":"active_listening","turn_index":5}

// 漫画+策略就绪（异步路径，10-30s 后）
id: 1078
data: {"type":"analysis_ready","skill_cards":[...],"snapshot_index":1}

// 漫画图片就绪（逐张推送）
id: 1095
data: {"type":"image_ready","image_url":"https://r2.../...","scene_index":3,"batch_index":2,"total_in_batch":2}

// 心跳（每 15s，不写 live_events，不参与 replay）
: ping
```

> `id:` 为 `live_events.id`（全局自增，跨会话唯一）。iOS 的 SSE 客户端自动记录 `Last-Event-ID`，重连时通过 Header 上报。

**断连重连 replay 流程（H-1 核心）：**

```
iOS SSE 断连（进后台 / 网络切换）
        ↓
iOS 重连：GET /events，携带 Header：Last-Event-ID: 1078
        ↓
后端查询：
  SELECT * FROM live_events
  WHERE session_id = :sid
    AND id > 1078               -- 只补发断连期间未收到的事件
    AND event_type != 'ping'    -- ping 不补发（无意义）
    AND created_at > NOW() - INTERVAL '10 minutes'  -- 超过10分钟的事件不补发（已过时）
  ORDER BY id ASC
        ↓
逐条以 SSE 格式下发（先补历史，再接实时推送）
```

**不补发的事件类型：**

| 事件 | 是否补发 | 原因 |
|---|---|---|
| `suggestion` | ✅ 补发 | 用户可能错过实时建议 |
| `analysis_ready` | ✅ 补发 | 漫画脚本就绪通知不能丢 |
| `image_ready` | ✅ 补发 | 图片就绪通知不能丢 |
| `ping` | ❌ 不补发 | 无实际内容 |
| 10分钟前的事件 | ❌ 不补发 | 已过时，补了也没用 |

#### POST /api/v1/live/sessions/{id}/end
结束 live session，保存完整 transcript，返回汇总。

```json
{
  "session_id": "uuid",
  "session_type": "live",
  "total_turns": 28,
  "duration_seconds": 324,
  "has_analysis": true,
  "reanalyze_available": true,
  "total_panels": 5,          // 已触发生成的场景总数
  "completed_panels": 3,      // 已生成完毕的图片数
  "pending_panels": 2         // 仍在后台生成的图片数（>0 时 iOS 需轮询）
}
```

> 对话结束时若 `pending_panels > 0`，后台图片生成任务继续运行不中断。
> iOS 进入复盘页后通过 `GET /api/v1/live/sessions/{id}/panel-status` 轮询（每 5s），直至 `pending_panels = 0`。

#### POST /api/v1/live/sessions/{id}/reanalyze
用 live session 的文本记录重跑完整复盘分析（走现有策略生成逻辑）。

```json
// 响应（立即返回，异步执行）
{
  "status": "processing",
  "poll_url": "/api/v1/tasks/sessions/{id}/status"  // 复用现有轮询接口
}
```

### 4.3 两条路径的分工

**快速路径（直连 Gemini，iOS → 后端 → Gemini）**

```
触发条件：每 3 个对话 turn 或距上次 20s
输入：最近 5-8 个对话 turn
Gemini 任务：轻量 prompt，只输出 1 条建议 + 情绪标签
延迟目标：< 2 秒
不生成图片，不存 DB
```

**异步路径（走现有策略流程，只生成脚本，不生成图片）**

```
触发条件：每累积 10 个 turn（Turn 10, 20, 30...）
输入：本批次新增的 turn 区间
      + 已有 character_desc（保持人物外貌跨批次一致）
后端任务：classify_scene → match_skills → 并行策略执行
          → 生成新场景脚本（visual[]）→ 存入 DB
          ⚠️ 不调用 Imagen，不生成图片（统一在对话结束后生成）
延迟目标：脚本 8-15s
结果存 DB（追加，不覆盖），脚本就绪后 SSE 推送 analysis_ready
```

**漫画脚本追加逻辑（PanelTracker）：**

```
每次触发时检查 PanelTracker.illustrated_range：
  Turn 10 → 输入 transcript[0-9]，生成场景 1-3 脚本，offset=0
  Turn 20 → 输入 transcript[10-19]，生成场景 4-5 脚本，offset=3
  Turn 30 → 输入 transcript[20-29]，生成场景 6-7 脚本，offset=5
  → 场景全局编号连续递增，脚本存 DB，图片在结束时统一生成
```

**三条路径对比：**

| | 快速路径 | 异步路径（Live中） | 结束总结路径 |
|---|---|---|---|
| 触发时机 | 每 3 turn / 20s | 每 10 turn | 用户点停止后 |
| 输入 | 最近 5-8 turns | 本批次新增 turns | 全量 transcript |
| 输出 | 1条文字建议 | visual[] 脚本 + skill_cards | 概要 + 标题 + 图片 |
| 是否调 Imagen | 否 | **否（改动）** | **是（统一生成）** |
| 是否存 DB | 否 | 是（脚本） | 是（图片+概要） |

### 4.4 关键设计：跳过音频转录步骤

现有流程：`音频文件 → analyze_audio_from_path() → transcript → 策略生成`

Live 模式流程：`Gemini Live 已实时转录 transcript → 直接策略生成`

新增 `analyze_text_transcript(transcript, session_id)` 函数：
- 接受已有文本 transcript（格式与 `analyze_audio_from_path` 输出一致）
- 直接从策略生成阶段开始，不调用 Gemini 文件 API
- 复用 `classify_scene()` / `match_skills_v2()` / `generate_scene_images()` 全部现有逻辑

### 4.5 数据库变更（最小化，向后兼容）

**sessions 表新增字段：**

```sql
ALTER TABLE sessions
ADD COLUMN session_type VARCHAR(20) DEFAULT 'recording';
-- 'recording'（现有）| 'live'（新）

ADD COLUMN live_source VARCHAR(20) DEFAULT NULL;
-- NULL（普通录音）| 'ray_ban'（眼镜输入）

-- S-1 新增：Gemini Live 会话续期 token（后端持久化，用于 15min 到期自动续期）
ADD COLUMN gemini_token         TEXT          DEFAULT NULL,
ADD COLUMN gemini_token_updated TIMESTAMPTZ   DEFAULT NULL;
-- WS 连接建立时写入，每次续期后更新；服务重启可凭此 token 恢复 Gemini Live 会话
```

**新增表：live_turns（S-2 更新：补充 speaker_label / segment_id / 幂等约束）**

```sql
CREATE TABLE live_turns (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id       UUID REFERENCES sessions(id) ON DELETE CASCADE,
    turn_index       INTEGER NOT NULL,
    speaker          VARCHAR(20) NOT NULL,    -- 'user' | 'other'
    speaker_label    VARCHAR(20) DEFAULT NULL, -- S-2 新增：Gemini 原始标签 'Speaker_0'/'Speaker_1'
    text             TEXT NOT NULL,
    timestamp_ms     BIGINT,
    segment_id       UUID REFERENCES live_segments(id) DEFAULT NULL,  -- S-2 新增：所属 Segment
    created_at       TIMESTAMPTZ DEFAULT NOW(),

    -- S-2 新增：幂等约束，防止 WS 重传导致 turn 重复写入
    CONSTRAINT uq_live_turns_session_turn UNIQUE (session_id, turn_index)
);
CREATE INDEX idx_live_turns_session ON live_turns(session_id, turn_index);
```

> **speaker_label 的作用（S-2）：**
> - SpeakerIdentificationService 读取此字段识别说话人身份
> - Segment 边界检测：后端对比相邻 turns 的 speaker_label 集合，发生变化时触发新建 Segment
> - 3B 触发检测：按 speaker_label 分组，只对有意义的发言 turn 触发

live session 结束时，live_turns 合并成完整 transcript 写入 `analysis_results`，之后复盘分析与普通 session 完全相同。

**新增表：live_events（H-1：SSE 事件持久化，支持断连 replay）**

```sql
CREATE TABLE live_events (
    id          BIGSERIAL PRIMARY KEY,       -- 全局自增，用作 SSE id: 字段
    session_id  UUID REFERENCES sessions(id) ON DELETE CASCADE,
    event_type  VARCHAR(50) NOT NULL,        -- 'suggestion' | 'analysis_ready' | 'image_ready'
    payload     JSONB NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_live_events_session ON live_events(session_id, id);
-- 清理策略：session 结束后 2 小时自动删除（定时任务或 pg_partman）
```

**新增表：live_panel_batches（漫画脚本批次追踪，H-2 新增心跳字段）**

```sql
CREATE TABLE live_panel_batches (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      UUID REFERENCES sessions(id) ON DELETE CASCADE,
    batch_index     INTEGER NOT NULL,         -- 第几批，从 1 开始
    turn_start      INTEGER NOT NULL,         -- 本批次覆盖的 turn 起始（含）
    turn_end        INTEGER NOT NULL,         -- 本批次覆盖的 turn 结束（含）
    panel_count     INTEGER NOT NULL,         -- 本批次脚本场景数
    panel_offset    INTEGER NOT NULL,         -- 全局场景编号起始
    visual_scripts  JSONB DEFAULT NULL,       -- visual[] 脚本数据（含 image_prompt）
    character_desc  JSONB DEFAULT NULL,       -- 人物外貌描述，后续批次复用
    script_status   VARCHAR(20) DEFAULT 'pending',
    -- 'pending' | 'script_ready' | 'images_generating' | 'completed' | 'failed'

    -- H-2 新增：任务追踪字段（用于重启恢复）
    task_started_at TIMESTAMPTZ DEFAULT NULL, -- 任务开始时间
    task_heartbeat  TIMESTAMPTZ DEFAULT NULL, -- 最后心跳时间（每 30s 更新）
    retry_count     INTEGER DEFAULT 0,        -- 已重试次数（上限 3）
    error_msg       TEXT DEFAULT NULL,        -- 失败原因

    created_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_live_batches_session ON live_panel_batches(session_id, batch_index);
-- 快速找出卡住的任务（服务启动恢复用）
CREATE INDEX idx_live_batches_stuck ON live_panel_batches(script_status, task_heartbeat)
    WHERE script_status = 'images_generating';
```

**新增表：live_summary_tasks（H-2：Step 3a 文字总结任务持久化）**

```sql
CREATE TABLE live_summary_tasks (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  UUID REFERENCES sessions(id) ON DELETE CASCADE,
    status      VARCHAR(20) DEFAULT 'pending',
    -- 'pending' | 'processing' | 'completed' | 'failed'
    task_started_at TIMESTAMPTZ DEFAULT NULL,
    task_heartbeat  TIMESTAMPTZ DEFAULT NULL, -- 每 30s 更新
    retry_count     INTEGER DEFAULT 0,
    error_msg       TEXT DEFAULT NULL,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_summary_task_session UNIQUE (session_id)  -- 每个 session 只有一个总结任务
);
CREATE INDEX idx_summary_tasks_stuck ON live_summary_tasks(status, task_heartbeat)
    WHERE status = 'processing';
```

**skill_cards 表新增字段（区分增量/全量来源）：**

```sql
ALTER TABLE skill_cards
ADD COLUMN analysis_type VARCHAR(20) DEFAULT 'incremental';
-- 'incremental'（Live 期间增量生成）| 'full'（结束后全量生成）
```

**profiles 表新增声纹状态字段：**

```sql
ALTER TABLE profiles
ADD COLUMN voiceprint        JSONB    DEFAULT NULL,
-- 声纹特征向量（实现后填入）
ADD COLUMN voiceprint_status VARCHAR(20) DEFAULT 'none';
-- 'none'（未录入）| 'pending'（用户已同意录入，等待提取）| 'ready'（已录入可用）
```

**新增表：live_speaker_mappings（M-2：SpeakerMapping 持久化）**

```sql
CREATE TABLE live_speaker_mappings (
    session_id    UUID        REFERENCES sessions(id) ON DELETE CASCADE,
    speaker_label VARCHAR(20) NOT NULL,       -- Gemini 标签：'Speaker_0' / 'Speaker_1'
    profile_id    UUID        REFERENCES profiles(id) DEFAULT NULL,
    name          VARCHAR(100) DEFAULT NULL,  -- 冗余存储，避免 JOIN，查询快
    confidence    FLOAT        DEFAULT NULL,  -- 0-1，识别置信度
    method        VARCHAR(20)  DEFAULT NULL,  -- 'voiceprint'|'rule'|'llm'|'user_confirmed'
    updated_at    TIMESTAMPTZ  DEFAULT NOW(),
    PRIMARY KEY (session_id, speaker_label)   -- 同一 session + 同一 label 只有一行，upsert 友好
);
CREATE INDEX idx_speaker_mappings_session ON live_speaker_mappings(session_id);
```

**新增 API：GET /api/v1/live/sessions/{id}/panel-status**

进入复盘页后 iOS 轮询图片生成进度：

```json
{
  "total_panels": 5,
  "completed_panels": 3,
  "pending_panels": 2,
  "panels": [
    { "scene_index": 0, "image_url": "https://...", "status": "completed" },
    { "scene_index": 1, "image_url": "https://...", "status": "completed" },
    { "scene_index": 2, "image_url": "https://...", "status": "completed" },
    { "scene_index": 3, "image_url": null,          "status": "generating" },
    { "scene_index": 4, "image_url": null,          "status": "generating" }
  ]
}
```

---

### 4.6 漫画生成完整时序（改：图片统一在结束后生成）

#### Live 对话中（只生成脚本，不调 Imagen）

```
Turn 1-9：仅快速路径（文字建议），无脚本，无图片

Turn 10 → 异步路径 Batch #1 触发
  T+0s   classify_scene(transcript[0-9])
  T+3s   match_skills_v2()
  T+8s   strategy 并行执行 →
         visual[场景1,场景2,场景3] 脚本生成完成（含 image_prompt）
         character_desc 提取（人物外貌描述）
         ⚠️ 不调 Imagen，脚本存入 live_panel_batches.visual_scripts
  T+8s   SSE 推送 analysis_ready（含 skill_cards 文字内容，无图片）

Turn 11-19：对话继续，快速路径文字建议照常，界面无图片

Turn 20 → 异步路径 Batch #2 触发
  T+8s   visual[场景4,场景5] 脚本生成完成
         携带 Batch #1 的 character_desc 保持人物一致
         存入 live_panel_batches，script_status = 'script_ready'
  → 同上，不调 Imagen

... 对话继续，每 10 turn 生成一批脚本 ...
```

#### 结束后（统一批量生成图片）

```
用户点停止 → 完成 Step 1/2（确认 + 档案补全）→ 跳转复盘页
  ↓（后台同时触发）

summarize_and_generate()：

  Step A：补全尾部 turn 的脚本（如有）
    检查 PanelTracker.illustrated_range
    若 transcript 末尾有未覆盖的 turn（不足 10 turn 的尾部）：
      → 对尾部 turn 运行 classify_scene + strategy 生成脚本
      → 若整个 session < 10 turn：对全量 transcript 生成脚本
      → 追加到 live_panel_batches

  Step B：文字总结 summarize_live_session(full_transcript)
    → 1次 Gemini 调用
    → 输出：card_title（标题）+ session_summary（概要）
    → 写入 sessions.card_title，sessions.summary
    → 历史列表下次 fetch 时展示新标题

  Step C：统一图片生成（Imagen 批量调用）
    收集所有 live_panel_batches.visual_scripts 的 image_prompt
    → 批量调用 scene_image_generator（复用现有逻辑）
    → 图片逐张写入 R2，更新 DB
    → iOS 轮询 panel-status（每 5s）→ 图片逐张浮现在复盘页
```

#### 人物一致性机制（跨批次）

```
Batch #1 策略 prompt 额外要求：
  "同时输出每个人物的外貌描述（JSON），供后续批次保持视觉一致"

Batch #1 输出（存入 live_panel_batches.character_desc）：
  {
    "user": "30岁男性，黑色西装，短发，眼镜",
    "张总": "55岁男性，灰色西装，花白头发，方脸"
  }

Batch #2+ 的 prompt 携带 character_desc：
  "保持人物外貌：用户（...）张总（...）
   为以下新对话生成 2-3 个新场景（接续前N个场景之后）：[transcript 10-19]"

Step C 图片生成时：image_prompt 已包含人物描述，Imagen 自动保持一致
```

#### < 10 turn 短对话的兜底

```
用户 8 turn 就结束了，增量路径从未触发

Step A 检测到 illustrated_range 为空
  → 对全量 transcript[0-7] 运行完整脚本生成
  → 生成 visual[场景1,场景2] 脚本
  → 进入 Step C 图片生成
  → 复盘页图片正常显示
```

---

### 4.7 后台任务持久化与重启恢复（H-2）

> 解决问题：Step 3a（文字总结）和 Step 3b（图片生成）在内存中异步运行，服务重启后任务消失，DB 中 `status = 'processing'` 永久卡死。

#### 核心机制：心跳 + 启动扫描恢复

不引入外部队列（Redis/Celery），用 DB 本身作为任务状态存储：

```
任务运行时：每 30s 更新 task_heartbeat 字段
服务重启时：扫描 heartbeat 超过 5 分钟未更新的 processing 任务 → 重新触发
最大重试次数：3 次，超出后标记 failed，iOS 轮询时收到失败状态
```

#### 任务运行时（心跳写入）

```python
async def run_with_heartbeat(task_record, coro):
    """通用任务包装器：执行 coro，同时每 30s 刷新 heartbeat"""

    async def heartbeat_loop():
        while True:
            await asyncio.sleep(30)
            await db.execute(
                "UPDATE live_summary_tasks SET task_heartbeat = NOW() WHERE id = :id",
                id=task_record.id
            )

    heartbeat_task = asyncio.create_task(heartbeat_loop())
    try:
        result = await coro
        await db.execute(
            "UPDATE live_summary_tasks SET status='completed', task_heartbeat=NOW() WHERE id=:id",
            id=task_record.id
        )
        return result
    except Exception as e:
        await db.execute(
            "UPDATE live_summary_tasks SET status='failed', error_msg=:msg WHERE id=:id",
            msg=str(e), id=task_record.id
        )
        raise
    finally:
        heartbeat_task.cancel()
```

#### 服务启动时（扫描恢复）

```python
# main.py 启动入口，在 uvicorn 启动后立即执行
@app.on_event("startup")
async def recover_stale_tasks():
    stale_threshold = datetime.now() - timedelta(minutes=5)

    # ── Step 3a：文字总结任务恢复 ──
    stale_summaries = await db.fetch_all("""
        SELECT * FROM live_summary_tasks
        WHERE status = 'processing'
          AND (task_heartbeat IS NULL OR task_heartbeat < :threshold)
    """, threshold=stale_threshold)

    for task in stale_summaries:
        if task.retry_count >= 3:
            await db.execute(
                "UPDATE live_summary_tasks SET status='failed', error_msg='max retries' WHERE id=:id",
                id=task.id
            )
        else:
            await db.execute(
                "UPDATE live_summary_tasks SET retry_count=retry_count+1, status='processing' WHERE id=:id",
                id=task.id
            )
            asyncio.create_task(
                run_with_heartbeat(task, summarize_live_session(task.session_id))
            )

    # ── Step 3b：图片生成任务恢复 ──
    stale_batches = await db.fetch_all("""
        SELECT * FROM live_panel_batches
        WHERE script_status = 'images_generating'
          AND (task_heartbeat IS NULL OR task_heartbeat < :threshold)
    """, threshold=stale_threshold)

    for batch in stale_batches:
        if batch.retry_count >= 3:
            await db.execute(
                "UPDATE live_panel_batches SET script_status='failed', error_msg='max retries' WHERE id=:id",
                id=batch.id
            )
        else:
            await db.execute(
                "UPDATE live_panel_batches SET retry_count=retry_count+1 WHERE id=:id",
                id=batch.id
            )
            asyncio.create_task(
                generate_images_for_batch(batch.session_id, batch.id)
            )
```

#### Step 3b 图片生成的断点续传

图片生成任务重启后，**不需要重新生成已上传 R2 的图片**：

```python
async def generate_images_for_batch(session_id, batch_id):
    batch = await db.get(batch_id)
    scripts = batch.visual_scripts  # 脚本已存 DB，不用重新生成

    for script in scripts:
        scene_index = script["scene_index"]

        # 检查此图是否已生成（R2 已有）
        existing = await db.fetch_one(
            "SELECT image_url FROM scene_images WHERE session_id=:sid AND scene_index=:idx",
            sid=session_id, idx=scene_index
        )
        if existing:
            continue  # 跳过已完成的图，直接进入下一张

        # 未生成 → 调 Imagen
        image_url = await call_imagen(script["image_prompt"])
        await db.execute(
            "INSERT INTO scene_images (session_id, scene_index, image_url) VALUES (:sid, :idx, :url)",
            sid=session_id, idx=scene_index, url=image_url
        )
        # 更新心跳
        await db.execute(
            "UPDATE live_panel_batches SET task_heartbeat=NOW() WHERE id=:id",
            id=batch_id
        )
```

#### 完整状态流转

```
任务创建（/end 调用后）
  live_summary_tasks.status = 'pending'
  live_panel_batches.script_status = 'script_ready'（脚本已有）
         │
         ▼
任务开始执行
  status → 'processing'
  task_started_at = NOW()
  heartbeat 每 30s 刷新
         │
    ┌────┴────────────────────────────┐
    │                                  │
执行成功                          服务崩溃 / 重启
    │                                  │
status → 'completed'         heartbeat 停止更新
    │                                  │
                              启动扫描（5min 超时）
                                       │
                             retry_count < 3 → 重新触发
                             retry_count ≥ 3 → status='failed'
                                       │
                             iOS panel-status 轮询收到 failed
                             → 展示"生成失败，点击重试"按钮
```

#### 各端点对 H-2 的感知

| 端点 | H-2 变化 |
|---|---|
| `POST /end` | 创建 `live_summary_tasks` 记录（status=pending），再异步触发 |
| `GET /panel-status` | 读取 `live_panel_batches.script_status`，failed 时返回 `"status":"failed"` |
| `GET /summary-status` | 读取 `live_summary_tasks.status`，failed 时返回 failed + error_msg |
| `POST /reanalyze` | 重置对应 task 的 status=pending，retry_count=0，重新触发 |

---

### 4.8 孤儿 Session 清理（H-3 修正）

> **问题本质澄清**：原描述"并发 Session 防护"不准确。Live Mode 的 UI 层已天然串行（同录音模式），用户不会故意开两个。真正的风险是 **iOS 被系统杀掉时 /end 未被调用，留下永久活跃的僵尸 Session**。

#### 触发场景

```
用户戴眼镜开始 Session A（进行中，已录 2 小时）
         ↓
iOS 被系统杀掉（内存压力 / 手机重启 / 强制退出）
         ↓
/end 接口从未调用，DB 中 Session A.status 永远是 'active'
         ↓
后端 Gemini Live WebSocket 连接孤悬，持续占用资源
         ↓
用户重新打开 App，创建 Session B 正常使用
         ↓
Session A 作为僵尸 session 永久留在 DB（资源泄漏）
```

#### 三层防护

**层 1：WebSocket 断连超时 → 自动关闭（主要防护）**

```python
# WS Handler 内：iOS audio-stream 连接断开时触发
async def on_audio_stream_disconnect(session_id: str):
    # 记录断连时间
    await db.execute(
        "UPDATE sessions SET ws_disconnected_at = NOW() WHERE id = :id",
        id=session_id
    )

    # 等待 10 分钟，看 iOS 是否重连
    await asyncio.sleep(600)

    # 重新查询：若仍未重连（ws_disconnected_at 未被清除）
    session = await db.get_session(session_id)
    if session.status == 'active' and session.ws_disconnected_at:
        await abandon_session(session_id, reason='ws_timeout')
```

```python
async def abandon_session(session_id: str, reason: str):
    """将孤儿 Session 标记为 abandoned，释放 Gemini Live 连接"""
    await db.execute(
        "UPDATE sessions SET status='abandoned', ended_at=NOW() WHERE id=:id",
        id=session_id
    )
    # 关闭对应的 Gemini Live WebSocket（如仍在线）
    await gemini_proxy.close_session(session_id)

    # 如果已有足够 turns（≥5），尝试触发补救性总结
    turn_count = await db.count("SELECT COUNT(*) FROM live_turns WHERE session_id=:id", id=session_id)
    if turn_count >= 5:
        asyncio.create_task(summarize_live_session(session_id))  # 复用 H-2 的任务机制
```

**层 2：创建新 Session 时静默清理旧孤儿**

```python
# POST /live/sessions 处理器
async def create_live_session(user_id: str, title: str):
    # 检查是否有该用户的 active session
    old_session = await db.fetch_one(
        """SELECT id, ws_disconnected_at FROM sessions
           WHERE user_id=:uid AND status='active' AND session_type='live'
           ORDER BY created_at DESC LIMIT 1""",
        uid=user_id
    )

    if old_session:
        # 已断连超过 2 分钟 → 静默关闭（不报错给用户）
        if old_session.ws_disconnected_at and \
           (datetime.now() - old_session.ws_disconnected_at) > timedelta(minutes=2):
            await abandon_session(old_session.id, reason='new_session_preempt')

        # 仍在线 → 拒绝创建，提示用户先结束当前对话
        else:
            raise HTTPException(409, detail="已有进行中的对话，请先结束")

    # 正常创建新 session
    return await db.create_session(user_id=user_id, title=title, session_type='live')
```

**层 3：定时扫描兜底（防止层 1/2 漏网）**

```python
# 每小时执行一次（可用 APScheduler 或 asyncio 定时任务）
async def cleanup_abandoned_sessions():
    cutoff = datetime.now() - timedelta(hours=1)
    stale = await db.fetch_all(
        """SELECT id FROM sessions
           WHERE status = 'active'
             AND session_type = 'live'
             AND (ws_disconnected_at < :cutoff
                  OR (ws_disconnected_at IS NULL AND created_at < :cutoff))""",
        cutoff=cutoff
    )
    for s in stale:
        await abandon_session(s.id, reason='hourly_cleanup')
```

#### 数据库变更

```sql
-- sessions 表补充字段（孤儿检测用）
ALTER TABLE sessions
ADD COLUMN ws_disconnected_at TIMESTAMPTZ DEFAULT NULL,
-- iOS audio-stream WS 断开时间；重连时清除；NULL 表示当前在线

ADD COLUMN ended_at           TIMESTAMPTZ DEFAULT NULL,
-- 正常 /end 或 abandon 时写入

ADD COLUMN abandon_reason     VARCHAR(50)  DEFAULT NULL;
-- 'ws_timeout' | 'new_session_preempt' | 'hourly_cleanup'
```

#### Session 状态流转（完整）

```
'active'
  ├─ 用户点停止 → POST /end → 'summarizing' → 'completed'
  ├─ iOS WS 断连 10min 无重连 → abandon_session() → 'abandoned'（触发补救总结）
  ├─ 创建新 Session 时检测到旧孤儿 → abandon_session() → 'abandoned'
  └─ 定时扫描超 1h → abandon_session() → 'abandoned'

'abandoned'
  └─ 如有 ≥5 turns → 异步触发文字总结（H-2 任务机制）→ 历史列表仍可查看
```

#### 与录音模式的对比

| | 录音复盘模式 | Live Mode |
|---|---|---|
| Session 时长 | 秒~分钟（上传即完成） | 分钟~小时（长连接） |
| 并发风险 | 无（UI 串行，流程短） | 有（iOS 随时可能被杀） |
| /end 是否可靠 | 是（HTTP 请求即时完成） | 否（长录音中途崩溃） |
| 防护手段 | 不需要 | WS 超时 + 创建时清理 + 定时扫描 |

---

### 4.9 Gemini Live 会话续期：原子切换（H-4）

> 解决问题：Gemini Live 单次会话约 15 分钟到期，5 小时录音需续期约 20 次。
> 目标：每次续期对 iOS 完全透明，音频流不中断，转录内容不丢失。

#### 问题本质：切换间隙的音频帧丢失

```
T-60s  Gemini 推送续期预警，后端开始建立新会话
T-0s   旧会话关闭
T+2s   新会话建立完成（约 1-3s）

间隙期（T-0 ~ T+2s）：iOS 仍在发 PCM 音频帧
  → 发给旧会话：已关闭，丢失
  → 发给新会话：还没 ready，丢失
  → 缓存起来，新会话 ready 后补发 ✅  ← 解决方案
```

**需要缓冲的音频量**：新会话建立约 1-3s，对应约 48-96 KB PCM（完全可控）。

---

#### 三步原子切换流程

```
T-60s ─────────────────────────────────────────────────────
  Gemini 推送 session_resumption_token（或 GoAway 预警）
  后端：
    ① 将 self.is_switching = True（后续音频帧进入 buffer）
    ② 异步发起新 Gemini Live 会话（携带 resumption_token）
    ③ 旧会话继续正常工作（转录不停）

T-60s ~ T-0s ──────────────────────────────────────────────
  新会话建立中（1-3s 完成）
  旧会话：继续接收音频、输出转录
  audio_buffer：积累 iOS 发来的新音频帧（小量，< 96KB）

T-0s（新会话就绪）──────────────────────────────────────────
  原子切换（3行代码，不可中断）：
    old_ws = self.active_gemini_ws
    self.active_gemini_ws = new_ws    ← 路由切换
    self.is_switching = False

  补发 buffer：
    while audio_buffer: new_ws.send(audio_buffer.popleft())

  收尾：
    old_ws.close()（优雅关闭旧会话）
    更新 DB：sessions.gemini_token = new_ws.resumption_token
    （可选）SSE 推送 session_renewed 给 iOS（debug 用）
```

---

#### 后端实现（GeminiProxySession）

```python
class GeminiProxySession:
    def __init__(self, session_id: str):
        self.session_id    = session_id
        self.active_ws     = None          # 当前 Gemini Live 连接
        self.pending_ws    = None          # 新会话（建立中）
        self.audio_buffer  = deque()       # 切换间隙的音频帧缓冲
        self.is_switching  = False
        self.resumption_token = None
        self._switch_lock  = asyncio.Lock()

    # ── 收到 Gemini 下行消息 ──
    async def on_gemini_message(self, msg: dict):
        msg_type = msg.get("type")

        if msg_type == "session_resumption_token":
            # Gemini 在会话中途持续下发，每次都更新，最新的才有效
            self.resumption_token = msg["token"]
            await db.execute(
                "UPDATE sessions SET gemini_token=:t, gemini_token_updated=NOW() WHERE id=:id",
                t=self.resumption_token, id=self.session_id
            )

        elif msg_type == "go_away":
            # 会话即将关闭，立即触发续期
            asyncio.create_task(self._renew_session())

        else:
            # 正常转录结果，写 live_turns + 触发分析
            await self._handle_transcript(msg)

    # ── iOS 发来 PCM 音频帧 ──
    async def send_audio(self, pcm_chunk: bytes):
        if self.is_switching:
            self.audio_buffer.append(pcm_chunk)   # 切换间隙：缓冲
        else:
            await self.active_ws.send_bytes(pcm_chunk)  # 正常：直接发

    # ── 核心：原子续期 ──
    async def _renew_session(self, retry: int = 0):
        async with self._switch_lock:             # 防止并发触发多次续期
            if not self.is_switching:
                self.is_switching = True
            else:
                return                            # 已在切换中，忽略重复触发

        try:
            # Step 1：建立新 Gemini Live 会话
            new_ws = await connect_gemini_live(
                resumption_token=self.resumption_token,
                timeout=10                        # 10s 超时
            )

            # Step 2：原子切换路由（不可中断）
            old_ws = self.active_ws
            self.active_ws    = new_ws
            self.is_switching = False             # 先开路由，再清 flag

            # Step 3：补发 buffer 中积累的音频帧
            while self.audio_buffer:
                await new_ws.send_bytes(self.audio_buffer.popleft())

            # Step 4：收尾
            await old_ws.close()
            await db.execute(
                "UPDATE sessions SET gemini_token=:t WHERE id=:id",
                t=new_ws.resumption_token, id=self.session_id
            )
            await sse_push(self.session_id, {"type": "session_renewed"})

        except Exception as e:
            if retry < 3:
                # 指数退避重试（1s / 2s / 4s）
                await asyncio.sleep(2 ** retry)
                await self._renew_session(retry=retry + 1)
            else:
                # 3 次全败 → 通知 iOS
                self.is_switching = False
                self.audio_buffer.clear()
                await sse_push(self.session_id, {
                    "type": "error",
                    "code": "gemini_renew_failed",
                    "message": "实时对话连接中断，已保存对话记录，建议结束本次对话"
                })
```

---

#### 时序图（5 小时录音中第 N 次续期）

```
iOS               后端 WS Handler              旧 Gemini Live      新 Gemini Live
 │                      │                            │                    │
 │── PCM 音频 ──────────▶│── 透传音频 ────────────────▶│                    │
 │                      │◀── transcript ─────────────│                    │
 │                      │                            │                    │
 │              [T-60s] │◀── go_away ────────────────│                    │
 │                      │  is_switching=True          │                    │
 │                      │── connect(resumption_token) ────────────────────▶│
 │── PCM 音频 ──────────▶│→ buffer.append()            │                    │
 │── PCM 音频 ──────────▶│→ buffer.append()            │                    │
 │                      │                            │◀── ready ──────────│
 │                      │ [原子切换]                  │                    │
 │                      │ active_ws = new_ws          │                    │
 │                      │ is_switching = False        │                    │
 │                      │── 补发 buffer ──────────────────────────────────▶│
 │── PCM 音频 ──────────▶│── 直接发新会话 ──────────────────────────────────▶│
 │                      │── close() ─────────────────▶│                    │
 │◀── session_renewed ──│                                                  │
 │  （SSE，可选）        │                                                  │
```

---

#### 关键指标

| 指标 | 数值 |
|---|---|
| 续期触发提前量 | 60s（GoAway 信号） |
| 新会话建立耗时 | 1-3s |
| 缓冲区最大占用 | ~96 KB（3s × 16kHz × 2 bytes） |
| iOS 感知到的中断 | 0ms（完全透明） |
| 转录内容丢失 | 0（buffer 补发） |
| 5 小时续期次数 | ~20 次 |
| 单次续期失败重试 | 最多 3 次，退避 1/2/4s |
| 3 次全败后行为 | SSE 推送 error，iOS 提示用户手动结束 |

---

#### 与其他模块的交互

| 模块 | 交互 |
|---|---|
| `sessions.gemini_token` | 每次续期后更新，服务重启可凭此恢复（H-2 / H-3 依赖此字段） |
| `live_events`（SSE） | `session_renewed` 事件写入，支持断连 replay（H-1 机制） |
| `recover_stale_tasks`（H-2） | 启动时若检测到 gemini_token 存在，尝试用 token 恢复 Gemini Live 连接 |
| `abandon_session`（H-3） | 孤儿 session 清理时也会调用 `gemini_proxy.close_session()`，无需等待续期 |

---

### 4.10 SpeakerMapping 持久化与重启恢复（M-2）

> 解决问题：SpeakerMapping（Speaker_X → 真实人物的映射）仅存在内存中。服务重启后映射丢失，Layer 3A/3B 加载失效，实时建议退化为无人物记忆的通用建议。

#### 问题场景

```
T=3s    点名规则识别：Speaker_1 = 张总（confidence 0.95）
T=30s   声纹比对确认：Speaker_1 = 张总（confidence 0.97）
T=60s   LLM 推断：   Speaker_2 = 李明（confidence 0.65）

        内存中 SpeakerMapping = {
            "Speaker_1": {profile_id: uuid-张总, confidence: 0.97},
            "Speaker_2": {profile_id: uuid-李明, confidence: 0.65}
        }
                ↓ 服务重启
        SpeakerMapping = {}   ← 全丢

后续影响：
  Layer 3A：profile_id 为空，张总/李明档案无法加载
  Layer 3B：无 profile_id，kg_events 查询返回空
  实时建议：退化为通用建议，丢失所有人物历史记忆
```

#### 写入时机：每次映射更新立即持久化

三条识别管线（点名规则 / 声纹比对 / LLM 推断）产出结果后，立即调用：

```python
async def persist_speaker_mapping(
    session_id: str,
    speaker_label: str,   # 'Speaker_1'
    profile_id: str,
    name: str,
    confidence: float,
    method: str           # 'rule' | 'voiceprint' | 'llm' | 'user_confirmed'
):
    await db.execute("""
        INSERT INTO live_speaker_mappings
            (session_id, speaker_label, profile_id, name, confidence, method)
        VALUES (:sid, :label, :pid, :name, :conf, :method)
        ON CONFLICT (session_id, speaker_label) DO UPDATE
            SET profile_id  = EXCLUDED.profile_id,
                name        = EXCLUDED.name,
                confidence  = EXCLUDED.confidence,
                method      = EXCLUDED.method,
                updated_at  = NOW()
        WHERE EXCLUDED.confidence >= live_speaker_mappings.confidence
        -- 只允许高置信度结果覆盖低置信度（防止 LLM 推断覆盖声纹比对）
    """, sid=session_id, label=speaker_label,
         pid=profile_id, name=name, conf=confidence, method=method)
```

**置信度覆盖规则**（`WHERE EXCLUDED.confidence >= ...`）：

| 新结果方法 | 旧结果方法 | 允许覆盖？ |
|---|---|---|
| 用户确认（1.0） | 任意 | ✅ 始终覆盖 |
| 声纹比对（~0.9） | LLM 推断（~0.65） | ✅ 覆盖 |
| LLM 推断（0.65） | 声纹比对（0.9） | ❌ 不覆盖 |
| 点名规则（0.95） | 声纹比对（0.97） | ❌ 不覆盖 |

#### 恢复时机：WS 重连 / 服务重启时从 DB 加载

```python
async def restore_speaker_mapping(session_id: str) -> dict:
    """WS 断线重连或服务重启后调用，从 DB 重建内存中的 SpeakerMapping"""
    rows = await db.fetch_all("""
        SELECT speaker_label, profile_id, name, confidence, method
        FROM live_speaker_mappings
        WHERE session_id = :sid
        ORDER BY updated_at DESC
    """, sid=session_id)

    return {
        row.speaker_label: {
            "profile_id": row.profile_id,
            "name":        row.name,
            "confidence":  row.confidence,
            "method":      row.method,
        }
        for row in rows
    }

# WS Handler：audio-stream 重连时调用
async def on_audio_stream_connect(session_id: str):
    speaker_mapping = await restore_speaker_mapping(session_id)
    segment_state.speaker_mapping = speaker_mapping
    # Layer 3A/3B 立即可用，无需重新识别
```

#### 用户确认时同步更新

结束弹窗用户确认身份后（置信度设为 1.0，覆盖所有自动识别结果）：

```python
async def confirm_speaker_identity(session_id, speaker_label, profile_id, name):
    await persist_speaker_mapping(
        session_id, speaker_label, profile_id, name,
        confidence=1.0, method='user_confirmed'
    )
    # 同时回写 live_turns.speaker_profile_id（关联已有 turns）
    await db.execute("""
        UPDATE live_turns
        SET speaker_profile_id = :pid
        WHERE session_id = :sid AND speaker_label = :label
    """, pid=profile_id, sid=session_id, label=speaker_label)
```

#### 完整生命周期

```
识别事件发生
（点名 / 声纹 / LLM）
       ↓
persist_speaker_mapping()   ← 立即写 DB（含置信度覆盖规则）
       ↓
内存 SpeakerMapping 同步更新
       ↓
Layer 3A/3B 下次调用时使用新 profile_id

服务重启 / WS 重连
       ↓
restore_speaker_mapping()   ← 从 DB 恢复，秒级完成
       ↓
Layer 3A/3B 立即恢复正常，无需重新识别

用户结束对话确认身份
       ↓
persist_speaker_mapping(confidence=1.0, method='user_confirmed')
       ↓
回写 live_turns.speaker_profile_id
```

---

### 4.11 新端点鉴权规范（M-4）

> 现有 `/api/v1/audio/*` 端点已有 JWT 中间件保护。新增 `/api/v1/live/*` 端点若实现时漏加，最严重后果是 SSE 实时对话内容被第三方监听，以及向他人 session 注入伪造音频。

#### 各端点鉴权方式

| 端点 | 类型 | 鉴权方式 | 说明 |
|---|---|---|---|
| `POST /live/sessions` | REST | Bearer JWT（Header） | 复用现有中间件 |
| `POST /live/sessions/{id}/turn` | REST | Bearer JWT（Header） | 同上 |
| `POST /live/sessions/{id}/end` | REST | Bearer JWT（Header） | 同上 |
| `POST /live/sessions/{id}/reanalyze` | REST | Bearer JWT（Header） | 同上 |
| `GET /live/sessions/{id}/panel-status` | REST | Bearer JWT（Header） | 同上 |
| `GET /live/sessions/{id}/summary-status` | REST | Bearer JWT（Header） | 同上 |
| `GET /live/sessions/{id}/events` | **SSE** | **JWT query param** | EventSource 不支持自定义 Header |
| `WS /live/sessions/{id}/audio-stream` | **WebSocket** | **JWT query param** | WebSocket 握手不支持自定义 Header |

#### REST 端点：复用现有中间件（零新增代码）

```python
# api/live.py — 路由注册时显式声明依赖，与现有 audio 路由完全一致
from api.auth import get_current_user   # 现有鉴权函数，直接复用

router = APIRouter(prefix="/api/v1/live", tags=["live"])

@router.post("/sessions")
async def create_session(user=Depends(get_current_user), ...):
    ...

@router.post("/sessions/{session_id}/end")
async def end_session(session_id: str, user=Depends(get_current_user), ...):
    await verify_session_owner(session_id, user.id)  # 加归属校验
    ...
```

#### SSE 端点：JWT query param + 握手验证

```python
@router.get("/sessions/{session_id}/events")
async def sse_events(
    session_id: str,
    token: str = Query(..., description="JWT token"),   # ?token=xxx
    request: Request = None
):
    # Step 1：验证 JWT
    user_id = verify_jwt_token(token)   # 无效则抛 401

    # Step 2：验证 session 归属
    await verify_session_owner(session_id, user_id)     # 非本人则抛 403

    # Step 3：建立 SSE 长连接
    return EventSourceResponse(event_generator(session_id, request))
```

#### WebSocket 端点：握手阶段验证，失败立即关闭

```python
@router.websocket("/sessions/{session_id}/audio-stream")
async def audio_stream(
    websocket: WebSocket,
    session_id: str,
    token: str = Query(..., description="JWT token"),   # ?token=xxx
):
    # Step 1：验证 JWT（握手阶段，连接建立前）
    try:
        user_id = verify_jwt_token(token)
    except JWTError:
        await websocket.close(code=4001, reason="Unauthorized")
        return

    # Step 2：验证 session 归属
    try:
        await verify_session_owner(session_id, user_id)
    except HTTPException:
        await websocket.close(code=4003, reason="Forbidden")
        return

    # Step 3：accept 并进入正常流程
    await websocket.accept()
    await handle_audio_stream(websocket, session_id)
```

> WebSocket 关闭码约定：`4001` = 未认证，`4003` = 无权限（4000-4999 为应用自定义区间）

#### 归属校验（所有端点复用同一函数）

```python
async def verify_session_owner(session_id: str, user_id: str):
    """
    防止 A 用自己的 JWT 访问 B 的 session_id。
    适用于所有 /live/sessions/{id}/* 端点。
    """
    session = await db.fetch_one(
        "SELECT user_id, status FROM sessions WHERE id = :id AND session_type = 'live'",
        id=session_id
    )
    if not session:
        raise HTTPException(404, "Session not found")
    if session.user_id != user_id:
        raise HTTPException(403, "Access denied")
    # 注：不校验 status，已结束的 session 仍可查询历史数据
```

#### 鉴权失败的处理方式

| 场景 | REST | SSE | WebSocket |
|---|---|---|---|
| JWT 无效 / 过期 | HTTP 401 | HTTP 401（连接建立前） | close(4001) |
| session 不属于当前用户 | HTTP 403 | HTTP 403（连接建立前） | close(4003) |
| token 缺失 | HTTP 422（参数缺失） | HTTP 422 | close(4001) |

---

## 五、iOS 客户端架构

### 5.1 新增文件（不改动现有核心文件）

```
Models.swift/WorkSurvivalGuide/WorkSurvivalGuide/
├── ViewModels/
│   ├── RecordingViewModel.swift       ← 不改动
│   ├── LiveSessionViewModel.swift     ← 全新
│   └── MetaSDKManager.swift           ← 全新
├── Views/
│   ├── Recording/                     ← 不改动
│   ├── Live/                          ← 全新目录
│   │   ├── LiveSessionView.swift
│   │   ├── LiveSuggestionCard.swift
│   │   └── LiveComicPanel.swift
│   └── Sessions/
│       └── SessionListView.swift      ← 最小改动（加 badge）
└── Network/
    └── NetworkManager.swift           ← 追加新方法，不改原有方法
```

### 5.2 MetaSDKManager

负责 HFP 蓝牙音频 + AVAudioEngine 生命周期管理，与业务逻辑完全解耦。
接口设计对上层透明，未来切换为 DAT SDK 时仅改此文件内部实现。

```
MetaSDKManager
 │
 ├─ 属性
 │   ├─ isGlassesAvailable: Bool         // iOS 蓝牙已配对 + HFP 设备在线
 │   └─ connectionState: ConnectionState  // .idle / .connecting / .active / .error
 │
 ├─ 核心组件
 │   ├─ AVAudioSession                    // 模式：.voiceChat（内置软件降噪 + AEC）
 │   │   选项：.allowBluetooth           // 启用 HFP 输入（眼镜麦克风）
 │   └─ AVAudioEngine                     // 实时 PCM 采集 + 重采样
 │
 ├─ 眼镜检测逻辑
 │   AVAudioSession.availableInputs
 │       → 筛选 portType == .bluetoothHFP
 │       → 若存在 → isGlassesAvailable = true
 │       → 监听 routeChangeNotification（连接/断开实时更新）
 │
 ├─ 音频处理管线（无唤醒词，用户点按钮即触发）
 │   HFP 蓝牙音频（Int16 PCM，16kHz，来自眼镜麦克风）
 │       → AVAudioSession 内置降噪（voiceChat 模式自动应用）
 │       → 重采样至 16kHz mono（若需要）
 │       → 积累约 100ms chunk
 │       → Base64 编码
 │       → 输出给 GeminiLiveManager（管线 A）
 │       → 同时写入声纹缓冲区（管线 B，经 VAD 过滤后用于身份识别）
 │
 ├─ func connect()      // 设置 AVAudioSession，选定眼镜为输入设备
 ├─ func startCapture() // AVAudioEngine 开始采集，启动 chunk 输出
 ├─ func stopCapture()  // 停止采集，保持蓝牙连接
 └─ func disconnect()   // 还原 AVAudioSession 路由
```

**GeminiLiveManager（新增，独立于 MetaSDKManager）：**

```
GeminiLiveManager
 │
 ├─ WebSocket 连接
 │   wss://generativelanguage.googleapis.com/ws/.../BidiGenerateContent?key=...
 │
 ├─ 发送（接收 MetaSDKManager 的 PCM chunks）
 │   { "realtimeInput": { "audio": { "data": "<base64>", "mimeType": "audio/pcm;rate=16000" } } }
 │
 ├─ 接收（Gemini Live 返回转录 + Diarization）
 │   { speaker: "Speaker_1", text: "我觉得预算有点高", is_user: false }
 │
 └─ 输出（Combine Publisher）：
     onTurnReceived: (speaker: String, text: String, isUser: Bool, timestampMs: Int)
     → 下游：LiveSessionViewModel 消费
```

**眼镜检测逻辑（App 启动 + 蓝牙路由变化时）：**

```
App 启动 / 收到 AVAudioSession.routeChangeNotification
 ├─ availableInputs 中存在 portType == .bluetoothHFP
 │       └─ isGlassesAvailable = true → 主界面显示 Live 入口
 └─ 否则
         └─ isGlassesAvailable = false → 界面与现在完全一致，无任何新元素
```

### 5.3 LiveSessionViewModel

```
LiveSessionViewModel
 ├─ 状态
 │   ├─ sessionState: .idle / .connecting / .active / .paused / .ended
 │   ├─ currentSuggestion: QuickSuggestion?      // 最新实时建议
 │   ├─ comicPanels: [ComicPanel]                // 追加模式：按 scene_index 排序
 │   │   ComicPanel { sceneIndex, batchIndex, imageUrl?, status: .pending/.ready }
 │   ├─ skillCards: [SkillCard]                   // 最新完整分析结果
 │   ├─ transcript: [TurnItem]                    // 实时字幕
 │   └─ elapsedSeconds: Int
 │
 ├─ 输入处理
 │   ├─ onTurnReceived(speaker, text)
 │   │   ├─ 追加到 transcript
 │   │   ├─ POST /live/sessions/{id}/turn
 │   │   └─ 若响应含 suggestion → 更新 currentSuggestion
 │   └─ 订阅 SSE：GET /live/sessions/{id}/events
 │       ├─ .suggestion     → 更新 currentSuggestion
 │       ├─ .analysis_ready → 更新 skillCards，在 comicPanels 中追加 .pending 占位
 │       └─ .image_ready    → 按 scene_index 找到对应 ComicPanel，更新 imageUrl + status=.ready，播放淡入动画
 │
 └─ 操作
     ├─ startSession()  → POST /live/sessions
     ├─ endSession()    → POST /live/sessions/{id}/end
     └─ reanalyze()     → POST /live/sessions/{id}/reanalyze
```

### 5.4 NetworkManager 追加方法（不改现有）

```swift
// 追加到 NetworkManager.swift 末尾，Live 模式专用

func createLiveSession(title: String?) async throws -> LiveSession
func submitTurn(sessionId: String, turn: TurnRequest) async throws -> TurnResponse
func endLiveSession(sessionId: String) async throws -> LiveSessionSummary
func reanalyzeLiveSession(sessionId: String) async throws -> ReanalyzeResponse
func subscribeLiveEvents(sessionId: String) -> AsyncStream<LiveEvent>
```

---

## 六、UI 设计

### 6.1 主界面入口变化

**有眼镜时（新增 Live 入口）：**

```
┌─────────────────────────────┐
│     [录音按钮（现有）]       │
│                              │
│  ┌──────────────────────┐   │
│  │  👓 Ray-Ban 已连接    │   │← 新增，检测到眼镜时出现
│  │  [ 开始实时对话 ]     │   │
│  └──────────────────────┘   │
└─────────────────────────────┘
```

**无眼镜时：** 界面与现在完全一致，不显示任何新元素。

### 6.2 LiveSessionView 布局

```
┌─────────────────────────────────────────┐
│  🔴 LIVE  与同事对话中         00:03:24  │  ← 顶部状态栏
│  👓 Ray-Ban · 2位说话人                  │
├─────────────────────────────────────────┤
│                                          │
│  ┌───────────────────────────────────┐  │
│  │       漫画区（结束后生成）         │  │
│  │                                   │  │
│  │  对话进行中（始终显示）：          │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │  🎨 对话结束后自动生成漫画   │  │  │
│  │  │     已记录 N 个关键场景      │  │  │  ← 每批脚本生成后更新 N
│  │  └─────────────────────────────┘  │  │
│  │                                   │  │
│  └───────────────────────────────────┘  │
│                                          │
├─────────────────────────────────────────┤
│  💡 实时建议                    刚刚更新 │  ← 快速路径，每轮刷新
│  ─────────────────────────────────────  │
│  对方在防御，避免追问，换个角度切入      │
│  ⚠️ 对方情绪：防御中                    │
│                                          │
├─────────────────────────────────────────┤
│  对话记录  ▾                            │  ← 默认折叠
│  你：这个方案你怎么看？                  │
│  对方：我觉得预算有点高...              │
└─────────────────────────────────────────┘

          [  暂停  ]    [  结束对话  ]
```

### 6.3 结束对话弹窗

```
┌─────────────────────────────────────────┐
│  对话结束                                │
│  时长：5分24秒  · 对话轮次：28次        │
│                                          │
│  ┌─────────────────────────────────┐    │
│  │  ✅ 查看本次实时分析结果         │    │← 已有的实时 skill_cards
│  └─────────────────────────────────┘    │
│                                          │
│  ┌─────────────────────────────────┐    │
│  │  🔄 重新运行完整复盘分析         │    │← 触发 /reanalyze
│  │  （更深入，约需 30 秒）          │    │
│  └─────────────────────────────────┘    │
│                                          │
│            [ 稍后再看 ]                  │
└─────────────────────────────────────────┘
```

### 6.4 历史记录列表区分

**普通录音卡片（现有，不变）：**

```
┌─────────────────────────────────────────┐
│  [封面图]  与领导的谈话                  │
│            2026-06-05 · 12分钟          │
│            😰 焦虑  · 薪资谈判          │
└─────────────────────────────────────────┘
```

**Live session 卡片（新增 badge，其余样式复用）：**

```
┌─────────────────────────────────────────┐
│  [封面图]  与同事的项目讨论     [👓LIVE] │← 右上角 badge
│            2026-06-06 · 5分钟           │
│            ⚠️ 防御  · 职场沟通          │
└─────────────────────────────────────────┘
```

---

## 七、新旧路径隔离策略

### 7.1 代码隔离

| 层 | 现有代码（不改动） | 新增代码 | 共享调用 |
|---|---|---|---|
| 后端入口 | `main.py` `/audio/upload` | `api/live.py` `/live/*` | — |
| 后端服务 | `analyze_audio_from_path` | `live_session_service.py` | `classify_scene()` `match_skills_v2()` `generate_scene_images()` |
| iOS ViewModel | `RecordingViewModel.swift` | `LiveSessionViewModel.swift` `MetaSDKManager.swift` | — |
| iOS View | `Recording/` 目录 | `Live/` 目录 | `StrategyCard` 等展示组件 |
| iOS Network | 现有方法保持不变 | 追加新方法 | — |

### 7.2 降级策略

```
眼镜断连（Live 进行中）
 ├─ 自动暂停，弹出提示："眼镜已断开，是否结束本次对话？"
 ├─ 用户选"继续等待" → 等待重连，超时 30s
 └─ 用户选"结束" → 走 endSession，保存已有记录

Live 模式降级为 Review 模式
 → 用户在结束后触发 /reanalyze
 → 完全复用现有复盘分析流程，行为与普通录音一致
```

---

## 八、开发分阶段计划

| 阶段 | 内容 | 改动范围 |
|---|---|---|
| Phase 1 | 后端 live 基础架构（新文件 + 新 API + DB 变更） | `live_session_service.py` `api/live.py` `models.py`（加列） |
| Phase 2 | iOS Live 模式基础（Meta SDK + LiveSession UI） | 全新文件，`NetworkManager.swift` 追加方法 |
| Phase 3 | 异步路径 + 漫画生成接入 | `live_session_service.py` 内新增函数 |
| Phase 4 | 历史列表区分 + 复盘入口 | `SessionListView.swift` 最小改动 |

---

## 九、说话人身份识别

### 9.1 问题层次

HFP 给的是单声道 16kHz PCM 音频，Gemini Live 在转录时提供 Speaker Diarization（区分几个人在说话），但不知道每个说话人是谁。

**关于单声道音频对说话人识别的影响：**
- Gemini Live 的 Diarization 基于声纹特征，不依赖麦克风数量，单声道是标准输入
- 用户戴着眼镜，嘴部距麦克风约 5cm，对方约 1m，音量差约 26dB，用户声音天然最突出
- 声纹比对（管线 B）在单声道音频上完全可用，需加 VAD 过滤保证输入质量

```
层次 1：用户 vs 其他人          → Gemini Live Diarization 已解决
层次 2：other 有几个人          → Gemini Live Diarization 已解决（Speaker_0 / Speaker_1 ...）
层次 3：Speaker_X 是谁          → 需要额外识别 ← 本章解决
层次 4：Speaker_X 是档案里哪个人 → 需要额外匹配
```

Gemini Live 实际返回格式：
```json
{ "speaker": "Speaker_0", "text": "你们觉得这个方案怎么样？", "is_user": true  },
{ "speaker": "Speaker_1", "text": "我觉得预算有点高",          "is_user": false },
{ "speaker": "Speaker_2", "text": "时间线也太紧了吧",          "is_user": false },
{ "speaker": "Speaker_1", "text": "我们需要更多资源",          "is_user": false }
```

---

### 9.2 核心设计：两条管线并行，互不阻塞

**身份识别不插入音频处理流水线，而是和它并行运行。**

```
眼镜原始 PCM 音频
         │
         ├─────────────────────────────────────────────────────────
         │  管线 A：实时转录（不等身份，先跑）
         │
         │  Float32 → Int16 → 16kHz mono → 100ms chunks
         │       → Gemini Live WebSocket（音频转录 + Diarization）
         │       → 返回：{ speaker: "Speaker_1", text: "..." }
         │       → 实时建议（用角色类型，不等具体身份）
         │
         └─────────────────────────────────────────────────────────
            管线 B：身份识别（并行，不阻塞 A）

            同样的 PCM 数据 → [VAD 过滤（iOS 本地，<3ms）]
                 │                    │
                 │              静音/噪音帧 → 丢弃（不进入声纹比对）
                 │
                 └─ 语音帧写入 Speaker 音频缓冲区
                        │
                        ├─ Speaker_1 音频段积累器（累积 2-3 秒干净语音）
                        │       满足时长 → 声纹比对 → 更新 SpeakerMapping
                        │
                        └─ Speaker_2 音频段积累器（累积 2-3 秒干净语音）
                                同上
            同时：
            管线 A 产出的文字 → 点名规则 + LLM 推断 → 更新 SpeakerMapping
```

> **为什么不串行？**
> 100ms chunk 太短，声纹识别至少需要 2-3 秒连续语音。
> 串行会让实时建议延迟从 2s 变成 10s+，不可接受。

---

### 9.3 识别工具箱（按触发速度排序）

| 工具 | 耗时 | 前提条件 | 说明 |
|---|---|---|---|
| **① Gemini `is_user` 标记** | 实时 | 无 | Gemini 根据音量/距离自动标记谁是用户，免费且始终可用 |
| **② 声纹比对** | <500ms | 档案中存有该人声纹 | PCM 音频段 → 余弦相似度比对，经 VAD 过滤后触发 |
| **③ 点名规则** | <100ms | 对话中出现档案姓名 | 纯文本规则，无 LLM，每个 turn 返回后立即扫描 |
| **④ 排除法** | 即时 | 其他工具已识别部分人 | 已确认的人从候选集排除，缩小剩余人的搜索范围 |
| **⑤ LLM 上下文推断** | 3-8s | 有档案 + 足够对话内容 | 分析话题/称谓/角色语气与档案匹配，每 10 turn 触发 |
| **⑥ 结束弹窗（用户确认）** | 用户操作 | 无 | 所有自动工具置信度不足时的最终兜底，展示代表性语句辅助选择 |

---

### 9.4 三条输入驱动身份识别

**输入 1：PCM 音频段（工具②，声纹比对）**

```
触发时机：某个 Speaker 积累到 2-3 秒有效语音帧（经 VAD 过滤后）
速度：最快（< 500ms 出结果）
准确率：最高（> 90%，有声纹时）
前提：profiles 表中已存有该人声纹特征

VAD 过滤（iOS 本地，MetaSDKManager 内执行）：
  方案 A（推荐）：AVAudioSession mode = .voiceChat
                  → 系统自动降噪，输出帧信噪比已提升
                  → 无需额外算法，零开销
  方案 B（可选）：WebRTC VAD 库（< 50KB，< 1ms/帧）
                  → 精确判断每帧是"语音"还是"静音/噪音"
                  → 仅在室外/嘈杂场景准确率不足时引入

  当前阶段：先用方案 A，上线后如声纹误识别率 > 15% 再引入方案 B

流程：
  Speaker_X 音频段（2-3s 有效帧，非静音非噪音）
      → 与 profiles.voiceprint 做余弦相似度比对
      → 相似度 > 0.8 → 确认身份
      → 写入 SpeakerMapping: { Speaker_X: profile_id, confidence: 0.92 }
```

**输入 2：Gemini 返回的文字（工具③，点名规则）**

```
触发时机：每个 turn 文字返回后立即扫描
速度：极快（< 100ms，无 LLM 调用，纯规则）
准确率：高（95%，有点名时）
前提：无，随时可用

规则：
  用户说 "张总，您看这个方案…"
      → 扫描：文字包含已知档案姓名 + 下一句是 Speaker_X 说的
      → 规则匹配：Speaker_X 暂定 = 张总
      → 写入 SpeakerMapping: { Speaker_X: 张总_profile_id, confidence: 0.95 }
```

**输入 3：积累的对话上下文（工具⑤，LLM 推断）**

```
触发时机：每积累 10 个 turn，或对话结束后
速度：最慢（3-8s，有 LLM 调用）
准确率：中（60-70%，无声纹无点名时的兜底）
前提：无，随时可用

流程：
  完整 transcript（前 N 轮）+ 用户所有档案摘要
      → LLM 分析说话风格、话题、角色语言
      → 输出：{ Speaker_X: probable_profile_id, confidence: 0.65, evidence: "..." }
      → 写入 SpeakerMapping（低置信度，待确认）
```

---

### 9.5 三条结果汇入 SpeakerMapping，随时间收敛

```
Session 开始
    │
T=0s    SpeakerMapping: { Speaker_1: 未知, Speaker_2: 未知 }
    │   实时建议依据：角色类型（上级/同事，从语气推断）
    │
T=3s    输入 2（点名规则）触发：
    │   用户说了"张总"，Speaker_1 接着回答
    │   SpeakerMapping: { Speaker_1: 张总(0.95), Speaker_2: 未知 }
    │   实时建议升级：知道对方是张总，建议更有针对性
    │
T=5s    输入 1（声纹比对）出结果：
    │   Speaker_1 音频积累了 3s，比对档案声纹
    │   SpeakerMapping: { Speaker_1: 张总(0.95→0.97), Speaker_2: 未知 }
    │   （声纹和点名双重确认，置信度提升）
    │
T=30s   输入 3（LLM 推断）出结果：
    │   Speaker_2 说话风格 → 偏执行层，话题是技术细节
    │   档案里有"李明（工程师）"匹配
    │   SpeakerMapping: { Speaker_1: 张总(0.97), Speaker_2: 李明(0.65) }
    │
T=结束   用户确认弹窗：
        张总 ✓（高置信，默认已选）
        李明 ?（低置信，需用户点确认）
        最终写入 live_turns.speaker_profile_id
```

---

### 9.6 实时建议的两个阶段

```
阶段 1（身份未知时，T=0 开始）：
  "对方情绪偏防御，建议换个角度切入"
  → 依据：Speaker_1 的语气 / 对话结构
  → 角色类型 = 上级（推断），足够驱动技能匹配

阶段 2（身份确认后，SpeakerMapping 更新时自动切换）：
  "张总通常关注资源分配，可以从 ROI 角度切入"
  → 依据：张总档案的历史对话记录 + KG 知识图谱
  → 建议更个性化，有历史上下文
```

---

### 9.7 首次对话（无档案）的处理

```
第一次遇到这个人，三条输入都无法匹配到已有档案
    │
    ▼
实时阶段：
  用角色类型（上级/同事/朋友）驱动技能匹配
  漫画按 LLM 推断外貌特征绘制（性别/年龄/风格）
  不依赖档案照片（复用现有文字级人物一致性逻辑）

对话结束后弹窗：
  "这次对话出现了新面孔（说话人 B）"
  [创建档案] → 预填 LLM 推断的姓名 / 角色 / 关系类型
  [跳过]     → 匿名保存，记录完整保留

下次再遇同一个人：
  有档案 → 声纹 + 点名 + LLM 均可匹配
  漫画开始使用档案照片（复用现有 Level 1-3 策略）
```

---

### 9.8 场景 × 信息条件完整矩阵（12种组合）

**场景定义：**
- **A**：只有用户自己说话
- **B**：用户 + 1个他人（共2人）
- **C**：用户 + 2个以上他人（共3人以上）

**信息条件定义：**
- **信息1**：所有人档案有人名 + 对应声纹
- **信息2**：所有人均有档案人名，但都无声纹
- **信息3**：我有档案+声纹，他人有档案人名但无声纹
- **信息4**：我有档案+声纹，无他人档案，无他人声纹

---

#### 场景 A：只有用户自己说话

**A-信息1（所有人有名+声纹）**
```
Gemini 返回 Speaker_0（is_user=true，唯一说话人）
工具① is_user 标记 → 确认是我
工具② 声纹比对 → 双重确认
✅ 准确率 100%
```

**A-信息2（所有人有名，无声纹）**
```
Gemini 返回 Speaker_0（is_user=true，唯一说话人）
工具① is_user 标记 → 唯一说话人，就是我
✅ 准确率 100%
```

**A-信息3（我有声纹，他人有名无声纹）**
```
同 A-信息1，唯一说话人，工具①② 均指向我
✅ 准确率 100%
```

**A-信息4（我有声纹，无他人档案）**
```
同 A-信息1，唯一说话人，工具①② 均指向我
✅ 准确率 100%
```

---

#### 场景 B：用户 + 1个他人（2人对话）

**B-信息1（所有人有名+声纹）**
```
Gemini 返回：Speaker_0(is_user=true), Speaker_1(is_user=false)

Speaker_0（我）：
  工具① is_user=true + 工具② 声纹比对
  → ✅ ~99% 确认

Speaker_1（他人）：
  工具② 声纹比对 → 在档案里遍历匹配
  → ✅ ~90% 准确（2-3s 积累干净语音后触发）

⏱ 全部识别完成时间：约 3-5s
✅ 总体准确率：高
```

**B-信息2（所有人有名，无声纹）**
```
Gemini 返回：Speaker_0(is_user=true), Speaker_1(is_user=false)

Speaker_0（我）：
  工具① is_user=true
  → ✅ ~95%（物理距离优势，Gemini 标记准确）

Speaker_1（他人）：
  工具② 无声纹，跳过
  工具③ 点名规则：
    - 我叫了"张总"，下一句 Speaker_1 回应 → 识别为张总
    有点名 → ✅ 95%
    无点名 → 继续往下
  工具⑤ LLM推断：
    - 分析说话风格/称谓/话题，与档案比对
    → ⚠️ 60-70%
  工具⑥ 结束弹窗：
    "本次对话的对方是谁？" → 展示档案列表
    → ✅ 100%（用户确认后）

✅/⚠️ 我可识别；他人有点名则高准确，无点名依赖 LLM+弹窗
```

**B-信息3（我有声纹，他人有名无声纹）**
```
Speaker_0（我）：
  工具① + 工具② 声纹比对
  → ✅ ~99%（比 B-信息2 更确定）

Speaker_1（他人）：
  工具② 无对方声纹，跳过
  工具③④⑤⑥ 识别路径与 B-信息2 的他人完全相同

关键差异：我的识别从 95% 提升到 99%，他人识别路径不变
✅ 我准确；他人依赖点名/LLM/弹窗
```

**B-信息4（我有声纹，无他人档案）**
```
Speaker_0（我）：
  工具② 声纹比对 → ✅ ~99%

Speaker_1（他人）：
  工具②③⑤ 均无法匹配（档案里根本没有此人）
  工具⑥ 结束弹窗：
    "检测到一位新面孔，是否创建档案？"
    → 预填 LLM 推断的姓名/角色/关系类型
    → 用户填写 → 创建档案，本次对话完成标注
    → 下次见面可声纹匹配

✅ 我准确；他人触发新建档案流程
```

---

#### 场景 C：用户 + 2个以上他人（3人以上）

**C-信息1（所有人有名+声纹）**
```
Gemini 返回：Speaker_0, Speaker_1, Speaker_2

Speaker_0（我）：工具①② → ✅ ~99%

Speaker_1 / Speaker_2（他人）：
  工具② 各自声纹比对 → 在档案里遍历匹配
  → ✅ ~85%（多人场景下声纹提取质量略降）

⚠️ 主要风险：多人同时说话时音频重叠，VAD 过滤后
   可能等待更长时间才能拿到 2-3s 干净语音段
   → 声纹比对推迟，但不影响实时建议（用角色类型先跑）

✅ 整体可识别，需等待干净语音段
```

**C-信息2（所有人有名，无声纹）**
```
Speaker_0（我）：工具① is_user=true → ✅ ~95%

Speaker_1 / Speaker_2（两个未知人）：
  工具② 无声纹，跳过
  工具③ 点名规则：
    - 我叫"张总"，Speaker_1 回应 → 可能是张总
    - 我叫"李明"，Speaker_2 回应 → 可能是李明
    - 但两人都未被点名 → 无法自动区分
  工具④ 排除法：
    已确认我是 Speaker_0 → 候选档案排除我
    若点名确认 Speaker_1=张总 → Speaker_2 候选再排除张总
  工具⑤ LLM推断：
    2个未知人，推断难度倍增
    话题/角色有明显差异时才有效（一个谈技术/一个谈预算）
    → ⚠️ 50-60%，显著低于2人场景
  工具⑥ 结束弹窗（必须依赖）：
    展示每个说话人的代表性语句（3-5句），让用户为每人选档案
    → ✅ 100%（用户确认后）

❌ 自动识别准确率低；点名时部分可识别；弹窗是主要兜底
```

**C-信息3（我有声纹，他人有名无声纹）**
```
Speaker_0（我）：工具② 声纹比对 → ✅ ~99%

Speaker_1 / Speaker_2（他人）：
  工具④ 排除法：我确认后搜索空间缩小
  工具③ 点名规则 → 同 C-信息2
  工具⑤ LLM推断 → 同 C-信息2
  工具⑥ 弹窗 → 同 C-信息2

✅ 我准确；他人识别路径与 C-信息2 相同
```

**C-信息4（我有声纹，无他人档案）**
```
Speaker_0（我）：工具② 声纹比对 → ✅ ~99%

Speaker_1 / Speaker_2（他人）：
  工具②③⑤ 均无法匹配
  工具⑥ 结束弹窗：
    "检测到 2 位新面孔"
    → 分别展示各说话人代表性语句
    → 用户逐个命名/创建档案（批量新建流程）

✅ 我准确；他人触发批量新建档案流程
```

---

#### 12种组合汇总矩阵

| | **A（1人）** | **B（2人）** | **C（3人+）** |
|---|---|---|---|
| **信息1** 全员有名+声纹 | ✅ 100% | ✅ ~90%（3-5s内） | ✅ ~85%（等干净帧） |
| **信息2** 全员有名无声纹 | ✅ 100% | ✅ 我95% / ⚠️ 他人靠点名+弹窗 | ✅ 我95% / ❌ 他人强依赖弹窗 |
| **信息3** 我有声纹/他人有名无声纹 | ✅ 100% | ✅ 我99% / ⚠️ 他人靠点名+弹窗 | ✅ 我99% / ⚠️ 他人靠点名+弹窗 |
| **信息4** 我有声纹/他人无档案 | ✅ 100% | ✅ 我99% / 他人→新建档案 | ✅ 我99% / 他人→批量新建 |

---

#### 三个关键设计决策（由矩阵分析得出）

**决策1：声纹是核心基础设施，强引导录入**

没有声纹的场景（信息2/3/4的他人部分）全部严重依赖点名或弹窗确认。
产品策略：首次使用时引导用户为常用联系人录制 10-15s 声纹样本，解锁 B-1/C-1 高准确路径。

**决策2：点名规则是无声纹场景的最高价值信号**

无声纹时，点名规则（95%）远优于 LLM 推断（50-70%），且零延迟、零成本。
实时建议中应主动提示用户"在对话中叫出对方名字"以帮助系统识别。

**决策3：结束弹窗必须展示代表性语句，而非只列档案名单**

用户无法凭空回忆"说话人B是谁"，必须给上下文：
```
说话人 B 说了这些话：
  "我觉得预算有点高"
  "时间线也太紧了"
  "我们需要更多资源"
请问他/她是：[张总] [李明] [王总] [其他...]
```

---

### 9.9 后端组件：SpeakerIdentificationService

```
SpeakerIdentificationService（live_session_service.py 内）
 │
 ├─ voiceprint_match(speaker_audio_segment, profiles)     ← 输入 1
 │   → 音频段（2-3s）与档案声纹做余弦相似度比对
 │   → < 500ms，无 LLM，最高优先级
 │   → 更新 SpeakerMapping（confidence ≥ 0.8 时覆盖低置信结果）
 │
 ├─ rule_based_identify(turn_text, transcript_context)   ← 输入 2
 │   → 扫描点名模式，< 100ms，纯规则，无 LLM
 │   → 每个 turn 返回文字后立即触发
 │   → 更新 SpeakerMapping（confidence = 0.95）
 │
 ├─ llm_infer_identity(transcript, user_profiles)        ← 输入 3
 │   → 每 10 turn 或对话结束后触发
 │   → 输出含置信度和推断依据的 SpeakerMapping
 │   → 仅在前两条无结果时作为兜底
 │
 └─ confirm_speaker_mapping(session_id, confirmed_mapping)
     → 用户在结束弹窗确认后调用
     → 写入 live_turns.speaker_profile_id
     → 可选：触发声纹采集（见 9.9）
```

**live_turns 表补充字段：**

```sql
ALTER TABLE live_turns
ADD COLUMN speaker_label      VARCHAR(20)  DEFAULT NULL,
-- Gemini Diarization 原始标签：'Speaker_0' / 'Speaker_1'

ADD COLUMN inferred_name      VARCHAR(100) DEFAULT NULL,
-- rule-based 或 LLM 推断的姓名，如 '张总'

ADD COLUMN speaker_profile_id UUID REFERENCES profiles(id) DEFAULT NULL,
-- 用户确认后填入

ADD COLUMN id_confidence      FLOAT        DEFAULT NULL;
-- 最终使用的置信度（0-1）
```

---

### 9.10 声纹采集（Roadmap，不阻塞当前开发）

```
用户确认 Speaker_1 = 张总 后，弹出可选提示：

"是否为张总添加声音识别？下次对话自动认出他"

用户同意：
  → 从本次对话的 Speaker_1 PCM 片段提取声纹特征向量
  → 存入 profiles.voiceprint（新字段，JSONB）
  → 下次对话：PCM 音频 → 声纹比对（输入 1）→ 自动匹配，无需点名

当前阶段：仅预留 profiles.voiceprint 字段，不实现提取逻辑
```

---

## 十、结束流程（Live 模式专属）

### 10.1 完整结束流程总览

```
用户点击停止录音
        │
        ▼
┌───────────────────────────────────┐
│  Step 1：二次确认                  │
│  "确定结束本次对话？"             │
│  [继续对话]      [结束对话]        │
└──────────────────┬────────────────┘
                   │ 用户选"结束"
                   ▼
┌─────────────────────────────────────────────────────┐
│  Step 2：说话人档案补全（按置信度分级）              │
│                                                     │
│  规则：置信度 ≥ 0.85 → 自动通过，不显示             │
│                                                     │
│  置信度 0.60-0.85（LLM推断，需确认）：              │
│  ┌──────────────────────────────────────────┐       │
│  │ 说话人B是张总吗？                         │       │
│  │ 他说了："我觉得预算有点高"               │       │
│  │          "时间线也太紧了"                │       │
│  │  [✓ 是张总]  [修改]  [跳过]              │       │
│  │                                          │       │
│  │  确认后行内弱提示（非阻塞弹窗）：         │       │
│  │  💬 为张总录入声音识别？[录入] [跳过]    │       │
│  └──────────────────────────────────────────┘       │
│                                                     │
│  置信度 < 0.60 / 完全无档案（新面孔）：             │
│  ┌──────────────────────────────────────────┐       │
│  │ 发现新面孔，是否创建档案？               │       │
│  │ 预填：姓名[___] 关系[同事▼] 职位[___]   │       │
│  │  [创建档案]  [跳过]                      │       │
│  └──────────────────────────────────────────┘       │
│                                                     │
│  所有人处理完毕 → [完成，进入复盘]                  │
└─────────────────────────┬───────────────────────────┘
                          │
                          ▼
              立即跳转复盘页（不等后台完成）
                          │
           ┌──────────────┴──────────────┐
           │    后台并行执行 3a + 3b       │
           └──────────────┬──────────────┘
                          │
            ┌─────────────┴─────────────┐
            ▼                           ▼
  Step 3a：文字总结              Step 3b：统一图片生成
  summarize_live_session()       收集全部 visual[] 脚本
  · 合并全量 transcript          · 补全尾部未覆盖 turn 脚本
  · 分析尾部未覆盖 turn          · 批量调用 Imagen
  · 生成 card_title + 概要       · 图片逐张写 R2 + DB
  · 写入 sessions 表             · iOS 轮询 panel-status
  · 历史列表下次 fetch 更新标题  · 复盘页骨架屏逐张替换
```

---

### 10.2 复盘页加载状态

进入复盘页时各区域初始状态及更新时机：

```
┌─────────────────────────────────────────┐
│  Live 对话 · 2026-06-06    [👓 LIVE]    │← 标题暂用时间戳
│  概要生成中...             ─────────    │← Step 3a 完成后替换
├─────────────────────────────────────────┤
│  Tab 1：实时分析  │  Tab 2：完整复盘    │
│  （增量 skill_cards，立即可看）         │← analysis_type='incremental'
│  Tab 2：骨架屏，Step 3a 完成后填入      │← analysis_type='full'
├─────────────────────────────────────────┤
│  漫画                                   │
│  [骨架屏] [骨架屏] [骨架屏]            │← Step 3b 开始后显示
│  图片完成后淡入替换，横向滑动           │
└─────────────────────────────────────────┘

底部声纹弱提示（如 Step 2 有人选了"录入"但未完成）：
╔═══════════════════════════════════════╗
║ 💬 为张总录入声音识别？下次自动认出他  ║
║  [立即录入]            [不了]          ║
╚═══════════════════════════════════════╝

用户退出复盘页但仍未处理声纹录入：
→ 弱弹窗："下次见到张总时要提醒我录入声音吗？"
  [提醒我]  [不用了]
```

---

### 10.3 声纹录入状态机

```
用户在 Step 2 点击"录入" 或复盘页底部弱提示点"录入"：
  → profiles.voiceprint_status = 'pending'
  → 系统标记：本次对话的 Speaker_X PCM 片段需提取声纹
  → 实际提取逻辑（Roadmap，当前阶段不实现）

voiceprint_status 状态流：
  'none'    → 未录入，首次见面
  'pending' → 用户已同意，等待声纹提取实现
  'ready'   → 声纹已提取，可用于比对（Pipeline B 输入1）

当前阶段：
  点击"录入" → 只写 pending，不做实际提取
  Pipeline B 输入1（声纹比对）检查 status == 'ready' 才触发
  → pending 状态不影响当前功能，为后续版本预留
```

---

### 10.4 Step 3a：文字总结（summarize_live_session）

```
函数：summarize_live_session(full_transcript, confirmed_speakers)

输入：
  · full_transcript：所有 live_turns 合并（含尾部 turn）
  · confirmed_speakers：Step 2 确认后的 SpeakerMapping

Gemini 调用（1次，复用现有 Call #1 提示词改造）：
  可复用：card_title 生成、session 概要生成
  不需要：音频转录、说话人检测（已有）

输出写入：
  sessions.card_title    ← 历史列表显示
  sessions.summary       ← 复盘页概要区
  sessions.status = 'summarized'

耗时目标：< 10s
```

---

### 10.5 历史列表标题更新

```
Live session 创建时：
  sessions.card_title = NULL
  历史列表显示：「Live 对话 · HH:mm」（fallback）

Step 3a 完成后：
  sessions.card_title = "与张总的项目预算讨论"
  iOS 历史列表：下次进入页面时重新 fetch，展示新标题
  （无需 Push Notification，pull-to-refresh 或重新进页面即可）
```

---

### 10.6 新增 API 端点（结束流程）

**POST /api/v1/live/sessions/{id}/end（更新响应）**

```json
{
  "session_id": "uuid",
  "session_type": "live",
  "total_turns": 28,
  "duration_seconds": 324,
  "total_scripts": 7,         // 已生成脚本的场景数
  "summary_status": "processing",   // 文字总结状态
  "image_status": "processing"      // 图片生成状态
}
```

**GET /api/v1/live/sessions/{id}/summary-status（新增）**

复盘页轮询文字总结进度：

```json
{
  "summary_status": "completed",    // processing | completed | failed
  "card_title": "与张总的项目预算讨论",
  "summary": "本次对话围绕Q3预算方案展开..."
}
```

---

### 10.7 新增 API 端点（Step 2 Speaker 确认流程）

> 以下端点对应停止录音弹窗 Step 2 中用户对 Speaker 识别结果的确认、修改和新建操作。

---

**POST /api/v1/live/sessions/{id}/confirm-speaker（新增）**

场景：识别置信度 0.60–0.85（情况 B），用户点击「✓ 确认」按钮，确认 Speaker_X = 某位已有档案成员。

Request：
```json
{
  "speaker_label": "Speaker_1",
  "profile_id": "uuid",
  "confidence": 1.0,
  "method": "user_confirmed"
}
```

Response：
```json
{
  "success": true,
  "speaker_label": "Speaker_1",
  "profile_id": "uuid",
  "profile_name": "张总"
}
```

服务端行为：
- 写入 `live_speaker_mappings`（`ON CONFLICT DO UPDATE WHERE confidence >= existing`）
- 重新触发对该 Speaker 所有 turns 的 profile 补填（异步）

---

**POST /api/v1/live/sessions/{id}/update-speaker（新增）**

场景：情况 B 用户点击「✏️ 修改」，或情况 A 识别结果有误，选择了不同档案成员。

Request：
```json
{
  "speaker_label": "Speaker_1",
  "old_profile_id": "uuid-old",
  "new_profile_id": "uuid-new",
  "confidence": 1.0,
  "method": "user_confirmed"
}
```

Response：
```json
{
  "success": true,
  "speaker_label": "Speaker_1",
  "profile_id": "uuid-new",
  "profile_name": "李总"
}
```

服务端行为：
- 覆盖写入 `live_speaker_mappings`（强制 confidence=1.0 user_confirmed）
- 异步重跑该 Speaker 的 turns 上下文补填

---

**POST /api/v1/profiles（新增，或复用现有创建档案接口）**

场景：情况 C，置信度 < 0.60，系统无法识别，用户选择「➕ 新建档案」为该 Speaker 创建新成员。

Request：
```json
{
  "name": "王总",
  "relationship": "colleague",
  "session_id": "uuid",
  "speaker_label": "Speaker_2"
}
```

Response：
```json
{
  "profile_id": "uuid-new",
  "name": "王总",
  "relationship": "colleague"
}
```

服务端行为：
1. 在 `profiles` 表创建新档案
2. 自动调用 `confirm-speaker` 逻辑：将 Speaker_2 → 新 profile_id 写入 `live_speaker_mappings`
3. 返回新 profile_id 供 iOS 后续展示

---

**POST /api/v1/live/sessions/{id}/voiceprint-intent（新增）**

场景：弹窗底部「🎙 录入声纹」按钮，用户表达愿意在后续录入声纹以提升识别率。此端点仅记录意愿，不做实际录入（声纹录入为未来功能）。

Request：
```json
{
  "speaker_label": "Speaker_1",
  "profile_id": "uuid",
  "intent": true
}
```

Response：
```json
{
  "success": true,
  "message": "声纹录入意愿已记录，后续可在档案页完成录入"
}
```

服务端行为：
- 写入 `profiles.voiceprint_intent = true`（或单独的 intents 表，待声纹功能设计时确定）
- 当前不触发任何声纹采集流程

---

**端点权限说明**

| 端点 | 鉴权方式 | 归属校验 |
|---|---|---|
| POST /confirm-speaker | Bearer JWT | `verify_session_owner()` |
| POST /update-speaker | Bearer JWT | `verify_session_owner()` |
| POST /profiles | Bearer JWT | 用户自有数据，无需 session 校验 |
| POST /voiceprint-intent | Bearer JWT | `verify_session_owner()` |

---

## 十一、录音结束后处理流程（Summary + 图片 + 技能）

> 本章描述用户点击停止录音、完成 Step 2 Speaker 确认后，客户端 UI 行为和服务端三项并行任务的完整流程。目标是复用线上录音卡片的 UI 框架，做到视觉统一。

---

### 11.1 客户端流程（iOS）

```
用户点击「停止录音」
    ↓
弹窗 Step 1：「确认停止？」（二次确认）
    ↓ 用户确认
调用 POST /live/sessions/{id}/end
    ↓
弹窗 Step 2：Speaker 确认（Section 10.4-10.5）
    ↓ 用户完成确认 / 跳过
弹窗 Step 3：「图片生成中，正在整理本次录音内容...」
    ├── 「返回列表」按钮
    └── （可选）「在这里等」（保持弹窗轮询）

用户点「返回列表」
    ↓
Moments 列表页：刚录音的卡片显示为「处理中」状态（不可点击）
    ├── 卡片头部：转圈 Loading 图标 + 「分析中」文字
    ├── 与线上普通录音卡片处理中状态完全一致
    └── iOS 开始轮询 GET /live/sessions/{id}/summary-status（每 4 秒）

轮询响应 summary_status = "completed"
    ↓
卡片变为「可点击」状态
    ├── 展示封面图（第一张生成图，若全部失败则用默认占位图）
    ├── 展示 card_title（30字）
    └── 停止 summary 轮询，继续轮询 image_status（若图片未全部完成）

点击卡片 → 进入 Detail 详情页（与线上录音详情页 UI 完全相同）
```

---

### 11.2 卡片状态机

| 状态 | 触发条件 | UI 表现 | 是否可点击 |
|---|---|---|---|
| `processing` | POST /end 调用后 | 转圈 + 「分析中」 | ❌ 不可点击 |
| `summary_ready` | Summary 完成（无论图片状态） | 显示 card_title + 封面图占位 | ✅ 可点击 |
| `completed` | Summary + 所有图片完成 | 封面图 + card_title | ✅ 可点击 |
| `image_partial` | Summary 完成 + 部分图片失败 | 已生成的图片正常展示 | ✅ 可点击 |
| `image_failed` | Summary 完成 + 所有图片失败 | 默认占位图，无图片内容 | ✅ 可点击 |
| `failed` | Summary 生成失败 | 错误提示，可重试 | ❌ 不可点击 |

**关键规则：**
- 卡片是否可点击 = `summary_status == "completed"`，与图片状态无关
- 图片生成失败逐个跳过，不阻塞整体流程
- 全部图片失败时，Detail 页图片区域展示空状态，不影响文字总结和技能展示

---

### 11.3 服务端三项并行任务

POST /live/sessions/{id}/end 触发以下三个任务并行执行：

```
POST /end
    ├── Task 1：生成 Summary（阻塞卡片可点击）
    ├── Task 2：生成图片（不阻塞，失败跳过）
    └── Task 3：技能分类整理（不阻塞，无需重新分析）
```

---

### 11.4 Task 1 - Summary 汇总生成

**逻辑：**
1. 读取本 session 所有 Segment 的 `running_context`（每个 Segment 已有 ~300 token 的分段摘要）
2. 将各 Segment 的 running_context 按时间顺序拼接
3. 调用 Gemini Flash 生成全局总结：
   - `card_title`：30 字以内，描述本次录音主题（例：「与张总的 Q3 预算讨论」）
   - `summary`：200 字，跨 Segment 的整体叙述，突出关键决策和行动项
4. 写入 `sessions.card_title` 和 `sessions.summary`
5. 更新 `sessions.summary_status = "completed"`

**Prompt 设计：**
```
以下是本次录音各阶段的摘要，请生成整体总结：

[Segment 1] {running_context_1}
[Segment 2] {running_context_2}
...

输出 JSON：
{
  "card_title": "30字以内的标题",
  "summary": "200字左右的整体总结，包含主要话题、关键决策、后续行动项"
}
```

---

### 11.5 Task 2 - 图片生成（per-Segment，全局上限 5 张）

**调用现有 `generate_scene_images()` 模块，关键参数差异：**

| 参数 | 线上普通录音 | Live 眼镜录音 |
|---|---|---|
| `transcript` | 上传音频转写结果 | 各 Segment 的 `live_turns`，转换 `is_me` 字段 |
| `speaker_mapping` | analyze_audio 输出 | `live_speaker_mappings` 表（Section 4.10） |
| `max_images` | 免费 1 / Pro 3 | 全局上限 5（跨 Segment 分配）|
| `style_key` | 用户偏好设置 | 同，读取用户偏好 |

**`is_me` 字段转换：**
```python
# live_turns 中 speaker = "user" | "other"
# 调用 generate_scene_images() 时需转换为 is_me
transcript_item["is_me"] = (turn["speaker"] == "user")
```

**跨 Segment 5 张配额分配策略：**

```
Step 1：场景提取阶段
  对每个 Segment，调用 Gemini 提取候选场景列表（不限数量）
  每个候选场景包含：
    - scene_description: 场景描述
    - importance_score: 重要度 0-10
    - segment_id: 来源 Segment
    - speakers: 涉及的 Speaker 列表

Step 2：全局裁选
  汇总所有 Segment 的候选场景
  调用 Gemini Flash：
    "以下是本次录音各阶段的场景列表，从中选出最重要、最有画面感的5个（若总数≤5则全选），
    去除重复或相似度高的场景，优先保留有人物互动的场景。"
  输出：最多 5 个场景的有序列表

Step 3：逐一生成图片
  对筛选出的场景，依次调用 generate_scene_images()
  每个场景生成 1 张图片
  生成失败则跳过（记录 error，不重试，不阻塞）
  成功后写入 R2 并更新 live_panel_batches.image_urls[]

封面图：第一张成功生成的图片（写入 sessions.cover_image_url）
```

---

### 11.6 Task 3 - 技能分类展示

> **不重新分析**：实时录音阶段每条 turn 已完成技能匹配，此阶段只做分类整理。

**逻辑：**
1. 从 `live_turns` 读取本 session 所有带 `matched_skills` 的记录（已在实时阶段写入）
2. 按 `segment_id` 分组，每个 Segment 对应一个「场景」
3. 同一 Segment 内对相同技能去重（保留出现频次最高的一次）
4. 按线上技能匹配区域的展示格式写入 `sessions.skill_results`：
   ```json
   {
     "scenes": [
       {
         "segment_id": "uuid-1",
         "scene_title": "与张总的预算讨论",   // 取该 Segment 的 running_context 首句
         "skills": [
           {"skill_id": "uuid", "skill_name": "预算谈判", "category": "沟通"},
           {"skill_id": "uuid", "skill_name": "向上管理", "category": "职场"}
         ]
       },
       {
         "segment_id": "uuid-2",
         "scene_title": "与同事的方案讨论",
         "skills": [...]
       }
     ]
   }
   ```
5. 更新 `sessions.skills_status = "completed"`

**Detail 页展示**：与线上录音 Detail 页技能区域完全相同的 UI，按场景（Segment）分组展示技能卡片。

---

### 11.7 轮询接口更新（GET /summary-status 响应扩展）

```json
{
  "summary_status": "completed",       // processing | completed | failed
  "image_status": "processing",        // processing | partial | completed | failed
  "skills_status": "completed",        // processing | completed
  "card_title": "与张总的Q3预算讨论",
  "summary": "本次对话围绕Q3预算方案展开...",
  "cover_image_url": "https://cdn.../first_image.png",   // null 若尚未生成
  "total_images_expected": 4,          // 筛选后预期生成数
  "total_images_completed": 2,         // 已成功生成数
  "total_images_failed": 0             // 已失败数
}
```

**iOS 轮询策略：**
- 轮询间隔：4 秒
- 停止条件：`summary_status != "processing"` AND `image_status != "processing"`
- `summary_status = "completed"` 时立即刷新卡片为可点击状态（不等图片）
- `image_status = "completed" | "partial" | "failed"` 时更新封面图并停止轮询

---

## 十二、长录音上下文管理：三层架构 + Segment 分段

> 解决问题：用户连续录音 3-5 小时，跨越多个物理场景（和老板开会 → 家人来电 → 同事讨论），如何保证实时建议的上下文准确、不失真、不爆炸。

---

### 12.1 问题本质

```
错误方案（全局累积摘要）：
  Turn 105 快速建议输入 =
    "老板说预算300万（Turn5）+ 家人叫回家吃饭（Turn15）+ 同事说方案有问题（Turn30）..."
  → 上下文有了，全是噪音

根因：
  5小时录音不是一个连续上下文，是多段独立对话的拼接
  不同场景之间的内容对当前建议毫无帮助
```

**核心原则：上下文不按时间积累，按"当前这段对话"范围构建。**

---

### 12.2 三层上下文架构

快速路径每次分析时，Prompt 由三层叠加构成，总量恒定 ~1150 token，与录音时长无关：

```
┌──────────────────────────────────────────────────────────┐
│               快速路径 Prompt 构成（永远恒定）             │
├──────────────────────────────────────────────────────────┤
│                                                           │
│  Layer 1  最近 8 turn（实时）                  ~400 token │
│  ─────────────────────────────────────────────────────── │
│  来源：Gemini Live 滚动窗口                               │
│  解决：刚才说了什么                                       │
│  更新：每个 turn 后自动滚动                               │
│                                                           │
├──────────────────────────────────────────────────────────┤
│                                                           │
│  Layer 2  当前 Segment 摘要（固定大小）        ~300 token │
│  ─────────────────────────────────────────────────────── │
│  来源：live_segments.running_context                       │
│  解决：这段对话讲了什么，有哪些决定和未解决的张力          │
│  更新：每 10 turn 触发一次"改写"（不是追加，是重写压缩）   │
│  重置：检测到 Segment 边界时清空，新段从空白开始           │
│  大小：硬性上限 300 token，无论对话多长始终恒定            │
│                                                           │
├──────────────────────────────────────────────────────────┤
│                                                           │
│  Layer 3A  人物基础档案（始终加载）              每人 ~80 token │
│  ──────────────────────────────────────────────────────────── │
│  来源：kg_persons + kg_skills（零改造，完全复用）              │
│  内容：亲密度、摩擦度、沟通风格、有效技能                      │
│  加载：SpeakerMapping 确认 profile_id 后立即加载               │
│  生命周期：整个 Segment 期间固定不变                           │
│  上限：最多 3 人 × 80 token = 240 token                       │
│                                                                │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  Layer 3B  历史事件（按需触发，缓存复用）          ~120 token  │
│  ──────────────────────────────────────────────────────────── │
│  来源：kg_events（只查当前 Segment 涉及人物的事件）            │
│  触发：每 turn 异步 LLM 判断是否引用历史（不阻塞快速路径）     │
│  查询：profile_id 过滤 + 关键词 ILIKE，排序取 Top 2 事件      │
│  缓存：命中后全 Segment 复用；新话题自动覆盖；                 │
│        连续 20 turns 无触发自动清空                            │
│  上限：2 条事件 × 60 token = 120 token                        │
│                                                                │
│  示例输出（3A + 3B 合并）：                                    │
│  "【张总】上司 亲密度7 摩擦3 | 有效技能：先讲ROI再谈资源      │
│   [3B] 事件[05-17]：Q3需求文档待审批（按需加载）"             │
│                                                                │
└────────────────────────────────────────────────────────────────┘
总计：~400 + 300 + 240 + 120 = 1060 token（有 3B 时最多 1150，无 3B 时 940）
→ 详细设计见 12.9
```

**Layer 3 与线上 AI 助手的差异（仅查询入口不同）：**

```python
# AI 助手（现有）：用户打字时文字匹配人名
mentioned = [p for p in all_persons if p.name in user_message]

# Live Mode（新）：声纹/点名识别后按 profile_id 直接查
persons = await db.execute(
    select(KgPerson)
    .where(KgPerson.profile_id.in_(confirmed_profile_ids))
)
# 拼装逻辑完全复用 _format_person_block()
```

---

### 12.3 Segment 分段机制

#### Segment 定义

**一个 Segment = 一段逻辑独立的对话。**

```
5小时录音中的 Segment 划分示例：

Segment #1（Turn 1-10）：  和老板谈预算
Segment #2（Turn 11-20）： 家人来电
Segment #3（Turn 21-70）： 和同事开会（长）
Segment #4（Turn 71-80）： 接了陌生电话
Segment #5（Turn 81-120）：继续同事会议（Segment #3 的续接）
```

#### 边界检测（自动）

| 信号 | 触发条件 | 可靠性 | 处理 |
|---|---|---|---|
| 静音检测 | 无语音 > 2 分钟 | 高 | 自动关闭当前 Segment |
| 说话人集合变化 | 全新声纹组合出现 | 高 | 自动新建 Segment |
| App 后台 | 锁屏或切后台 > 5 分钟 | 中 | 关闭 Segment，唤醒时询问 |
| HFP 断连重连 | 眼镜摘下再戴上 | 中 | 同上 |
| 用户手动标记 | 点击"新对话"按钮 | 确定 | 立即新建 Segment |

#### Resume vs 新建（关键判断逻辑）

```
用户唤醒 App（锁屏 40 分钟后）
         │
         ▼
    检测上次 Segment 的说话人集合
         │
    ┌────┴────────────────────────┐
    │                              │
说话人集合相似                  说话人全部陌生
    │                              │
    ▼                              ▼
弹出提示：                    直接新建 Segment #N
"继续之前的对话？              Layer 2 从空白开始
 （40分钟前 · 预算讨论）"
[继续] [新对话]
    │
[继续]：恢复 Segment #3 的
        running_context，
        turn_index 接续
[新对话]：新建 Segment #5
```

#### Segment #3 与 Segment #5 的关系（同一会议中断续接）

```
Segment #3（Turn 21-70）：午饭前的会议
  → 摘要："Q3方案，张总倾向保守，预算分歧未解决"
  → 用户去吃午饭（锁屏 60 分钟）

Segment #5（Turn 81-120）：午饭后续会
  → 用户选 [继续] → parent_segment_id = Segment #3
  → 载入 Segment #3 的摘要作为初始 running_context
  → 会议记忆无缝延续
```

---

### 12.4 running_context 改写机制（防止 Layer 2 增长）

```
每 10 turn 触发（与异步路径同步触发）：

输入：
  · 当前 Segment 的全部 turns（文字）
  · 旧 running_context（上一版）

Gemini 任务（轻量，1次调用，与策略生成合并）：
  "基于以下对话，输出一段不超过 300 token 的摘要，
   重点保留：关键决策、未解决分歧、情绪转折点、
   人物立场变化。旧的细节可以归并压缩。"

输出：
  新 running_context（≤300 token）
  → 覆写 live_segments.running_context（不追加）

效果：
  对话第 10 turn：300 token
  对话第 50 turn：还是 300 token（早期细节已压缩归并）
  对话第 200 turn：还是 300 token（只保留最重要的脉络）
```

---

### 12.5 数据库变更

**新增表：live_segments**

```sql
CREATE TABLE live_segments (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id       UUID REFERENCES sessions(id) ON DELETE CASCADE,
    segment_index    INTEGER NOT NULL,         -- 第几段，从 1 开始
    start_turn_index INTEGER NOT NULL,
    end_turn_index   INTEGER DEFAULT NULL,     -- NULL = 当前活跃段
    running_context  JSONB DEFAULT NULL,       -- 固定大小改写摘要（≤300 token）
    detected_topic   VARCHAR(200) DEFAULT NULL,-- 话题标签，如"预算讨论/家庭通话"
    speaker_ids      UUID[] DEFAULT NULL,      -- 本段在场的 profile_id 数组
    parent_segment_id UUID REFERENCES live_segments(id) DEFAULT NULL,
    -- 续接场景：午饭后会议的 parent 是午饭前会议
    boundary_reason  VARCHAR(50) DEFAULT NULL,
    -- 'silence' | 'speaker_change' | 'background' | 'manual' | 'resume'
    status           VARCHAR(20) DEFAULT 'active'
    -- 'active' | 'closed'
);

CREATE INDEX idx_live_segments_session ON live_segments(session_id, segment_index);
```

**live_turns 关联 Segment：**

```sql
ALTER TABLE live_turns
ADD COLUMN segment_id UUID REFERENCES live_segments(id);
```

**sessions 表追加当前活跃 Segment 指针：**

```sql
ALTER TABLE sessions
ADD COLUMN active_segment_id UUID REFERENCES live_segments(id);
```

---

### 12.6 Layer 3 加载时机

```
Session 开始时：
  SpeakerMapping 全部为 unknown
  Layer 3 = 空（无 profile_id 可查）
  快速建议仍可运行（只用 Layer 1）

T=3s（点名规则触发）：
  Speaker_1 被识别为 张总（profile_id = uuid-abc）
  → 异步触发 Layer 3 加载（不阻塞快速路径）
  → _format_person_block(profile_id=uuid-abc)
  → 写入内存缓存，下次快速路径开始携带张总记忆

T=5s（声纹比对触发）：
  Speaker_1 置信度升至 0.97
  → Layer 3 已加载，无需重新查询

建议质量变化：
  Turn 1-3：通用建议（无人物记忆）
  Turn 4+：个性化建议（携带张总历史上下文）
```

---

### 12.7 记忆回写闭环

```
Live Session 整个生命周期结束后：

summarize_and_generate() 完成
         │
         ▼
B-hook：save_kg_from_transcript(
    full_transcript,          ← 全量 live_turns 合并
    confirmed_speaker_mapping ← Step 2 用户确认的身份
)
→ 更新 kg_persons（亲密度滑动平均）
→ 写入 kg_events（本次对话的事件）
→ 写入 kg_goals（本次对话暴露的目标）

C-hook：save_kg_from_skills(skill_cards)
→ 写入 kg_skills（对谁用了什么技能）

下次见到张总（录音 or Live）：
  Layer 3 自动包含本次 Live 对话的记忆
  建议质量随每次对话持续提升
```

**与普通录音模式完全相同的写入流程，Live 模式零额外基础设施。**

---

### 12.8 完整验证：5小时录音 Turn 105 的 Prompt

```
场景：Segment #3（同事会议），Turn 105

Layer 1（400 token）：Turn 98-105
  你：这个时间线能提前吗？
  张总：资源不够很难提前...
  李明：技术上可以但需要加人
  你：如果加2个人呢...
  （最近 8 turn，完整呈现当下）

Layer 2（300 token）：Segment #3 摘要（只关于这次会议）
  "Q3方案讨论。核心分歧：你希望10月交付，
   张总认为12月更稳妥（已表达3次）。
   李明立场中立，倾向支持你但担忧资源。
   预算上限300万（Turn 65 确认）。
   时间线问题是当前主要障碍，尚未解决。"
  （老板那段、家人电话：完全不在这里）

Layer 3（300 token）：张总 + 李明档案
  "【张总】上司 亲密度7 摩擦3
   事件：上月绩效讨论（正面），3月预算案被他否决
   目标：Q3达成部门KPI
   有效技能：先讲ROI再谈资源"
  "【李明】同事 亲密度8 摩擦1
   特点：技术导向，重视可行性
   有效技能：给他具体数字"

→ Gemini 基于完整上下文生成建议：
  "张总今天已经3次提到资源不足，
   直接加人数可能触发他的成本敏感点。
   建议换角度：先问李明技术上的最小资源需求，
   再用数字向张总说明 ROI。"

总 token：1150（5小时后和5分钟后完全一样）
无老板对话噪音 ✅  无家人通话噪音 ✅  张总历史记忆完整 ✅
```

---

### 12.9 Layer 3B 按需触发详细设计

> 解决问题：何时触发 3B 查询（替代死板规则）+ 查询准确性 + 缓存生命周期管理

---

#### 触发机制：每 turn 异步 LLM 判断

running_context 改写（每 10 turns）和 3B 触发检测（每 1 turn）是两个独立任务：

| 任务 | 触发频率 | 输入量 | 目的 |
|---|---|---|---|
| A：running_context 改写 | 每 10 turns | 最近 10 turns（重） | 压缩 Segment 摘要 |
| B：3B 触发检测 | **每 1 turn** | 最新 1 turn（轻，~100 token） | 判断是否引用历史 |

任务 B 与实时快速路径并行，Gemini Flash 约 150ms，对 Gemini Live 延迟零影响。

**任务 B Prompt：**

```python
FAST_TRIGGER_PROMPT = """
这句话是否引用了"过去某件具体的事"？
判断标准（满足任一即为引用）：
- 提到具体项目/文档名（"那个需求文档"、"Q3方案"）
- 提到过去约定/承诺（"上次说好的"、"之前定的"）
- 询问进展（"那件事怎么样了"、"搞定了没"）
- 明确时间引用（"上周"、"上个月"、"那天"）

说话内容："{latest_turn}"
当前3B缓存话题："{current_3b_query}"

只输出JSON：
{
  "trigger": true/false,
  "same_topic": true/false,
  "query": "检索关键词（中文≤10字）或null",
  "reason": "判断依据（调试用）"
}
"""
```

**触发决策树：**

```
每 turn 执行任务 B（~150ms，异步）
         │
    trigger = false？
         │ YES → 3B 缓存不变，TTL -1
         │
    same_topic = true？
         │ YES → 不重查，TTL 重置为 20
         │
    新话题触发
         └→ 执行任务 C（SQL 查询）→ 覆盖缓存，TTL = 20
```

---

#### 查询逻辑：三步 SQL（任务 C）

```python
async def query_3b_events(user_id, profile_ids, query_text):
    keywords = query_text.split()[:3]  # 最多3个关键词

    sql = """
    SELECT e.id, e.summary, e.created_at
    FROM kg_events e
    JOIN kg_event_persons ep ON e.id = ep.event_id
    WHERE e.user_id = :user_id
      AND ep.profile_id = ANY(:profile_ids)      -- Step1：只查当前对话涉及的人
      AND (
        e.summary ILIKE :kw1                     -- Step2：关键词文本匹配
        OR e.summary ILIKE :kw2
        OR e.summary ILIKE :kw3
      )
    ORDER BY
      (CASE WHEN e.summary ILIKE :kw1 THEN 1 ELSE 0 END +
       CASE WHEN e.summary ILIKE :kw2 THEN 1 ELSE 0 END +
       CASE WHEN e.summary ILIKE :kw3 THEN 1 ELSE 0 END) DESC,
      e.created_at DESC                          -- Step3：命中多 + 时间新优先
    LIMIT 2;
    """
```

**为什么不需要 embedding：** Step1 先按 `profile_id` 把候选从全库所有事件压缩到"当前对话涉及的人"的事件（通常 < 20 条），在如此小的集合里 ILIKE 准确率已足够。

---

#### 迟到结果注入

当任务 B/C 在 Turn N 触发，约 200ms 后完成，注入到 **Turn N+1** 的上下文：

```
Turn N：张总问"上周需求文档怎么样了"
  → Gemini 用旧 3B 缓存回答（可能不完整）
  → 同时异步：任务 B（~150ms）+ 任务 C SQL（~50ms）

Turn N+1（约 200ms 后）：
  → Gemini 上下文新增：
    ┌──────────────────────────────────────────────────┐
    │ [历史记录补充]                                    │
    │ 张总 2026-05-20：需求文档已完成初稿，            │
    │ 等待李总审批，预计本周回复                        │
    └──────────────────────────────────────────────────┘
  → Gemini 自然衔接，补充 Turn N 未覆盖的历史信息
```

现实对话中同一话题通常持续 3-5 turns，Turn N+1 的补充依然有效。

---

#### 3B 缓存生命周期（状态机）

```
状态：EMPTY（无缓存）/ ACTIVE（有缓存，TTL 计数中）

EMPTY  + 新触发             → ACTIVE（TTL=20，查SQL写缓存）
ACTIVE + 相同话题触发        → ACTIVE（TTL重置为20，不重查）
ACTIVE + 新话题触发          → ACTIVE（TTL重置为20，覆盖缓存）
ACTIVE + 连续20 turns无触发  → EMPTY（缓存过期清空）
任意状态 + Segment结束        → EMPTY（强制清空）
```

**TTL = 20 turns（约7-10分钟）的依据：**

- 够长：一个话题正常讨论 5-15 turns，不会中途过期
- 够短：话题切走后约 10 分钟内自动清除，不带无关历史噪声
- 缓存无用的最坏情况（话题只说 1 句）：静默保留 20 turns 后自动清空，仅多带约 120 token/turn，可接受

---

#### 任务时序总览

```
Turn N（任意 turn）
  ├── [实时快路径] Gemini Live 使用当前 3B 缓存（EMPTY 时不带历史）
  └── [异步 ~200ms] 任务 B：LLM 触发检测
              ├── trigger=false → 结束（TTL-1）
              ├── same_topic=true → 刷新 TTL → 结束
              └── 新话题 → 任务 C：SQL 查询 → 更新缓存（TTL=20）

Turn N+1
  └── [实时快路径] Gemini 使用已更新的 3B 缓存，回答更完整
```

---

## 十一、待确认问题

| 问题 | 状态 |
|---|---|
| HFP 后台运行（锁屏时继续接收）？ | ✅ 已确认支持：UIBackgroundModes = audio，iOS 标准方案 |
| App Store 审核是否会因 HFP 被拒？ | ✅ 已确认不会：HFP 是标准蓝牙协议，无任何 MFi 限制 |
| DAT SDK App Store 问题是否已解决？ | ❌ 未解决：苹果要求 MFi PPID，Meta 未提供，暂不采用 |
| VAD 是否需要引入 WebRTC 库？ | 先用 .voiceChat 模式（方案 A），上线后看误识别率再决定 |
| 快速建议触发频率（每 3 turn）是否合适？ | Phase 1 后根据体验调整 |
| Live session 是否计入用量限制？与普通录音分开 or 合并？ | 待确认 |
| 漫画首次出现时机（10 turn 后 or 固定时间后）？ | 待体验测试决定 |
| 说话人确认弹窗时机：结束时强制确认，还是可跳过？ | 待产品决策 |
| 多人对话（3人以上）是否需要特殊处理或提示？ | 待产品决策 |
