//
//  ChatAIAssistantView.swift
//  WorkSurvivalGuide
//
//  全屏对话 AI 助手视图（chat session 模式）
//

import SwiftUI
import AVFoundation
import TikTokBusinessSDK

// MARK: - ChatInputMode

private enum ChatInputMode { case voice, text }

// MARK: - ChatAIAssistantView

struct ChatAIAssistantView: View {
    let sessionId: String
    /// true = 从 Moment 列表重入已有 session；false = 全新创建的 session
    let isExistingSession: Bool

    @StateObject private var chatVM: ChatAIAssistantViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var isClosingSession = false
    @State private var errorToast: String? = nil
    @State private var showSharePicker = false
    @State private var didTrackView = false
    @State private var showUnmatchedPersonToast = false
    @State private var showProfileCreate = false

    // ── scroll proxy for auto-scroll to bottom ──
    @State private var scrollToBottom = false

    // ── full-screen image viewer ──
    @State private var showFullScreen = false
    @State private var fullScreenInitialIndex = 0

    // ── voice input ──
    @State private var inputMode: ChatInputMode = .voice
    @State private var isRecording: Bool = false
    @StateObject private var audioRecorder = GeminiAudioRecorder()

    init(sessionId: String, isExistingSession: Bool = false) {
        self.sessionId = sessionId
        self.isExistingSession = isExistingSession
        _chatVM = StateObject(wrappedValue: ChatAIAssistantViewModel(sessionId: sessionId, isExistingSession: isExistingSession))
    }

