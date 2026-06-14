# 前端模块文档（iOS）

## 技术栈

| 项 | 技术 |
|---|---|
| 语言 | Swift 5.9+ |
| UI 框架 | SwiftUI |
| 架构模式 | MVVM |
| 网络库 | Alamofire |
| 认证存储 | Keychain（KeychainManager） |
| 本地持久化 | `@AppStorage`（UserDefaults）、内存缓存 |
| 最低支持 | iOS 16+（部分组件需 iOS 17） |

---

## 文件结构

```
iOS_Code_Files/
├── 数据模型
│   ├── Task.swift              # TaskItem、TaskDetailResponse、DialogueItem 等
│   ├── APIResponse.swift       # 通用 APIResponse<T>
│   ├── VisualData.swift        # 策略卡片 VisualItem、StrategyItem
│   ├── Skill.swift             # 技能数据模型
│   └── SkillsRadarModels.swift # 技能雷达模型
│
├── 网络 & 认证
│   ├── NetworkManager.swift    # 所有 API 调用（Alamofire，单例）
│   ├── AuthService.swift       # 登录/注册/登出 API
│   ├── AuthManager.swift       # 登录状态管理（@Published，单例）
│   └── KeychainManager.swift   # JWT Token 存取
│
├── ViewModel（单例）
│   ├── RecordingViewModel.swift    # 录音 + 上传 + 轮询
│   ├── TaskListViewModel.swift     # 任务列表（shared 单例）
│   ├── ProfileViewModel.swift      # 档案管理（shared 单例）
│   ├── SkillsViewModel.swift       # 技能库（shared 单例）
│   ├── SkillsRadarViewModel.swift  # 技能雷达（shared 单例）
│   ├── RadarInsightViewModel.swift # 雷达洞察
│   └── WeeklyStatsViewModel.swift  # 周统计
│
├── 主视图
│   ├── ContentView.swift       # 根视图：登录判断 + TabView
│   ├── LoginView.swift         # 登录页
│   ├── RegisterView.swift      # 注册页
│   ├── OnboardingView.swift    # 首次引导（选择场景偏好）
│   └── WalkthroughView.swift   # 功能介绍走马灯
│
├── 任务模块
│   ├── TaskListView.swift      # 碎片列表（Tab 1）
│   ├── TaskCardView.swift      # 列表卡片
│   ├── TaskDetailView.swift    # 任务详情页
│   └── DialogueReviewView.swift # 对话回放
│
├── 策略 & AI 助手
│   ├── StrategyAnalysisView_Updated.swift  # 策略分析主视图
│   ├── VisualMomentCarouselView.swift       # 场景图片轮播
│   ├── SkillDetailSheet.swift               # 技能详情弹窗
│   └── AnalysisStrategyView.swift           # 旧版策略视图（兼容）
│
├── 技能模块
│   ├── SkillsView.swift            # 技能库（Tab 2）
│   ├── SkillConstellationView.swift # 星座式技能图
│   ├── SkillsRadarCardView.swift   # 能力雷达卡片
│   └── AbilityRadarView.swift      # 雷达图绘制
│
└── 工具 & 设计系统
    ├── AppFonts.swift          # 全局字体
    ├── DesignColors.swift      # 全局颜色（AppColors）
    ├── DetailCacheManager.swift # 详情 + 策略内存缓存
    └── ImageLoaderView.swift   # 异步图片加载（含 JWT 鉴权）
```

---

## 应用入口与导航

```
ContentView
  ├── [未登录] → LoginView → RegisterView
  ├── [已登录，首次] → OnboardingView → WalkthroughView
  └── [已登录] → NavigationStack
        ├── Tab 1: TaskListView（碎片/录音列表）
        │     └── TaskDetailView → StrategyAnalysisView / DialogueReviewView
        ├── Tab 2: SkillsView（技能星域）
        │     └── SkillDetailSheet
        └── Tab 3: ProfileListView（档案）
              └── ProfileEditView
```

浮动录音按钮（`RecordingButtonView`）叠加在 Tab 1 右下角，始终可见。

---

## 核心流程：录音 → 分析 → 展示

### 1. 录音阶段
```
用户按住录音按钮
  → RecordingViewModel.startRecording()
  → AudioRecorderService.startRecording()（AVAudioRecorder）
  → 立即在列表顶部插入本地卡片（status: .recording）
  → NotificationCenter.post("NewTaskCreated")
  → TaskListViewModel 收到通知，插入卡片
```

### 2. 上传阶段
```
用户松开按钮
  → RecordingViewModel.stopRecordingAndUpload()
  → 卡片状态更新为 .analyzing
  → NetworkManager.uploadAudio()（multipart/form-data，Alamofire）
  → 上传进度回调 → 卡片显示 "Uploading XX%"
  → 服务器返回 session_id
  → 删除本地临时卡片，用服务器 session_id 创建新卡片
```

