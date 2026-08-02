//
//  TaskDetailView.swift
//  WorkSurvivalGuide
//
//  Moment 详情页 - 重新设计：图片轮播 + 信息卡 + 技能卡
//

import SwiftUI

struct TaskDetailView: View {
    let task: TaskItem
    @ObservedObject private var profileVM = ProfileViewModel.shared
    @ObservedObject private var emojiURLCache = SelfEmojiURLCache.shared  // 监听缓存更新，触发 moodEmojiUrl 重计算
    @State private var detail: TaskDetailResponse?
    @State private var strategyAnalysis: StrategyAnalysisResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @StateObject private var audioPlayer = SessionAudioPlayerService()
    @State private var showReportMenu = false
    @State private var reportSubmitted = false
    @State private var showSummarySheet = false
    @State private var showLiveReplaySheet = false
    @State private var strategyIsLoading = false
    @AppStorage("ai_disclaimer_shown") private var aiDisclaimerShown = false
    @State private var showAIDisclaimer = false
    @State private var showChatView = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppColors.background.ignoresSafeArea()
                PaperGridBackground().ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // ── Header ──
                        DetailHeaderView(onReportTap: {
                            withAnimation(.easeInOut(duration: 0.25)) { showReportMenu = true }
                        })
                        .padding(.horizontal, 15.99)
                        .padding(.top, 10)
                        .padding(.bottom, 14)

                        // ── Scene image carousel（全宽无边，4:5 竖版与服务端一致）──
                        let sceneImgs = strategyAnalysis?.sceneImages ?? []
                        let imgW = geometry.size.width
                        let imgH = imgW * 5.0 / 4.0   // 服务端强制裁剪 4:5
                        SceneRestoreImageCarouselView(
                            sceneImages: sceneImgs,
                            baseURL: NetworkManager.shared.getBaseURL(),
                            imageCornerRadius: 0         // 全宽贴边，不需要圆角
                        )
                        .frame(width: imgW, height: imgH)
                        .clipped()