    private var sceneImageItems: [(imageUrl: String?, imageBase64: String?)] {
        chatVM.messages
            .filter { $0.isSceneImage && !$0.isGeneratingSceneImage && $0.sceneImageURL != "error" }
            .map { (imageUrl: $0.sceneImageURL, imageBase64: nil) }
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // 技能标签区
                    if chatVM.isMatchingSkills || !chatVM.skillTags.isEmpty || chatVM.baselinePhase != nil {
                        skillTagsBar
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // 引导面板：仅在对话为空时展示
                    if chatVM.messages.isEmpty {
                        ScrollView {
                            TopicGuideView { moduleId, topicText in
                                chatVM.markModuleUsed(moduleId)
                                chatVM.send(text: topicText)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // 对话流（有消息后显示）
                    if !chatVM.messages.isEmpty {
                        chatScrollView
                            .transition(.opacity)
                    }

                    // 底部输入栏
                    inputBar
                }
                .animation(.easeInOut(duration: 0.25), value: chatVM.messages.isEmpty)

                // Error toast
                if let msg = errorToast {
                    VStack {
                        Spacer()
                        Text(msg)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(20)
                            .padding(.bottom, 100)
                    }
                    .transition(.opacity)
                    .zIndex(99)
                }

                // Unmatched person toast — tap to create profile
                if showUnmatchedPersonToast {
                    VStack {
                        Spacer()
                        Button { showProfileCreate = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.badge.plus")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("New character detected. Create a profile for more consistent results.")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .multilineTextAlignment(.leading)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Color(hex: "#1D4ED8").opacity(0.92))
                            .cornerRadius(20)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 96)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(98)
                    .onAppear {
                        Task {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            await MainActor.run { withAnimation { showUnmatchedPersonToast = false } }
                        }
                    }
                }

                // Loading overlay for history / close
                if chatVM.isLoadingHistory || isClosingSession {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    ProgressView(chatVM.isLoadingHistory ? "Loading history..." : "Saving...")
                        .foregroundColor(.white)
                        .tint(.white)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text("AI Chat")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !sceneImageItems.isEmpty {
                        Button { showSharePicker = true } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                        }
                    }
                    Button(action: handleCloseTap) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .disabled(isClosingSession)
                }
            }
        }
        .navigationViewStyle(.stack)
        .alert(chatVM.errorMessage ?? "Error", isPresented: Binding(
            get: { chatVM.errorMessage != nil },
            set: { if !$0 { chatVM.errorMessage = nil } }
        )) {
            Button("OK") {}
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenImageViewer(
                items: sceneImageItems,
                initialIndex: fullScreenInitialIndex,
                baseURL: ""
            ) { showFullScreen = false }
        }
        .sheet(isPresented: $chatVM.showPaywall) {
            SubscriptionView()
        }
        .sheet(isPresented: $showSharePicker) {
            SharePickerSheet(imageURLs: sceneImageItems.compactMap { $0.imageUrl })
        }
        .sheet(isPresented: $showProfileCreate) {
            ProfileEditView(profile: nil)
        }
        .onChange(of: chatVM.unmatchedPeople) { people in
            if !people.isEmpty {
                withAnimation { showUnmatchedPersonToast = true }
            }
        }
        .alert("You've reached the image generation limit", isPresented: $chatVM.showProLimitToast) {
            Button("OK", role: .cancel) { chatVM.showProLimitToast = false }
        } message: {
            Text("You've used all your image generations for this period. They'll reset with your next billing cycle.")
        }
        .onAppear {
            guard !didTrackView else { return }
            didTrackView = true
            TikTokTracker.track("ViewContent", ["content_id": "ai_chat", "content_type": "feature"])
        }
        .task {
            if isExistingSession {
                await chatVM.loadHistory()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chatVM.skillTags.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: chatVM.baselinePhase)
        .animation(.easeInOut(duration: 0.3), value: chatVM.suggestions.isEmpty)
        .onChange(of: chatVM.messages.count) { _ in scrollToBottom = true }
    }

    // MARK: - Skill Tags Bar

    private var skillTagsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if chatVM.isMatchingSkills {
                    HStack(spacing: 6) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.6)))
                            .scaleEffect(0.65)
                        Text("Matching skills...")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                } else {
                    ForEach(chatVM.skillTags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.75))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    if let phase = chatVM.baselinePhase {
                        Text(phase == "ask" ? "Setting up your profile..." : "Saving profile...")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.black.opacity(0.3))
    }

    // MARK: - Chat Scroll View

    private var chatScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(chatVM.messages) { msg in
                        ChatBubble(message: msg, onImageTap: { url in
                            let items = sceneImageItems
                            let idx = items.firstIndex { $0.imageUrl == url } ?? 0
                            fullScreenInitialIndex = idx
                            showFullScreen = true
                        })
                        .id(msg.id)
                    }

                    // Streaming bubble
                    if chatVM.isStreaming && !chatVM.displayedStreamingText.isEmpty {
                        ChatBubble(
                            message: AssistantMessage(role: .assistant,
                                                      content: chatVM.displayedStreamingText)
                        )
                        .id("streaming")
                    }

                    // Streaming indicator (dot pulse before first token)
                    if chatVM.isStreaming && chatVM.displayedStreamingText.isEmpty {
                        HStack {
                            StreamingDotView()
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .id("streaming_indicator")
                    }

                    // 猜你想问 chips（流结束后显示）
                    if !chatVM.isStreaming && !chatVM.suggestions.isEmpty {
                        suggestedQuestionsView
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    Color.clear.frame(height: 8).id("bottom_anchor")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: scrollToBottom) { _ in
                withAnimation {
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
                scrollToBottom = false
            }
            .onChange(of: chatVM.displayedStreamingText) { _ in
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
            .onChange(of: chatVM.suggestions.count) { count in
                if count > 0 { scrollToBottom = true }
            }
        }
    }

    // MARK: - Suggested Questions

    private var suggestedQuestionsView: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Next scene:")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 2)

            ForEach(chatVM.suggestions, id: \.self) { question in
                Button(action: {
                    chatVM.send(text: question)
                }) {
                    HStack(spacing: 10) {
                        Text(question)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(.white.opacity(0.82))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "sparkles")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chatVM.suggestions.count)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        Group {
            switch inputMode {
            case .voice:
                voiceInputBar
            case .text:
                textInputBar
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.6))
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: inputMode)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isRecording)
    }

    // ── 语音模式（默认）──
    private var voiceInputBar: some View {
        HStack(spacing: 12) {
            if isRecording {
                // 录音中：声波胶囊（单击 = 停止并发送）
                Button(action: sendVoiceMessage) {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                        ChatVoiceWaveformView()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))

                // 取消按钮
                Button(action: cancelRecording) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))

            } else {
                // 待机：大胶囊（单击 = 开始录音）
                Button(action: startRecording) {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                        Text("Tap to speak")
                            .font(.system(size: 16, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.07))
                            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(chatVM.isStreaming)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))

                // 键盘按钮（切文字模式，直接呼出键盘）
                Button(action: {
                    inputMode = .text
                    isInputFocused = true
                }) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
    }

    // ── 文字模式 ──
    private var textInputBar: some View {
        HStack(spacing: 12) {
            TextField("Message...", text: $inputText, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 15, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .focused($isInputFocused)
                .disabled(chatVM.isStreaming)

            if chatVM.isStreaming {
                Button(action: { chatVM.cancelStream() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 空文字：麦克风按钮（切回语音模式）
                Button(action: { inputMode = .voice }) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        chatVM.send(text: text)
    }

    private func startRecording() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            isRecording = true
        }
        audioRecorder.startRecording()
    }

    private func sendVoiceMessage() {
        let result = audioRecorder.stopRecording()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            isRecording = false
        }
        guard let (data, fileURL) = result else { return }
        chatVM.sendAudio(audioData: data, fileURL: fileURL)
    }

    private func cancelRecording() {
        audioRecorder.cancelRecording()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            isRecording = false
        }
    }

    // MARK: - Exit state helpers

    /// 该 session 是否已经做过退出决策（Convert to Image 或 Just Close）
    private var hasAlreadyExited: Bool {
        let exited = UserDefaults.standard.stringArray(forKey: "chat_exited_sessions") ?? []
        return exited.contains(sessionId)
    }

    /// 记录该 session 已做过退出决策，后续再退出直接 dismiss
    /// action: "convert" | "just_close"
    private func markSessionExit(action: String) {
        var exited = UserDefaults.standard.stringArray(forKey: "chat_exited_sessions") ?? []
        if !exited.contains(sessionId) {
            exited.append(sessionId)
            UserDefaults.standard.set(exited, forKey: "chat_exited_sessions")
        }
        UserDefaults.standard.set(action, forKey: "chat_exit_action_\(sessionId)")
    }

    // MARK: - Actions

    private func handleCloseTap() {
        TikTokTracker.track("ClickButton", [
            "content_id": "close_ai_chat",
            "content_type": "feature",
            "image_count": sceneImageItems.count
        ])
        // 从列表重入：无论有无新消息，直接关（session 已归档，不重复 finalize 或删除）
        if isExistingSession {
            dismiss()
            return
        }
        // 全新 session 且从未对话 → 孤儿，删除
        if chatVM.isConversationEmpty {
            deleteOrphanSession()
            return
        }
        // 已经做过退出决策 → 不重复弹窗
        if hasAlreadyExited {
            dismiss()
            return
        }
        // 直接以 leave 逻辑处理
        handleCloseWithFinalize()
    }

    private func handleCloseWithFinalize() {
        markSessionExit(action: "just_close")
        isClosingSession = true
        let conversation = chatVM.conversationForServer()
        Task {
            do {
                try await NetworkManager.shared.closeChatSession(
                    sessionId: sessionId,
                    conversation: conversation
                )
            } catch {
                print("⚠️ [ChatAIAssistantView] closeChatSession failed: \(error)")
            }
            await MainActor.run {
                isClosingSession = false
                // 更新本地 TaskItem 状态为 archived
                NotificationCenter.default.post(
                    name: NSNotification.Name("ChatSessionClosed"),
                    object: sessionId,
                    userInfo: ["mood": chatVM.lastMoodState ?? "neutral"]
                )
                dismiss()
            }
        }
    }

    private func deleteOrphanSession() {
        Task {
            try? await NetworkManager.shared.deleteSession(sessionId)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ChatSessionDeleted"),
                    object: sessionId
                )
                dismiss()
            }
        }
    }
}

