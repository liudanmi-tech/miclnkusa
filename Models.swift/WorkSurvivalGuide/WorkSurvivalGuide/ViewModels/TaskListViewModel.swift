//
//  TaskListViewModel.swift
//  WorkSurvivalGuide
//
//  任务列表 ViewModel
//

import Foundation
import Combine

class TaskListViewModel: ObservableObject {
    static let shared = TaskListViewModel()

    @Published var tasks: [TaskItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// true = 上一条录音仍在分析中，禁止开始新录音
    @Published var isProcessing = false

    private let networkManager = NetworkManager.shared
    private(set) var hasLoaded = false // 记录是否已经加载过数据（服务器成功响应后置 true）
    private var loadingTask: Task<Void, Never>? // 当前加载任务，用于取消重复请求

    // MARK: - 并发锁（单条录音分析完成/失败前，禁止新录音）
    private var processingSessionId: String?
    private var processingTimeoutTask: Task<Void, Never>?
    private let processingTimeoutSeconds: Double = 360 // 6 分钟

    /// 标记某 session 进入处理中，启动 6 分钟超时兜底
    func setProcessing(sessionId: String, startedAt: Date = Date()) {
        processingSessionId = sessionId
        isProcessing = true
        processingTimeoutTask?.cancel()
        // 计算剩余超时（场景C：App 重启时剩余时间可能已缩短）
        let elapsed  = max(0, Date().timeIntervalSince(startedAt))
        let remaining = max(5, processingTimeoutSeconds - elapsed)
        processingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.clearProcessing()
                print("⏰ [TaskListViewModel] 分析超时（6min），自动解锁录音按钮 sessionId=\(sessionId)")
            }
        }
        print("🔒 [TaskListViewModel] 录音锁定 sessionId=\(sessionId) 剩余超时=\(Int(remaining))s")
    }

    /// 解除锁定；传入 sessionId 时仅当匹配才解锁（防止旧通知误解锁新 session）
    func clearProcessing(for sessionId: String? = nil) {
        if let sid = sessionId, processingSessionId != sid { return }
        processingTimeoutTask?.cancel()
        processingTimeoutTask = nil
        processingSessionId = nil
        isProcessing = false
        print("🔓 [TaskListViewModel] 录音解锁")
    }

    /// 加载/刷新后调用：根据 tasks 状态同步 isProcessing（处理 App 重启场景）
    private func reconcileProcessingState() {
        let cutoff = Date().addingTimeInterval(-processingTimeoutSeconds)
        // 找最近的非终态 session（6 分钟内）；chat session 不占用录音锁
        let active = tasks.first {
            ![TaskStatus.archived, .completed, .failed, .burned, .chatActive].contains($0.status)
            && $0.startTime > cutoff
        }
        if let active {
            if processingSessionId != active.id {
                setProcessing(sessionId: active.id, startedAt: active.startTime)
            }
        } else if isProcessing {
            // 没有进行中的 session → 解锁（包含已超时的卡死场景）
            clearProcessing()
        }
    }

    // MARK: - 磁盘缓存
    private static var cacheFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tasks_cache.json")
    }

    private func loadFromCache() {
        guard let url = Self.cacheFileURL,
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode([TaskItem].self, from: data) else { return }
        tasks = cached
        print("✅ [TaskListViewModel] 磁盘缓存加载完成，任务数量: \(cached.count)")
        reconcileProcessingState() // 场景C：冷启动后根据缓存恢复锁状态
    }

    private func saveToCache() {
        guard let url = Self.cacheFileURL,
              let data = try? JSONEncoder().encode(tasks) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func clearCache() {
        if let url = Self.cacheFileURL { try? FileManager.default.removeItem(at: url) }
    }

    private init() {
        loadFromCache() // 冷启动立即读取磁盘缓存，无需等待网络
        // 注意：不在 init() 里调用 loadTasks()，由 TaskListView.onAppear 负责触发
        // 避免 init() + onAppear 双重调用导致后者取消前者请求（共 22 秒以上）
    }
    
    // 加载任务列表
    func loadTasks(date: Date? = nil, forceRefresh: Bool = false) {
        // 如果已经有数据且不在加载中，且不是强制刷新，则跳过
        if !forceRefresh && !tasks.isEmpty && !isLoading && hasLoaded {
            print("✅ [TaskListViewModel] 数据已存在，跳过加载")
            return
        }
        
        // 如果正在加载中，取消之前的任务
        if isLoading {
            print("⚠️ [TaskListViewModel] 正在加载中，跳过重复请求")
            loadingTask?.cancel()
        }
        
        isLoading = true
        errorMessage = nil
        
        loadingTask = Task {
            let loadStartTime = Date()
            print("⏱️ [TaskListViewModel] ========== 开始加载任务列表 ==========")
            print("⏱️ [TaskListViewModel] 开始时间: \(loadStartTime)")
            
            do {
                let response = try await self.networkManager.getTaskList(date: date)
                let networkTime = Date().timeIntervalSince(loadStartTime)
                print("⏱️ [TaskListViewModel] 网络请求完成，耗时: \(String(format: "%.3f", networkTime))秒")
                
                // 检查任务是否被取消
                guard !Task.isCancelled else {
                    print("⚠️ [TaskListViewModel] 加载任务已取消")
                    return
                }
                
                let mergeStartTime = Date()
                await MainActor.run {
                    // 合并任务列表，保留已有任务的 summary 字段（如果 API 返回的任务没有 summary）
                    self.tasks = self.mergeTasks(apiTasks: response.sessions)
                    let mergeTime = Date().timeIntervalSince(mergeStartTime)
                    print("⏱️ [TaskListViewModel] 数据合并完成，耗时: \(String(format: "%.3f", mergeTime))秒")
                    
                    self.isLoading = false
                    self.hasLoaded = true
                    self.saveToCache() // 持久化到磁盘，供下次冷启动使用
                    self.reconcileProcessingState() // 网络数据到位后再校准一次锁状态

                    let totalTime = Date().timeIntervalSince(loadStartTime)
                    print("⏱️ [TaskListViewModel] ========== 任务列表加载完成 ==========")
                    print("⏱️ [TaskListViewModel] 总耗时: \(String(format: "%.3f", totalTime))秒")
                    print("⏱️ [TaskListViewModel] 任务数量: \(self.tasks.count)")
                    
                    // 对于archived状态且没有summary的任务，异步获取详情补充summary（不阻塞主流程）
                    // 延迟执行，避免影响首次加载速度
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 延迟0.5秒
                        self.loadMissingSummaries()
                        self.resumePendingImagePolling()
                    }
                }
            } catch {
                // 检查任务是否被取消
                guard !Task.isCancelled else {
                    print("⚠️ [TaskListViewModel] 加载任务已取消")
                    return
                }
                
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    print("加载任务失败: \(error)")
                }
            }
        }
    }
    
    // 登出时清空缓存，防止切换账号后看到旧用户数据
    func reset() {
        loadingTask?.cancel()
        tasks = []
        hasLoaded = false
        isLoading = false
        errorMessage = nil
        clearCache()
        clearProcessing() // 登出时同步解锁
    }

    // 刷新任务列表（强制刷新）
    func refreshTasks() {
        loadTasks(forceRefresh: true)
    }
    
    // 异步刷新任务列表（用于 refreshable）
    func refreshTasksAsync() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        
        do {
            let response = try await networkManager.getTaskList(date: nil)
            await MainActor.run {
                // 合并任务列表，保留已有任务的 summary 字段（如果 API 返回的任务没有 summary）
                self.tasks = self.mergeTasks(apiTasks: response.sessions)
                self.isLoading = false
                self.saveToCache()

                // 对于archived状态且没有summary的任务，异步获取详情补充summary
                self.loadMissingSummaries()
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                print("刷新任务失败: \(error)")
            }
        }
    }
    
    // 添加新任务（用于录制后创建）
    func addNewTask(_ task: TaskItem) {
        print("📝 [TaskListViewModel] ========== 添加新任务 ==========")
        print("📝 [TaskListViewModel] 任务ID: \(task.id)")
        print("📝 [TaskListViewModel] 任务标题: \(task.title)")
        print("📝 [TaskListViewModel] 任务状态: \(task.status)")
        print("📝 [TaskListViewModel] 当前任务数量: \(tasks.count)")

        tasks.insert(task, at: 0) // 添加到列表顶部
        // chat session 不占用录音锁，只有真实录音任务才锁定
        if task.sessionType != "chat" {
            setProcessing(sessionId: task.id)
        }

        print("✅ [TaskListViewModel] 任务已添加，当前任务数量: \(tasks.count)")
    }
    
    // 更新任务（用于分析完成后更新）
    func updateTask(_ updatedTask: TaskItem) {
        print("🔄 [TaskListViewModel] ========== 更新任务 ==========")
        print("🔄 [TaskListViewModel] 任务ID: \(updatedTask.id)")
        print("🔄 [TaskListViewModel] 任务标题: \(updatedTask.title)")
        print("🔄 [TaskListViewModel] 任务状态: \(updatedTask.status)")
        print("🔄 [TaskListViewModel] 当前列表中的任务IDs: \(tasks.map { $0.id })")

        if let index = tasks.firstIndex(where: { $0.id == updatedTask.id }) {
            print("✅ [TaskListViewModel] 找到任务，索引: \(index)")
            tasks[index] = updatedTask
            print("✅ [TaskListViewModel] 任务已更新")
        } else {
            print("⚠️ [TaskListViewModel] 未找到要更新的任务，直接插入到列表顶部作为兜底")
            tasks.insert(updatedTask, at: 0)
            print("✅ [TaskListViewModel] 任务已插入到列表顶部")
        }
        // 终态（完成/失败）→ 解锁录音按钮；chat session 不持有锁，无需解锁
        if [TaskStatus.archived, .completed, .failed, .burned].contains(updatedTask.status) {
            clearProcessing(for: updatedTask.id)
        }
    }

    // 更新任务状态（用于录音停止后更新状态）
    func updateTaskStatus(_ updatedTask: TaskItem) {
        print("🔄 [TaskListViewModel] ========== 更新任务状态 ==========")
        print("🔄 [TaskListViewModel] 任务ID: \(updatedTask.id)")
        print("🔄 [TaskListViewModel] 任务状态: \(updatedTask.status)")

        if let index = tasks.firstIndex(where: { $0.id == updatedTask.id }) {
            print("✅ [TaskListViewModel] 找到任务，索引: \(index)")
            tasks[index] = updatedTask
            print("✅ [TaskListViewModel] 任务状态已更新")
        } else {
            print("⚠️ [TaskListViewModel] 未找到要更新的任务")
        }
        // 终态 → 解锁
        if [TaskStatus.archived, .completed, .failed, .burned].contains(updatedTask.status) {
            clearProcessing(for: updatedTask.id)
        }
    }

    // 更新任务进度文案（用于卡片内显示 12 个进度节点）
    func updateTaskProgress(taskId: String, progressDescription: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let current = tasks[index]
        let updated = TaskItem(
            id: current.id,
            title: current.title,
            startTime: current.startTime,
            endTime: current.endTime,
            duration: current.duration,
            tags: current.tags,
            status: current.status,
            emotionScore: current.emotionScore,
            speakerCount: current.speakerCount,
            summary: current.summary,
            cardTitle: current.cardTitle,
            coverImageUrl: current.coverImageUrl,
            sessionType: current.sessionType,
            coverType: current.coverType,
            finalizeStatus: current.finalizeStatus,
            emotionMood: current.emotionMood,
            progressDescription: progressDescription
        )
        tasks[index] = updated
    }
    
    // 更新任务 summary（7-12 步时提前获取，供卡片滚动展示）
    func updateTaskSummary(taskId: String, summary: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let current = tasks[index]
        let updated = TaskItem(
            id: current.id,
            title: current.title,
            startTime: current.startTime,
            endTime: current.endTime,
            duration: current.duration,
            tags: current.tags,
            status: current.status,
            emotionScore: current.emotionScore,
            speakerCount: current.speakerCount,
            summary: summary,
            cardTitle: current.cardTitle,
            coverImageUrl: current.coverImageUrl,
            sessionType: current.sessionType,
            coverType: current.coverType,
            finalizeStatus: current.finalizeStatus,
            emotionMood: current.emotionMood,
            progressDescription: current.progressDescription
        )
        tasks[index] = updated
    }
    
    // 删除任务（本地移除 + 更新磁盘缓存）
    @MainActor
    func deleteTask(taskId: String) {
        if let index = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks.remove(at: index)
            saveToCache()
            print("✅ [TaskListViewModel] 录音已从列表删除 id=\(taskId) 剩余=\(tasks.count)")
        } else {
            print("⚠️ [TaskListViewModel] 未找到要删除的录音 id=\(taskId)")
        }
    }

    // 取消处理中的录音：解锁录音按钮 + 从列表移除
    @MainActor
    func cancelTask(taskId: String) {
        clearProcessing(for: taskId)
        deleteTask(taskId: taskId)
        print("🚫 [TaskListViewModel] 录音已取消 id=\(taskId)")
    }
    
    // 按天分组任务
    var groupedTasks: [String: [TaskItem]] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return Dictionary(grouping: tasks) { (task: TaskItem) -> String in
            formatter.string(from: task.startTime)
        }
    }
    
    // 获取分组标题
    func groupTitle(for dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        
        guard let date = formatter.date(from: dateString) else {
            return dateString
        }
        
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: date)
        }
    }
    
    // 合并任务列表，保留已有任务的 summary、progressDescription、coverType 字段
    private func mergeTasks(apiTasks: [TaskItem]) -> [TaskItem] {
        let existingSummaries = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in
            task.summary != nil ? (task.id, task.summary) : nil
        })
        let existingProgress = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in
            (task.progressDescription != nil && !(task.progressDescription?.isEmpty ?? true)) ? (task.id, task.progressDescription!) : nil
        })
        // coverType 是纯客户端状态（服务端不返回），必须从本地保留，否则 refreshTasks 会把
        // 刚设置的 "generated" 覆盖成 nil，导致 resumePendingImagePolling 找不到目标
        let existingCoverTypes = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in
            task.coverType != nil ? (task.id, task.coverType!) : nil
        })

        return apiTasks.map { apiTask in
            let keepSummary = (apiTask.summary == nil || apiTask.summary?.isEmpty == true) && existingSummaries[apiTask.id] != nil
            let keepProgress = apiTask.status == .analyzing && existingProgress[apiTask.id] != nil
            // 服务端不返回 cover_type，只要本地有就保留；若服务端已有 coverImageUrl 则不再需要 "generated"
            let resolvedCoverType: String? = apiTask.coverType ?? (apiTask.coverImageUrl == nil ? existingCoverTypes[apiTask.id] : nil)
            if keepSummary || keepProgress || resolvedCoverType != apiTask.coverType {
                return TaskItem(
                    id: apiTask.id,
                    title: apiTask.title,
                    startTime: apiTask.startTime,
                    endTime: apiTask.endTime,
                    duration: apiTask.duration,
                    tags: apiTask.tags,
                    status: apiTask.status,
                    emotionScore: apiTask.emotionScore,
                    speakerCount: apiTask.speakerCount,
                    summary: keepSummary ? (existingSummaries[apiTask.id].flatMap { $0 } ?? apiTask.summary) : apiTask.summary,
                    cardTitle: apiTask.cardTitle,
                    coverImageUrl: apiTask.coverImageUrl,
                    sessionType: apiTask.sessionType,
                    coverType: resolvedCoverType,
                    finalizeStatus: apiTask.finalizeStatus,
                    emotionMood: apiTask.emotionMood,
                    progressDescription: keepProgress ? existingProgress[apiTask.id] : nil
                )
            }
            return apiTask
        }
    }
    
    // 为 archived 状态、近期（15分钟内）且无封面图的任务重新轮询图片状态
    // 场景：用户在图片生成中途杀掉 app 或退后台，重新唤起后补全封面图并解锁卡片点击
    private func resumePendingImagePolling() {
        let now = Date()
        let pending = tasks.filter {
            ($0.status == .archived || $0.status == .completed)
            && $0.coverImageUrl == nil
            && now.timeIntervalSince($0.startTime) < 15 * 60
            && ($0.sessionType != "chat" || $0.coverType == "generated") // chat 只在 Convert to Image 时轮询
        }
        guard !pending.isEmpty else { return }
        print("🖼️ [TaskListViewModel] 发现 \(pending.count) 个任务图片未完成，恢复轮询...")

        Task {
            guard let authToken = KeychainManager.shared.getToken(), !authToken.isEmpty else { return }
            for task in pending {
                Task {
                    let maxAttempts = 20  // 最多等 1 分钟（20 × 3s），超时降级为 just-close 可点击状态
                    for _ in 0..<maxAttempts {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard let imgStatus = try? await self.networkManager.getImageStatus(
                            sessionId: task.id, authToken: authToken
                        ) else { continue }
                        // failed → 降级：清除 coverType，让卡片变回可点击（进入 AI chat 历史）
                        if imgStatus.status == "failed" {
                            print("❌ [TaskListViewModel] 任务 \(task.id) 图片生成失败，降级为无封面可点击状态")
                            await self.degradeToChatReentry(taskId: task.id)
                            return
                        }
                        guard imgStatus.status == "completed", imgStatus.totalScenes > 0 else { continue }

                        // 图片就绪，从 scene_images 取第一个有效 URL 作为封面
                        let baseURL = self.networkManager.getBaseURL()
                        let coverUrl = imgStatus.images.compactMap {
                            $0.getAccessibleImageURL(baseURL: baseURL)
                        }.first

                        guard let coverUrl else {
                            print("⚠️ [TaskListViewModel] 任务 \(task.id) status=completed 但无有效图片 URL，降级为无封面可点击状态")
                            await self.degradeToChatReentry(taskId: task.id)
                            return
                        }

                        await MainActor.run {
                            guard let idx = self.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                            let cur = self.tasks[idx]
                            self.tasks[idx] = TaskItem(
                                id: cur.id, title: cur.title, startTime: cur.startTime,
                                endTime: cur.endTime, duration: cur.duration, tags: cur.tags,
                                status: cur.status, emotionScore: cur.emotionScore,
                                speakerCount: cur.speakerCount, summary: cur.summary,
                                cardTitle: cur.cardTitle, coverImageUrl: coverUrl,
                                sessionType: cur.sessionType, coverType: cur.coverType,
                                finalizeStatus: cur.finalizeStatus, emotionMood: cur.emotionMood
                            )
                            self.saveToCache()
                            print("✅ [TaskListViewModel] 任务 \(task.id) 封面已补全，卡片解锁")
                        }
                        return
                    }
                    // 超时（1分钟）→ 降级：清除 coverType，让卡片变回可点击（进入 AI chat 历史）
                    print("⏰ [TaskListViewModel] 任务 \(task.id) 图片等待超时（1min），降级为无封面可点击状态")
                    await self.degradeToChatReentry(taskId: task.id)
                }
            }
        }
    }

    /// 图片生成失败或超时时，清除 coverType 使卡片恢复可点击（just-close / re-entry 状态）
    @MainActor
    private func degradeToChatReentry(taskId: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let cur = tasks[idx]
        tasks[idx] = TaskItem(
            id: cur.id, title: cur.title, startTime: cur.startTime,
            endTime: cur.endTime, duration: cur.duration, tags: cur.tags,
            status: cur.status, emotionScore: cur.emotionScore,
            speakerCount: cur.speakerCount, summary: cur.summary,
            cardTitle: cur.cardTitle, coverImageUrl: nil,
            sessionType: cur.sessionType, coverType: nil,
            finalizeStatus: cur.finalizeStatus, emotionMood: cur.emotionMood
        )
        saveToCache()
    }

    /// 并发锁：防止多次 loadTasks() 触发多个并发 loadMissingSummaries 实例
    private var isLoadingSummaries = false

    // 为archived状态且没有summary的任务异步加载summary
    private func loadMissingSummaries() {
        // 防止多次并发执行（3 次 refreshTasks 会触发 3 次）
        guard !isLoadingSummaries else {
            print("⏭️ [TaskListViewModel] loadMissingSummaries 正在运行，跳过重复调用")
            return
        }

        // chat session 的 summary 来自服务端 finalize，不通过 getTaskDetail 补充
        let tasksNeedingSummary = tasks.filter { task in
            (task.status == .archived || task.status == .completed)
            && task.sessionType != "chat"
            && (task.summary == nil || task.summary?.isEmpty == true)
        }

        guard !tasksNeedingSummary.isEmpty else { return }

        isLoadingSummaries = true
        print("🔄 [TaskListViewModel] 发现 \(tasksNeedingSummary.count) 个任务需要补充summary，开始异步加载...")

        // 使用 TaskGroup 控制并发数量，避免同时发起过多请求
        Task {
            defer {
                Task { @MainActor in self.isLoadingSummaries = false }
            }

            // 限制并发数量为5，避免过多并发请求
            let maxConcurrent = 5
            let chunks = tasksNeedingSummary.chunked(into: maxConcurrent)

            for chunk in chunks {
                await withTaskGroup(of: Void.self) { group in
                    for task in chunk {
                        group.addTask {
                            do {
                                let detail = try await self.networkManager.getTaskDetail(sessionId: task.id)

                                // 缓存详情数据，供详情页使用
                                DetailCacheManager.shared.cacheDetail(detail, for: task.id)

                                // 更新任务的summary，保留所有已有字段（避免丢失 sessionType 等关键字段）
                                await MainActor.run {
                                    if let index = self.tasks.firstIndex(where: { $0.id == task.id }) {
                                        let existing = self.tasks[index]
                                        let updatedTask = TaskItem(
                                            id: existing.id,
                                            title: existing.title,
                                            startTime: existing.startTime,
                                            endTime: existing.endTime,
                                            duration: existing.duration,
                                            tags: existing.tags,
                                            status: existing.status,
                                            emotionScore: existing.emotionScore,
                                            speakerCount: existing.speakerCount,
                                            summary: detail.summary,
                                            cardTitle: existing.cardTitle ?? detail.cardTitle,
                                            coverImageUrl: existing.coverImageUrl,
                                            sessionType: existing.sessionType,
                                            coverType: existing.coverType,
                                            finalizeStatus: existing.finalizeStatus,
                                            emotionMood: existing.emotionMood,
                                            progressDescription: existing.progressDescription
                                        )
                                        self.tasks[index] = updatedTask
                                        print("✅ [TaskListViewModel] 已为任务 \(task.id) 补充summary并缓存详情")
                                    }
                                }
                            } catch {
                                print("⚠️ [TaskListViewModel] 获取任务 \(task.id) 的summary失败: \(error)")
                            }
                        }
                    }
                }
            }
            print("✅ [TaskListViewModel] 所有summary加载完成")
        }
    }
}

// 辅助扩展：将数组分块（文件级别）
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