                        // ── Info card ──
                        MomentInfoCard(
                            sceneDescription: currentSceneDescription,
                            isLive: detail?.sessionType == "live" || task.status == .completed,
                            onSummaryTap: {
                                if detail?.sessionType == "live" || task.status == .completed {
                                    showLiveReplaySheet = true
                                } else {
                                    showSummarySheet = true
                                }
                            },
                            onChatTap: task.sessionType == "chat" ? { showChatView = true } : nil,
                            audioPlayer: audioPlayer,
                            moodEmoji: moodEmoji,
                            moodEmojiUrl: moodEmojiUrl,
                            moodState: moodState,
                            startTime: task.startTime,
                            strategyIsLoading: strategyIsLoading,
                            imageURLs: strategyAnalysis?.sceneImages?.compactMap { $0.imageUrl }.filter { !$0.isEmpty } ?? []
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        // ── Skills card ──
                        if let skillCards = strategySkillCards, !skillCards.isEmpty {
                            MomentSkillsCard(
                                sceneCategoryName: primarySceneCategory,
                                skillCards: skillCards,
                                sessionId: task.id,
                                sceneImages: strategyAnalysis?.sceneImages ?? [],
                                baseURL: NetworkManager.shared.getBaseURL(),
                                onSkillTap: task.sessionType == "chat" ? { showChatView = true } : nil
                            )
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        } else if strategyIsLoading {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Analyzing skills…")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 20)
                        }

                        // Error state
                        if let errorMessage = errorMessage {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(.orange)
                                Text(errorMessage)
                                    .font(.system(size: 14, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                                Button(action: { loadAll() }) {
                                    Text("Retry")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 20).padding(.vertical, 10)
                                        .background(Color.blue).cornerRadius(8)
                                }
                            }
                            .padding(.top, 32)
                        }

                        Spacer(minLength: 40)
                    }
                    .frame(width: geometry.size.width)
                }

                // Full-screen loading overlay
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        ProgressView().scaleEffect(1.5).tint(.white)
                    }
                }

                // Report menu
                if showReportMenu {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) { showReportMenu = false }
                        }
                        .transition(.opacity)

                    ReportMenuPanel(
                        sessionId: task.id,
                        submitted: $reportSubmitted,
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.25)) { showReportMenu = false }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom))
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                loadAll()
                if !aiDisclaimerShown {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        showAIDisclaimer = true
                        aiDisclaimerShown = true
                    }
                }
            }
            .onDisappear {
                audioPlayer.stop()
            }
            .task(id: profileVM.selfEmojiType) {
                if profileVM.selfEmojiType == "self" {
                    SelfEmojiURLCache.shared.reset()
                    await SelfEmojiURLCache.shared.load()
                }
            }
            .fullScreenCover(isPresented: $showChatView) {
                ChatAIAssistantView(sessionId: task.id, isExistingSession: true)
            }
            .onChange(of: showChatView) { isPresented in
                if !isPresented {
                    // Chat 关闭后失效缓存，重新拉取策略分析（含最新生图）
                    DetailCacheManager.shared.invalidateStrategy(for: task.id)
                    loadStrategyAnalysis()
                }
            }
            .sheet(isPresented: $showSummarySheet) {
                SummarySheet(
                    summary: detail?.summary ?? task.summary,
                    dialogues: detail?.dialogues ?? []
                )
            }
            .sheet(isPresented: $showLiveReplaySheet) {
                LiveReplaySheet(
                    dialogues: detail?.dialogues ?? [],
                    skillCards: strategySkillCards ?? []
                )
            }
            .alert("About AI Content", isPresented: $showAIDisclaimer) {
                Button("Got it", role: .cancel) { }
            } message: {
                Text("Images and insights in Chattoon are generated by AI and are for personal reflection only. They may not always be accurate and are not a substitute for professional advice.")
            }
        }
    }

    // MARK: - Computed helpers

    private var currentSceneDescription: String? {
        let imgs = strategyAnalysis?.sceneImages?.filter {
            ($0.imageUrl != nil && !($0.imageUrl?.isEmpty ?? true))
            || ($0.imageBase64 != nil && !($0.imageBase64?.isEmpty ?? true))
        } ?? []
        // Show first valid scene description
        let desc = imgs.first?.sceneDescription ?? ""
        return desc.isEmpty ? nil : desc
    }

    private var moodEmoji: String? {
        strategyAnalysis?.skillCards?
            .first(where: { $0.contentType == "emotion" })?
            .content?.moodEmoji
    }

    private var moodState: String? {
        // 优先从 emotion skill card 读取；chat session content 为 null 时回退到 task.emotionMood
        strategyAnalysis?.skillCards?
            .first(where: { $0.contentType == "emotion" })?
            .content?.moodState
        ?? task.emotionMood
    }

    private var moodEmojiSlot: String? {
        strategyAnalysis?.skillCards?
            .first(where: { $0.contentType == "emotion" })?
            .content?.moodEmojiSlot
    }

    private var selfEmojiType: String { profileVM.selfEmojiType }

    private var moodEmojiUrl: String? {
        let emojiType = selfEmojiType
        if emojiType == "self" {
            // Prefer fresh cached presigned URL (avoids expired stored URL)
            let slot: String
            if let s = moodEmojiSlot, !s.isEmpty {
                slot = s
            } else if let state = moodState, !state.isEmpty {
                slot = Self.slotFromMoodState(state)
            } else {
                slot = "neutral"
            }
            if let cachedUrl = SelfEmojiURLCache.shared.url(for: slot) {
                return cachedUrl
            }
            // Fallback: stored presigned URL from session data
            return strategyAnalysis?.skillCards?
                .first(where: { $0.contentType == "emotion" })?
                .content?.moodEmojiUrl
        } else {
            let slot: String
            if let s = moodEmojiSlot, !s.isEmpty {
                slot = s
            } else if let state = moodState, !state.isEmpty {
                slot = Self.slotFromMoodState(state)
            } else {
                slot = "neutral"
            }
            let base = NetworkManager.shared.getBaseURL()
            let apiBase = base.hasSuffix("/api/v1") ? String(base.dropLast(7)) : base
            return "\(apiBase)/api/v1/emoji-presets/\(emojiType)/\(slot)"
        }
    }

    private static func slotFromMoodState(_ state: String) -> String {
        // 对齐 sessions.mood_state 9 个枚举 → 5 个情绪槽（单一权威映射）
        switch state {
        case "Excited":                         return "very_happy"
        case "Happy", "Content":               return "happy"
        case "Neutral":                         return "neutral"
        case "Anxious", "Frustrated", "Angry": return "slightly_sad"
        case "Sad", "Overwhelmed":             return "sad"
        default:                                return "neutral"
        }
    }

    /// Strategy + scene skill cards (exclude emotion/mental_health always-run cards)
    private var strategySkillCards: [SkillCard]? {
        guard let cards = strategyAnalysis?.skillCards else { return nil }
        let filtered = cards.filter { $0.contentType != "emotion" && $0.contentType != "mental_health" }
        return filtered.isEmpty ? nil : filtered
    }

    private var primarySceneCategory: String? {
        if let cat = strategyAnalysis?.sceneCategory, !cat.isEmpty { return cat }
        if let first = strategySkillCards?.first(where: { !$0.sceneCategory.isEmpty }) {
            return first.sceneCategory
        }
        return nil
    }

    // MARK: - Loading

    private func loadAll() {
        loadTaskDetail()
        if task.status == .archived || task.status == .completed {
            loadStrategyAnalysis()
        }
    }

    private func loadTaskDetail(silent: Bool = false) {
        let cacheManager = DetailCacheManager.shared
        if let cached = cacheManager.getCachedDetail(sessionId: task.id) {
            self.detail = cached
            self.audioPlayer.setAudioUrl(cached.audioUrl)
            return
        }
        if let existing = detail, !existing.dialogues.isEmpty { return }
        if cacheManager.isLoadingDetail(for: task.id) { return }

        if !silent { isLoading = true }
        errorMessage = nil
        cacheManager.setLoadingDetail(true, for: task.id)

        Task {
            defer { cacheManager.setLoadingDetail(false, for: task.id) }
            do {
                let taskDetail = try await NetworkManager.shared.getTaskDetail(sessionId: task.id)
                cacheManager.cacheDetail(taskDetail, for: task.id)
                await MainActor.run {
                    self.detail = taskDetail
                    self.audioPlayer.setAudioUrl(taskDetail.audioUrl)
                    self.isLoading = false
                    self.errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = friendlyError(error)
                }
            }
        }
    }

    private func loadStrategyAnalysis() {
        let cacheManager = DetailCacheManager.shared
        if let cached = cacheManager.getCachedStrategy(sessionId: task.id) {
            let emotionCard = cached.skillCards?.first(where: { $0.contentType == "emotion" })
            let cachedUrl = emotionCard?.content?.moodEmojiUrl
            print("📦 [TaskDetailView] 缓存策略 moodEmojiUrl=\(cachedUrl ?? "nil")")
            // 如果缓存的情绪卡没有预签名 URL，跳过缓存强制重新请求
            if cachedUrl != nil {
                self.strategyAnalysis = cached
                #if DEBUG || INTERNALTEST
                DebugLogger.shared.setEmojiInfo(
                    userId: task.id,
                    slot: emotionCard?.content?.moodState,
                    urlStr: cachedUrl
                )
                #endif
                return
            }
            print("⚠️ [TaskDetailView] 缓存无 moodEmojiUrl，跳过缓存重新请求")
            cacheManager.invalidateStrategy(for: task.id)
        }
        if strategyIsLoading { return }
        strategyIsLoading = true
        print("🌐 [TaskDetailView] 请求服务端策略 sessionId=\(task.id)")

        Task {
            do {
                let response = try await NetworkManager.shared.getStrategyAnalysis(sessionId: task.id)
                let emotionCard = response.skillCards?.first(where: { $0.contentType == "emotion" })
                print("✅ [TaskDetailView] 服务端响应 moodEmojiUrl=\(emotionCard?.content?.moodEmojiUrl ?? "nil")")
                #if DEBUG || INTERNALTEST
                DebugLogger.shared.setEmojiInfo(
                    userId: task.id,
                    slot: emotionCard?.content?.moodState,
                    urlStr: emotionCard?.content?.moodEmojiUrl
                )
                #endif
                cacheManager.cacheStrategy(response, for: task.id)
                await MainActor.run {
                    self.strategyAnalysis = response
                    self.strategyIsLoading = false
                }
            } catch {
                print("❌ [TaskDetailView] 策略加载失败: \(error)")
                await MainActor.run { self.strategyIsLoading = false }
            }
        }
    }

    private func friendlyError(_ error: Error) -> String {
        let ns = error as NSError
        let msg = error.localizedDescription.lowercased()
        if ns.code == -1001 || msg.contains("timeout") {
            return "Request timed out. Please check your connection."
        } else if ns.code == 404 {
            return "Moment not found."
        } else if ns.code == 401 || ns.code == 403 {
            return "Authentication failed, please log in again."
        } else if msg.contains("safety") || msg.contains("blocked") || msg.contains("filter") {
            return "This content couldn't be processed. Please try recording again."
        }
        return "Something went wrong. Please try again."
    }
}