// MARK: - Chat Bubble

private struct ChatBubble: View {
    let message: AssistantMessage
    var onImageTap: ((String) -> Void)? = nil

    var isUser: Bool { message.role == .user }

    var body: some View {
        if message.isVoice, let path = message.audioFileURL,
           message.content == "[Voice message]" {
            // 语音消息：波形播放气泡
            VoiceMessageBubble(fileURLPath: path)
        } else if message.isSceneImage {
            // 场景图独立气泡（4:5 全宽）
            SceneImageBubble(
                url: message.sceneImageURL ?? "loading",
                isGenerating: message.isGeneratingSceneImage,
                onTap: (message.isGeneratingSceneImage || message.sceneImageURL == "error") ? nil : { onImageTap?(message.sceneImageURL ?? "") }
            )
            .animation(.easeInOut(duration: 0.3), value: message.hasSceneImage)
        } else {
            // 普通文字气泡
            HStack(alignment: .bottom, spacing: 0) {
                if isUser { Spacer(minLength: 60) }

                HStack(spacing: 6) {
                    if message.isVoice {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    Text(message.content)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(isUser ? .trailing : .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isUser
                            ? Color(hex: "#2D4A5E")
                            : Color.white.opacity(0.1))
                )

                if !isUser { Spacer(minLength: 60) }
            }
        }
    }
}

// MARK: - Scene Image Bubble (独立消息气泡，4:5 全宽)

private struct SceneImageBubble: View {
    let url: String
    let isGenerating: Bool
    var onTap: (() -> Void)? = nil

