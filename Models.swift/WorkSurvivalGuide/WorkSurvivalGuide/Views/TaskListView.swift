//
//  TaskListView.swift
//  WorkSurvivalGuide
//
//  任务列表主视图 - 按照Figma设计稿精确实现
//

import SwiftUI

// 用于追踪滚动内容顶部在屏幕上的 Y 坐标
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 999
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next < value { value = next }
    }
}

struct TaskListView: View {
    @ObservedObject private var viewModel = TaskListViewModel.shared
    @ObservedObject private var profileVM = ProfileViewModel.shared
    @State private var showStylePicker = false
    @AppStorage("image_style") private var selectedImageStyle: String = "spider_verse"
    @State private var scrollOffset: CGFloat = 999
    @State private var toastMessage: String? = nil
    @State private var showLiveSession = false
    
    /// 是否已上滑（卡片上边缘接触到顶部区域后再切换为毛玻璃）
    /// 内容顶部 global minY < 0 表示卡片已滑入 header 下方
    private var hasScrolledUp: Bool {
        scrollOffset < 0
    }
    
    /// 顶部 Header 毛玻璃背景（与卡片文字蒙层一致：ultraThinMaterial + black 0.25）
    @ViewBuilder
    private var headerFrostedGlassBackground: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(
                Color.black.opacity(0.25)
            )
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            // 主内容区（全屏，滚动时内容可从 Header 下方通过）
            VStack(spacing: 0) {
                if viewModel.isLoading && viewModel.tasks.isEmpty {
                    Spacer()
                    ProgressView("Loading...")
                        .tint(AppColors.headerText)
                    Spacer()
                } else if let errorMsg = viewModel.errorMessage, viewModel.tasks.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 50))
                            .foregroundColor(AppColors.secondaryText)
                        Text("Unable to load")
                            .font(AppFonts.cardTitle)
                            .foregroundColor(AppColors.secondaryText)
                        Text(errorMsg)
                            .font(AppFonts.time)
                            .foregroundColor(AppColors.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button(action: { viewModel.refreshTasks() }) {
                            Text("Retry")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 10)
                                .background(Color.blue.opacity(0.8))
                                .cornerRadius(10)
                        }
                    }
                    Spacer()
                } else if viewModel.tasks.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "mic.slash")
                            .font(.system(size: 50))
                            .foregroundColor(AppColors.secondaryText)
                        Text("No recordings yet")
                            .font(AppFonts.cardTitle)
                            .foregroundColor(AppColors.secondaryText)
                        Text("Tap the button below to start recording")
                            .font(AppFonts.time)
                            .foregroundColor(AppColors.secondaryText)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            // 按天分组显示
                            ForEach(Array(viewModel.groupedTasks.keys.sorted(by: >)), id: \.self) { dateKey in
                                VStack(alignment: .leading, spacing: 12) {
                                    // 日期分组标题
                                    Text(viewModel.groupTitle(for: dateKey))
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundColor(AppColors.headerText.opacity(0.7))
                                        .padding(.horizontal, 4)
                                    
                                    // 单列布局
                                    VStack(spacing: 12) {
                                        ForEach(viewModel.groupedTasks[dateKey] ?? []) { task in
                                            TaskCardRow(task: task)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 50) // 与 Header 高度匹配
                        .padding(.bottom, 100) // 为底部悬浮按钮留出空间
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ScrollOffsetPreferenceKey.self,
                                    value: geo.frame(in: .global).minY
                                )
                            }
                        )
                    }
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                        scrollOffset = value
                    }
                    .refreshable {
                        await viewModel.refreshTasksAsync()
                    }
                }
            }
            
            // 底部 Toast（录音太短提示）
            if let msg = toastMessage {
                Text(msg)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.78))
                    .cornerRadius(22)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 120)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(99)
            }

            // 顶部 Header 覆盖层（使用与 BottomNavView 相同参数的毛玻璃）
            HStack(alignment: .center, spacing: 0) {
                Text("Moments")
                    .font(AppFonts.headerTitle)
                    .foregroundColor(AppColors.headerText)
                
                Spacer()

                // Live 录音按钮（电话图标）
                Button(action: { showLiveSession = true }) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(AppColors.headerText)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)

                Button(action: {
                    showStylePicker = true
                    if TourManager.shared.currentStep == .styleButton {
                        TourManager.shared.advance()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: 16, weight: .medium))
                        Text("Style")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(AppColors.headerText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tourHighlight(.styleButton)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)  // 顶部高度约 52pt（8+36+8，不含状态栏）
            .background(
                Group {
                    if hasScrolledUp {
                        headerFrostedGlassBackground
                    } else {
                        Color.black
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: hasScrolledUp)
                .ignoresSafeArea(edges: .top)  // 延伸到状态栏下方，防止顶部漏出下层卡片
            )
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear {
            if !viewModel.hasLoaded && !viewModel.isLoading {
                viewModel.loadTasks()
            }
            // 首次出现时加载（load() 内部有 loaded guard，已加载则跳过，不 reset）
            if profileVM.selfEmojiType == "self" {
                Task { await SelfEmojiURLCache.shared.load() }
            }
        }
        .onChange(of: profileVM.selfEmojiType) { newType in
            // 只有 style 真正改变时才 reset + reload
            if newType == "self" {
                SelfEmojiURLCache.shared.reset()
                Task { await SelfEmojiURLCache.shared.load() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TaskUploaded"))) { _ in
            viewModel.refreshTasks()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NewTaskCreated"))) { notification in
            if let task = notification.object as? TaskItem {
                viewModel.addNewTask(task)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TaskAnalysisCompleted"))) { notification in
            if let task = notification.object as? TaskItem {
                print("📢 [TaskListView] 收到 TaskAnalysisCompleted: id=\(task.id), status=\(task.status)")
                viewModel.updateTask(task)
            } else {
                print("⚠️ [TaskListView] TaskAnalysisCompleted 类型转换失败，object=\(String(describing: notification.object))")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TaskStatusUpdated"))) { notification in
            if let task = notification.object as? TaskItem {
                viewModel.updateTaskStatus(task)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TaskDeleted"))) { notification in
            if let taskId = notification.object as? String {
                viewModel.deleteTask(taskId: taskId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ChatSessionClosed"))) { notification in
            guard let sessionId = notification.object as? String else { return }
            let mood = notification.userInfo?["mood"] as? String
            if let idx = viewModel.tasks.firstIndex(where: { $0.id == sessionId }) {
                let cur = viewModel.tasks[idx]
                let updated = TaskItem(
                    id: cur.id, title: cur.title, startTime: cur.startTime,
                    endTime: cur.endTime, duration: cur.duration, tags: cur.tags,
                    status: .archived, emotionScore: cur.emotionScore,
                    speakerCount: cur.speakerCount, summary: cur.summary,
                    cardTitle: cur.cardTitle, coverImageUrl: cur.coverImageUrl,
                    sessionType: cur.sessionType, coverType: cur.coverType,
                    finalizeStatus: "pending", emotionMood: mood
                )
                viewModel.updateTask(updated)
            }
            // 刷新列表：立即 + 5s + 15s，覆盖 finalize 完成时刻（关 Thinking 后约 2-3s，保守取 15s）
            viewModel.refreshTasks()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                viewModel.refreshTasks()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                viewModel.refreshTasks()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ChatSessionGeneratingImage"))) { notification in
            guard let sessionId = notification.object as? String else { return }
            if let idx = viewModel.tasks.firstIndex(where: { $0.id == sessionId }) {
                let cur = viewModel.tasks[idx]
                let updated = TaskItem(
                    id: cur.id, title: cur.title, startTime: cur.startTime,
                    endTime: cur.endTime, duration: cur.duration, tags: cur.tags,
                    status: .archived, emotionScore: cur.emotionScore,
                    speakerCount: cur.speakerCount, summary: cur.summary,
                    cardTitle: cur.cardTitle, coverImageUrl: nil,
                    sessionType: cur.sessionType, coverType: "generated",
                    finalizeStatus: "pending", emotionMood: cur.emotionMood
                )
                viewModel.updateTask(updated)
            }
            // 触发 loadTasks → resumePendingImagePolling，开始轮询图片状态
            viewModel.refreshTasks()
            // 15s 后再刷一次，确保 finalize 完成后 card_title / mood 能被拉取
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                viewModel.refreshTasks()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ChatSessionDeleted"))) { notification in
            guard let sessionId = notification.object as? String else { return }
            viewModel.deleteTask(taskId: sessionId)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TaskProgressUpdated"))) { notification in
            if let dict = notification.userInfo as? [String: String],
               let taskId = dict["taskId"],
               let progress = dict["progressDescription"] {
                viewModel.updateTaskProgress(taskId: taskId, progressDescription: progress)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TaskSummaryAvailable"))) { notification in
            if let taskId = notification.userInfo?["taskId"] as? String,
               let summary = notification.userInfo?["summary"] as? String {
                viewModel.updateTaskSummary(taskId: taskId, summary: summary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RecordingTooShort"))) { _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                toastMessage = "Recording too short — please record for at least 3 seconds."
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.easeInOut(duration: 0.3)) { toastMessage = nil }
            }
        }
        .sheet(isPresented: $showStylePicker) {
            ImageStylePickerSheet(selectedStyleId: $selectedImageStyle)
        }
        .fullScreenCover(isPresented: $showLiveSession) {
            LiveSessionView {
                // 完成后刷新列表（后处理已在后台运行）
                viewModel.refreshTasks()
            }
        }
    }
}

// 任务卡片行：左滑 200pt 漏出删除按钮，点击进入详情，互不冲突
//
// 关键设计：SwiftUI 的 .offset() 只移动视觉，不移动 hit-testing 区域。
// 因此卡片偏移后，其原始 hit 区域仍覆盖右侧删除按钮，导致按钮不可点击。
// 解决方案：卡片禁用 hit-testing，用 overlay 里动态宽度的 Color.clear 区域
// 精确覆盖"可见卡片区域"，让按钮区域自然暴露给下层的 Button。
struct TaskCardRow: View {
    let task: TaskItem

    // dragOffset ∈ [-deleteWidth, 0]，负数 = 卡片向左偏移
    @State private var dragOffset: CGFloat = 0
    @State private var gestureStartOffset: CGFloat = 0
    @State private var gestureStarted: Bool = false
    @State private var isDeleting = false
    @State private var isCancelling = false
    @State private var navigateToDetail = false
    @State private var showChatSession = false

    private let deleteWidth: CGFloat = 68
    private let snapThreshold: CGFloat = 40

    /// 卡片处于处理中状态：录音上传中 / 分析中 / archived 但封面图尚未生成
    private var isProcessingCard: Bool {
        task.status == .recording || task.status == .analyzing
            || (task.status == .archived && task.coverImageUrl == nil)
    }

    var body: some View {
        ZStack(alignment: .trailing) {

            // ── 1. 删除按钮（底层，右侧固定）────────────────────────
            Button(action: performDelete) {
                VStack(spacing: 6) {
                    if isDeleting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .medium))
                        Text("Delete")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundColor(.white)
                .frame(width: deleteWidth)
                .frame(maxHeight: .infinity)
                .background(Color.blue)
                .cornerRadius(16)
            }
            .disabled(isDeleting)
            .opacity(Double(min(1.0, -dragOffset / snapThreshold)))

            // ── 2. 卡片视觉层（禁止 hit-testing，避免遮挡按钮）─────
            ZStack {
                // detail 页导航（review / live session）
                NavigationLink(
                    destination: TaskDetailView(task: task),
                    isActive: $navigateToDetail
                ) { EmptyView() }

                TaskCardView(task: task)
                    .opacity(task.isReadyToView || task.sessionType == "chat" ? 1.0 : 0.9)
            }
            .offset(x: dragOffset)
            .allowsHitTesting(false) // ← 禁止，让下层按钮可点击

        }
        .clipped()
        // ── 3. 手势层：overlay 动态覆盖"可见卡片区域"，并叠加取消按钮──
        // GeometryReader 在 overlay 内不影响父视图布局
        .overlay(
            GeometryReader { geo in
                ZStack(alignment: .topTrailing) {
                    HStack(spacing: 0) {
                        // 仅覆盖卡片可见区域（随左移缩短），暴露右侧按钮区域
                        Color.clear
                            .frame(width: max(0, geo.size.width + dragOffset))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !isDeleting else { return }
                                if dragOffset != 0 {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                        dragOffset = 0
                                    }
                                } else if task.sessionType == "chat" {
                                    let exitAction = UserDefaults.standard.string(
                                        forKey: "chat_exit_action_\(task.id)"
                                    )
                                    if exitAction == "convert" || (exitAction == nil && task.isReadyToView) {
                                        // Convert to Image / 已有封面（向前兼容）→ detail 页
                                        navigateToDetail = true
                                    } else {
                                        // Just Close / 未退出过 → 重入对话
                                        showChatSession = true
                                    }
                                } else if task.isReadyToView {
                                    navigateToDetail = true
                                }
                            }
                        Spacer(minLength: 0)
                    }

                    // 取消按钮：仅在处理中且未左滑时显示
                    if isProcessingCard && dragOffset == 0 {
                        Button(action: performCancel) {
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.5))
                                    .frame(width: 30, height: 30)
                                if isCancelling {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.65)
                                } else {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isCancelling)
                        .padding(.top, 10)
                        .padding(.trailing, 10)
                    }
                }
            }
        )
        // ── 4. 横向拖拽手势（simultaneousGesture 不阻塞 ScrollView 垂直滚动）────
        .simultaneousGesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .local)
                .onChanged { value in
                    guard !isDeleting else { return }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if !gestureStarted {
                        // 必须向左 + 水平分量至少是垂直分量的 3 倍，才激活左滑删除
                        guard dx < 0, abs(dx) > abs(dy) * 3.0 else { return }
                        gestureStarted = true
                        gestureStartOffset = dragOffset
                    }
                    dragOffset = min(0, max(-deleteWidth, gestureStartOffset + dx))
                }
                .onEnded { value in
                    gestureStarted = false
                    guard !isDeleting else { return }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard dx < 0, abs(dx) > abs(dy) * 2.0 else {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { dragOffset = 0 }
                        return
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = dragOffset < -snapThreshold ? -deleteWidth : 0
                    }
                }
        )
        .fullScreenCover(isPresented: $showChatSession) {
            ChatAIAssistantView(sessionId: task.id)
        }
    }

    private func performDelete() {
        isDeleting = true
        Task {
            do {
                try await NetworkManager.shared.deleteSession(task.id)
                await TaskListViewModel.shared.deleteTask(taskId: task.id)
            } catch {
                print("❌ [TaskCardRow] 删除录音失败: \(error)")
                await MainActor.run {
                    isDeleting = false
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { dragOffset = 0 }
                }
            }
        }
    }

    private func performCancel() {
        guard !isCancelling else { return }
        isCancelling = true
        Task {
            do {
                try await NetworkManager.shared.deleteSession(task.id)
                await TaskListViewModel.shared.cancelTask(taskId: task.id)
                // 终止 RecordingViewModel 的轮询 Task
                NotificationCenter.default.post(
                    name: NSNotification.Name("TaskPollingCancelled"),
                    object: task.id
                )
            } catch {
                print("❌ [TaskCardRow] 取消录音失败: \(error)")
                await MainActor.run { isCancelling = false }
            }
        }
    }
}

// Header视图
struct HeaderView: View {
    var isBluetoothConnected: Bool = false
    var onDeviceTap: () -> Void = {}
    
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text("碎片")
                .font(AppFonts.headerTitle)
                .foregroundColor(AppColors.headerText)
            
            Spacer()
            
            // 设备按钮（蓝牙录音）
            Button(action: onDeviceTap) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 24))
                    .foregroundColor(isBluetoothConnected ? Color.blue : AppColors.headerText)
                    .frame(width: 44, height: 44)
            }
            
            Button(action: {
                // TODO: 添加更多功能菜单
            }) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 28))
                    .foregroundColor(AppColors.headerText)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(AppColors.headerBackground)
    }
}