// MARK: - MomentInfoCard

private struct MomentInfoCard: View {
    let sceneDescription: String?
    let isLive: Bool
    let onSummaryTap: () -> Void
    /// 非 nil 时表示 chat session：doc.text 按钮跳 AI chat，play 按钮隐藏
    let onChatTap: (() -> Void)?
    @ObservedObject var audioPlayer: SessionAudioPlayerService
    let moodEmoji: String?
    let moodEmojiUrl: String?
    let moodState: String?
    let startTime: Date
    let strategyIsLoading: Bool
    let imageURLs: [String]
    @State private var emojiLoadFailed = false
    @State private var showSharePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Scene description
            // Action row: chat session → [chat][share]---[mood]
            //             recording   → [doc][play][share]---[mood]
            HStack(spacing: 0) {
                // 详情/chat 按钮
                Button(action: { onChatTap != nil ? onChatTap!() : onSummaryTap() }) {
                    Image(systemName: onChatTap != nil ? "bubble.left.and.bubble.right.fill" : "doc.text")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.85))
                }

                // Play/pause 按钮（chat session 隐藏）
                if onChatTap == nil {
                    Button(action: { audioPlayer.togglePlayback() }) {
                        Group {
                            if audioPlayer.isBuffering {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.85)))
                                    .scaleEffect(0.85)
                                    .frame(width: 22, height: 22)
                            } else {
                                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white.opacity(0.85))
                            }
                        }
                    }
                    .padding(.leading, 22)
                }

                // Share button
                Button(action: { showSharePicker = true }) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.leading, 22)
                .sheet(isPresented: $showSharePicker) {
                    SharePickerSheet(imageURLs: imageURLs)
                }

                Spacer()

                // Mood emoji（仅图标，文字移到日期行）
                if moodState != nil {
                    if let urlStr = moodEmojiUrl, !emojiLoadFailed {
                        ImageLoaderView(
                            imageUrl: urlStr,
                            imageBase64: nil,
                            contentMode: .fill,
                            onLoadFailed: { emojiLoadFailed = true }
                        )
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                    } else {
                        Text(moodEmoji ?? "😐").font(.system(size: 40))
                    }
                }
            }

            // Date row（左：日期  右：mood 文字）
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
                Text(dateString)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
                Spacer()
                if let state = moodState {
                    Text(state)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#1C1C1E"))
        .cornerRadius(16)
    }

    private var dateString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "yyyy/MM/dd EEEE"
        return f.string(from: startTime)
    }
}

