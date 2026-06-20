//
//  ChatAIAssistantView.swift
//  WorkSurvivalGuide
//
//  全屏对话 AI 助手视图（chat session 模式）
//

import SwiftUI
import AVFoundation

// MARK: - ChatInputMode

private enum ChatInputMode { case voice, text }

// MARK: - ChatAIAssistantView

struct ChatAIAssistantView: View {
    let sessionId: String

    @StateObject private var chatVM: ChatAIAssistantViewModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("image_style") private var selectedImageStyle: String = "spider_verse"

    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var showExitSheet = false
    @State private var isClosingSession = false
    @State private var isGeneratingImage = false
    @State private var errorToast: String? = nil

    // ── scroll proxy for auto-scroll to bottom ──
    @State private var scrollToBottom = false

    // ── voice input ──
    @State private var inputMode: ChatInputMode = .voice
    @State private var isRecording: Bool = false
    @StateObject private var audioRecorder = GeminiAudioRecorder()

    init(sessionId: String) {
        self.sessionId = sessionId
        _chatVM = StateObject(wrappedValue: ChatAIAssistantViewModel(sessionId: sessionId))
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

                // Loading overlay for close/generate
                if isClosingSession || isGeneratingImage {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    ProgressView(isGeneratingImage ? "Starting image generation..." : "Saving...")
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: handleCloseTap) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .disabled(isClosingSession || isGeneratingImage)
                }
            }
        }
        .navigationViewStyle(.stack)
        .confirmationDialog(
            "What would you like to do?",
            isPresented: $showExitSheet,
            titleVisibility: .visible
        ) {
            // image quota 耗尽时隐藏 "Convert to image"，直接只留 Just close
            if SubscriptionManager.shared.canGenerateImage {
                Button("Convert to image") { handleGenerateImage() }
            }
            Button("Just close") { handleCloseWithFinalize() }
            Button("Keep chatting", role: .cancel) {}
        } message: {
            Text("Your conversation will be saved either way.")
        }
        .alert(chatVM.errorMessage ?? "Error", isPresented: Binding(
            get: { chatVM.errorMessage != nil },
            set: { if !$0 { chatVM.errorMessage = nil } }
        )) {
            Button("OK") {}
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
                        ChatBubble(message: msg)
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
            Text("You might ask:")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 2)

            ForEach(chatVM.suggestions, id: \.self) { question in
                Button(action: {
                    inputText = question
                    inputMode = .text
                    isInputFocused = true
                }) {
                    HStack(spacing: 10) {
                        Text(question)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(.white.opacity(0.82))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.circle")
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
        if chatVM.isConversationEmpty {
            // 未对话 → 删除孤儿 session，不触发 finalize
            deleteOrphanSession()
        } else if hasAlreadyExited {
            // 已经做过退出决策（Convert to Image 或 Just Close）→ 直接退出，不再弹窗
            dismiss()
        } else {
            showExitSheet = true
        }
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

    private func handleGenerateImage() {
        markSessionExit(action: "convert")
        isGeneratingImage = true
        let conversation = chatVM.conversationForServer()
        Task {
            do {
                _ = try await NetworkManager.shared.generateImageFromChat(
                    sessionId: sessionId,
                    conversation: conversation,
                    styleKey: selectedImageStyle
                )
            } catch {
                print("⚠️ [ChatAIAssistantView] generateImageFromChat failed: \(error)")
            }
            await MainActor.run {
                isGeneratingImage = false
                NotificationCenter.default.post(
                    name: NSNotification.Name("ChatSessionGeneratingImage"),
                    object: sessionId
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

    var isUser: Bool { message.role == .user }

    var body: some View {
        // 语音消息：transcript 未到达时（占位符）显示波形气泡；
        // transcript 到达后 content 已更新为真实文字，走普通文字气泡
        if message.isVoice, let path = message.audioFileURL,
           message.content == "[Voice message]" {
            VoiceMessageBubble(fileURLPath: path)
        } else {
            HStack(alignment: .bottom, spacing: 0) {
                if isUser { Spacer(minLength: 60) }

                HStack(spacing: 6) {
                    // 若该条消息原为语音输入，加小麦克风图标提示
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