    var body: some View {
        if isGenerating {
            SceneImageSkeletonView()
        } else if url == "error" {
            SceneImageFailedView()
        } else {
            SceneImageView(url: url, onTap: onTap)
        }
    }
}

// MARK: - Scene Image Skeleton (生成中骨架屏，4:5 全宽)

private struct SceneImageSkeletonView: View {
    @State private var shimmerOffset: CGFloat = -1.0

    var body: some View {
        Color.clear
            .aspectRatio(4/5, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.07))
                    // shimmer
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.12), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: shimmerOffset * geo.size.width)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    // label
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 26))
                            .foregroundColor(.white.opacity(0.22))
                        Text("Generating scene...")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.22))
                    }
                }
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmerOffset = 1.6
                }
            }
    }
}

// MARK: - Scene Image Failed (生图超时/被安全过滤，显示占位提示)

private struct SceneImageFailedView: View {
    var body: some View {
        Color.clear
            .aspectRatio(4/5, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.07))
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 26))
                            .foregroundColor(.white.opacity(0.3))
                        Text("Image unavailable")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            )
    }
}

// MARK: - Scene Image View (图片就绪，4:5 全宽)

private struct SceneImageView: View {
    let url: String
    var onTap: (() -> Void)? = nil

    var body: some View {
        // 使用 ImageLoaderView（内存+磁盘缓存 + JWT），替代 AsyncImage（无缓存）
        Color.clear
            .aspectRatio(4/5, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                ImageLoaderView(imageUrl: url, imageBase64: nil, contentMode: .fill)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
    }
}

// MARK: - Streaming Dot Indicator

private struct StreamingDotView: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.white.opacity(i == phase ? 0.9 : 0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.1))
        )
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}

// MARK: - Chat Voice Waveform

private struct ChatVoiceWaveformView: View {
    private let barCount = 22

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { i in
                    let h = barHeight(index: i, date: context.date)
                    Capsule()
                        .fill(Color.white.opacity(0.72))
                        .frame(width: 2.5, height: h)
                        .animation(.spring(response: 0.28, dampingFraction: 0.62), value: h)
                }
            }
            .frame(height: 28)
            .clipped()
            .frame(maxWidth: .infinity)
        }
    }

    private func barHeight(index: Int, date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let f1 = 3.8 + Double(index) * 0.21
        let f2 = 7.3 + Double(index) * 0.16
        let v = (sin(t * f1) + sin(t * f2 + Double(index) * 0.9) * 0.55 + 1.55) / 3.1
        return max(3, CGFloat(v) * 26)
    }
}

// MARK: - Voice Message Player (ObservableObject)

private final class VoiceMessagePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var elapsed: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(path: String) {
        let url = URL(fileURLWithPath: path)
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.prepareToPlay()
        player = p
        duration = p.duration
    }

    func toggle() { isPlaying ? stop() : play() }

    func stop() {
        player?.stop()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        elapsed = 0
    }

    private func play() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.currentTime = 0
        player.play()
        isPlaying = true
        elapsed = 0
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.elapsed = p.currentTime
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        stop()
    }
}

// MARK: - Voice Message Bubble

private struct VoiceMessageBubble: View {
    let fileURLPath: String
    @StateObject private var vm = VoiceMessagePlayer()

    private let barCount = 18

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 60)

            Button(action: { vm.toggle() }) {
                HStack(spacing: 10) {
                    // Play / Stop icon
                    Image(systemName: vm.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 18, height: 18)

                    // Waveform bars
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(0..<barCount, id: \.self) { i in
                            Capsule()
                                .fill(Color.white.opacity(vm.isPlaying ? 0.9 : 0.55))
                                .frame(width: 2.5, height: staticBarHeight(index: i))
                                .animation(
                                    vm.isPlaying
                                        ? .easeInOut(duration: 0.3).repeatForever().delay(Double(i) * 0.04)
                                        : .default,
                                    value: vm.isPlaying
                                )
                        }
                    }
                    .frame(height: 24)

                    // Duration / elapsed
                    Text(vm.isPlaying ? formatTime(vm.elapsed) : formatTime(vm.duration))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(minWidth: 28, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(hex: "#2D4A5E"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .onAppear { vm.load(path: fileURLPath) }
            .onDisappear { vm.stop() }
        }
    }

    /// 静态波形高度（模拟自然分布）
    private func staticBarHeight(index: Int) -> CGFloat {
        let heights: [CGFloat] = [6, 10, 16, 20, 18, 22, 14, 8, 12, 20, 24, 18, 10, 16, 20, 14, 8, 6]
        guard index < heights.count else { return 10 }
        return heights[index]
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return "\(s)\""
    }
}