// MARK: - MomentSkillsCard

private struct MomentSkillsCard: View {
    let sceneCategoryName: String?
    let skillCards: [SkillCard]
    let sessionId: String
    let sceneImages: [SceneImage]
    let baseURL: String
    /// 非 nil 时（chat session）：点击技能跳 AI chat，不走默认 AIAssistantView
    let onSkillTap: (() -> Void)?
    @State private var assistantCard: SkillCard?

    private func iconFor(_ cat: String) -> String {
        switch cat {
        case "Work Life": return "briefcase.fill"
        case "Campus":    return "graduationcap.fill"
        case "Social":    return "person.2.fill"
        case "Family":    return "house.fill"
        case "Growth":    return "chart.line.uptrend.xyaxis"
        case "Life":      return "sparkles"
        default:          return "circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Category pill
            if let cat = sceneCategoryName, !cat.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: iconFor(cat))
                        .font(.system(size: 12, weight: .semibold))
                    Text(cat)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(white: 0.28))
                .cornerRadius(20)
            }

            // Skill rows — onAppear fires when skills section is visible on screen,
            // guaranteeing: detail page is showing AND skills are loaded.
            VStack(spacing: 0) {
                ForEach(Array(skillCards.enumerated()), id: \.element.id) { idx, card in
                    Button(action: {
                        if let tap = onSkillTap { tap() } else { assistantCard = card }
                    }) {
                        HStack(spacing: 12) {
                            Rectangle()
                                .fill(Color.blue)
                                .frame(width: 3)
                                .cornerRadius(2)
                                .padding(.vertical, 2)

                            Text(card.accordionTitle)
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundColor(Color(hex: "#5E9BF5"))
                                .lineLimit(1)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.35))
                        }
                        .frame(minHeight: 46)
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if idx < skillCards.count - 1 {
                        Divider()
                            .background(Color.white.opacity(0.1))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#1C1C1E"))
        .cornerRadius(16)
        .fullScreenCover(item: $assistantCard) { card in
            AIAssistantView(
                sessionId: sessionId,
                skillCard: card,
                sceneImages: sceneImages,
                baseURL: baseURL,
                onDismiss: { assistantCard = nil }
            )
        }
    }
}