### 3. 轮询阶段
```
startPollingStatus(sessionId)
  → 每 3 秒（首次 8 秒）请求 GET /sessions/{id}/status
  → 将 analysisStage 翻译为英文显示（stageDisplayText）
  → 阶段 "matching_profiles" 或 "strategy_*" 时提前拉取 summary
  → 直到 status = "archived" + analysisStage = "strategy_done"
  → 最大轮询 300 次（约 15 分钟超时）
```

**分析阶段进度文案（英文）：**

| analysisStage | 显示文案 |
|---|---|
| upload_done | Upload complete |
| transcribing | Transcribing… |
| matching_profiles | Matching profiles… |
| strategy_scene | Identifying scene… |
| strategy_matching | Matching skills… |
| strategy_matched_n | Matched N skills |
| strategy_executing | Processing skills… |
| strategy_images | Generating images… |
| strategy_done | Strategy ready |

### 4. 图片等待阶段
```
pollForImages(sessionId)
  → 每 3 秒查询 GET /sessions/{id}/image-status
  → 最多等 180 秒（60 次）
  → 图片 completed → 预拉取 StrategyAnalysis（DetailCacheManager 缓存）
  → 预下载第一张图片（ImageCacheManager 缓存）
  → NotificationCenter.post("TaskAnalysisCompleted")
  → 卡片变为可点击
```

---

## 状态管理

### NotificationCenter 事件总线

跨 ViewModel 通信全部走 `NotificationCenter`：

| 通知名 | 发送方 | 接收方 | 含义 |
|---|---|---|---|
| `NewTaskCreated` | RecordingViewModel | TaskListViewModel | 新增卡片 |
| `TaskStatusUpdated` | RecordingViewModel | TaskListViewModel | 更新卡片状态 |
| `TaskProgressUpdated` | RecordingViewModel | TaskListViewModel | 更新进度文案 |
| `TaskSummaryAvailable` | RecordingViewModel | TaskListViewModel | 提前填充 summary |
| `TaskAnalysisCompleted` | RecordingViewModel | TaskListViewModel | 分析完成，卡片可点击 |
| `TaskAnalysisFailed` | RecordingViewModel | TaskListViewModel | 分析失败 |
| `TaskDeleted` | RecordingViewModel | TaskListViewModel | 删除临时卡片 |

### 单例 ViewModel

主要 ViewModel 均为 `static let shared` 单例，**登出时必须调用 `reset()`**（`AuthManager.logout()` 中统一清空）：

```swift
TaskListViewModel.shared.reset()
ProfileViewModel.shared.reset()
SkillsViewModel.shared.reset()
SkillsRadarViewModel.shared.reset()
```

---

## 网络层

`NetworkManager.swift` 封装所有接口，关键设计：

- **读写分离**：`writeBaseURL`（GCP 新加坡）始终用于写操作；`readBaseURL`（可选北京节点）用于读操作，由 `AppConfig.shared.useBeijingRead` 控制
- **Mock 模式**：`AppConfig.shared.useMockData = true` 时走 `MockNetworkService`，本地直接调 Gemini API，无需后端
- **Token 管理**：所有请求从 `KeychainManager.shared.getToken()` 取 JWT，加到 `Authorization: Bearer` 头
- **图片请求**：`ImageLoaderView` 自带 JWT 鉴权头（`/api/v1/images/` 接口需要）

---

## 缓存策略

| 缓存类 | 缓存内容 | 时机 |
|---|---|---|
| `DetailCacheManager` | `TaskDetailResponse` + `StrategyAnalysis` | 分析完成后预加载；列表页补充 summary 时 |
| `ImageCacheManager` | `UIImage`（内存） | 分析完成后预下载第一张场景图 |

进入详情页时优先读缓存，无缓存才发请求（零等待体验）。

---

## 设计系统

- **字体**：`AppFonts.swift` 统一定义（`cardTitle`、`body` 等）
- **颜色**：`DesignColors.swift` / `AppColors`（`background`、`cardBackground`、`primaryText`、`border` 等）
- **背景**：`PaperGridBackground`（信纸网格底纹）贯穿全 App
- **阴影风格**：卡片用 `shadow(color: border, radius: 0, x: 3, y: 3)`（平移阴影，复古感）

---

## AI 助手 SSE 接入

`NetworkManager` 中 AI 助手接口使用 `URLSession` 原生处理 SSE（非 Alamofire），按行解析 `data: {...}` 事件：

```
meta → 初始化技能名、记忆状态
token → 逐字追加到气泡文本
suggestions → 展示 4 个快捷追问按钮
meme → 展示 KLIPY GIF（情感梗图）
done → 关闭 loading，启用输入框
```

---

## 关键配置（AppConfig）

```swift
AppConfig.shared.useMockData      // true=Mock模式，false=真实API
AppConfig.shared.useBeijingRead   // true=读接口走北京节点
AppConfig.shared.writeBaseURL     // 生产写地址（GCP新加坡）
AppConfig.shared.readBaseURL      // 读地址（北京或新加坡）
```