// MARK: - SkillCardDetailSheet  (lightweight sheet showing strategy content)

private struct SkillCardDetailSheet: View {
    let card: SkillCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let strategies = card.content?.strategies, !strategies.isEmpty {
                        ForEach(strategies) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    if let emoji = item.emoji {
                                        Text(emoji).font(.system(size: 18))
                                    }
                                    Text(item.title)
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundColor(.primary)
                                }
                                Text(item.content)
                                    .font(.system(size: 14, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .lineSpacing(5)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                    } else if let moodContent = card.content?.emotionContent {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text(moodContent.moodEmoji).font(.system(size: 36))
                                VStack(alignment: .leading) {
                                    Text(moodContent.moodState)
                                        .font(.system(size: 18, weight: .bold, design: .rounded))
                                    Text("\(moodContent.charCount) characters spoken")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                }
                            }
                            HStack(spacing: 20) {
                                Label("\(moodContent.sighCount) sighs", systemImage: "wind")
                                Label("\(moodContent.hahaCount) laughs", systemImage: "face.smiling")
                            }
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    } else {
                        Text("No details available yet.")
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 100)
                    }
                }
                .padding(20)
            }
            .navigationTitle(card.accordionTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - SummarySheet

private struct SummarySheet: View {
    let summary: String?
    let dialogues: [DialogueItem]
    @Environment(\.dismiss) private var dismiss
    @State private var showDialogue = true  // 默认展开

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let summary = summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 15, weight: .regular, design: .rounded))
                            .foregroundColor(.white)
                            .lineSpacing(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Summary not available yet.")
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                    }

                    // View Details & Recording toggle
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.25)) { showDialogue.toggle() }
                    }) {
                        HStack {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 16))
                            Text("View Details & Recording")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Spacer()
                            Image(systemName: showDialogue ? "chevron.up" : "chevron.down")
                                .font(.system(size: 13))
                        }
                        .foregroundColor(Color(hex: "#5E9BF5"))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)

                    if showDialogue {
                        Divider()
                            .background(Color.white.opacity(0.15))
                        VStack(spacing: 16) {
                            ForEach(Array(dialogues.enumerated()), id: \.offset) { _, dialogue in
                                DialogueBubbleView(
                                    dialogue: dialogue,
                                    isOwn: dialogue.isMe ?? false
                                )
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            .background(Color.black)
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color(hex: "#5E9BF5"))
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - LiveReplaySheet
// 对话回放页：复刻 LiveSessionView 布局，去掉录制控件（计时、设备状态、结束按钮）

private struct LiveReplaySheet: View {
    let dialogues: [DialogueItem]
    let skillCards: [SkillCard]
    @Environment(\.dismiss) private var dismiss

    // 过滤掉 emotion/mental_health 类卡片，只展示技能策略卡
    private var strategyCards: [SkillCard] {
        skillCards.filter { $0.contentType != "emotion" && $0.contentType != "mental_health" }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                replayHeader
                chatArea
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 顶部栏（无设备/计时/REC）
    private var replayHeader: some View {
        HStack {
            Spacer()
            Text("对话回放")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Button("完成") { dismiss() }
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(hex: "#5E9BF5"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(white: 0.07))
    }

    // MARK: - 对话流区域
    private var chatArea: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if dialogues.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 36))
                            .foregroundColor(.white.opacity(0.12))
                        Text("暂无对话记录")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.25))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    ForEach(Array(dialogues.enumerated()), id: \.offset) { _, dialogue in
                        ReplayTurnBubble(dialogue: dialogue)
                        if let sug = dialogue.suggestion, !sug.isEmpty {
                            ReplaySuggestionBubble(text: sug)
                        }
                    }

                    // 技能卡片区（在对话流末尾）
                    if !strategyCards.isEmpty {
                        skillCardsSection
                    }
                }

                Color.clear.frame(height: 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - 技能卡片区块
    private var skillCardsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 1)
                Text("Session Skills")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .textCase(.uppercase)
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 1)
            }
            .padding(.vertical, 6)

            ForEach(strategyCards) { card in
                ReplaySkillCardView(card: card)
            }
        }
    }
}

// MARK: - 对话气泡（复刻 LiveSessionView TurnBubble）

private struct ReplayTurnBubble: View {
    let dialogue: DialogueItem
    private var isMe: Bool { dialogue.isMe ?? false }

    // 将 "Speaker_1" 映射为 "说话人A"
    private var displayLabel: String {
        let letters = ["A", "B", "C", "D", "E"]
        if let suffix = dialogue.speaker.components(separatedBy: "_").last,
           let n = Int(suffix), n >= 1, n - 1 < letters.count {
            return "说话人\(letters[n - 1])"
        }
        return dialogue.speaker
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isMe { Spacer(minLength: 60) }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                if !isMe {
                    Text(displayLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.38))
                        .padding(.leading, 4)
                }
                Text(dialogue.content)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isMe ? Color(white: 0.20) : Color(white: 0.16))
                    )
                    .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
            }
            if !isMe { Spacer(minLength: 60) }
        }
    }
}

// MARK: - AI 建议气泡（复刻 LiveSessionView InlineSuggestionBubble）

private struct ReplaySuggestionBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(Color(white: 0.22)).frame(width: 28, height: 28)
                Text("AI")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(white: 0.18))
                )
            Spacer(minLength: 60)
        }
    }
}

// MARK: - 技能卡片（复刻 LiveSessionView LiveSkillCardView，适配 SkillCard 模型）

private struct ReplaySkillCardView: View {
    let card: SkillCard

    private var accentColor: Color {
        let lc = (card.category ?? "").lowercased()
        if lc.contains("social") || lc.contains("沟通") || lc.contains("relationships") { return Color(hex: "#4A9EFF") }
        if lc.contains("language") || lc.contains("语言") { return Color(hex: "#34C759") }
        if lc.contains("emotion") || lc.contains("情绪") { return Color(hex: "#BF5AF2") }
        if lc.contains("negotiat") || lc.contains("谈判") { return Color(hex: "#FF9500") }
        return Color(hex: "#00D4FF")
    }

    private var iconName: String {
        let lc = (card.category ?? "").lowercased()
        if lc.contains("social") || lc.contains("relationships") { return "person.2.fill" }
        if lc.contains("language") { return "globe" }
        if lc.contains("emotion") { return "heart.fill" }
        if lc.contains("negotiat") { return "arrow.left.arrow.right" }
        return "lightbulb.fill"
    }

    // 取第一条策略内容作为 advice 展示
    private var adviceText: String? {
        card.content?.strategies?.first?.content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)

            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: iconName)
                        .font(.system(size: 14))
                        .foregroundColor(accentColor)
                }
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(card.accordionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    if let advice = adviceText, !advice.isEmpty {
                        Text(advice)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.72))
                            .lineLimit(3)
                    }
                }

                Spacer()
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
        }
        .background(Color(white: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - DetailHeaderView (unchanged)

struct DetailHeaderView: View {
    @Environment(\.presentationMode) var presentationMode
    var onReportTap: (() -> Void)? = nil

    var body: some View {
        HStack {
            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 39.98, height: 39.98)
                        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(AppColors.headerText)
                }
            }

            Spacer()

            Text("Details")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundColor(AppColors.headerText)
                .tracking(0.5)

            Spacer()

            Button(action: { onReportTap?() }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 39.98, height: 39.98)
                        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(AppColors.headerText)
                }
            }
        }
    }
}

// MARK: - DateTimeInfoBar (kept for backward compatibility, no longer used in main body)

struct DateTimeInfoBar: View {
    let task: TaskItem
    @ObservedObject var audioPlayer: SessionAudioPlayerService

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 18))
                    .foregroundColor(AppColors.headerText.opacity(0.8))
                Text(dateTimeString)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppColors.headerText.opacity(0.8))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 16)
            .frame(height: 37.37)
            .background(
                RoundedRectangle(cornerRadius: 9999)
                    .fill(Color.white.opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: 9999).stroke(Color.white.opacity(0.2), lineWidth: 0.69))
            )

            Spacer(minLength: 8)

            Button(action: { audioPlayer.togglePlayback() }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 49.37, height: 49.37)
                        .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.69))
                        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundColor(AppColors.headerText.opacity(0.8))
                }
            }
            .disabled(audioPlayer.isBuffering)
        }
        .frame(maxWidth: .infinity)
    }

    private var dateTimeString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "yyyy/MM/dd EEEE"
        return f.string(from: task.startTime)
    }
}

// MARK: - ReportMenuPanel (unchanged)

struct ReportMenuPanel: View {
    let sessionId: String
    @Binding var submitted: Bool
    let onDismiss: () -> Void

    private let reasons = [
        ("flag.fill",           "Inappropriate Content"),
        ("c.circle",            "Copyright Issue"),
        ("exclamationmark.shield.fill", "Violence or Hate Speech"),
        ("envelope.badge.fill", "Spam or Misleading"),
        ("questionmark.circle", "Other"),
    ]
    @State private var isSubmitting = false
    @State private var showConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 16)

            if showConfirmation {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(Color(hex: "#34D399"))
                    Text("Report Submitted")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(AppColors.primaryText)
                    Text("Thank you. We'll review this content.")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(AppColors.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .padding(.top, 8)
            } else {
                Text("Report Content")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(AppColors.primaryText)
                    .padding(.bottom, 8)

                Text("Select a reason for your report")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(AppColors.secondaryText)
                    .padding(.bottom, 16)

                VStack(spacing: 1) {
                    ForEach(reasons, id: \.1) { icon, label in
                        Button { submitReport(reason: label) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: icon)
                                    .font(.system(size: 15))
                                    .foregroundColor(AppColors.secondaryText)
                                    .frame(width: 20)
                                Text(label)
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundColor(AppColors.primaryText)
                                Spacer()
                                if isSubmitting { ProgressView().scaleEffect(0.7) }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.05))
                        }
                        .disabled(isSubmitting)
                    }
                }
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                Button("Cancel") { onDismiss() }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColors.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppColors.background)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func submitReport(reason: String) {
        isSubmitting = true
        Task {
            await NetworkManager.shared.submitReport(sessionId: sessionId, reason: reason)
            await MainActor.run {
                isSubmitting = false
                submitted = true
                withAnimation { showConfirmation = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { onDismiss() }
            }
        }
    }
}
