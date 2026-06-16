//
//  ChatAIAssistantView.swift
//  WorkSurvivalGuide
//
//  全屏对话 AI 助手视图（chat session 模式）
//

import SwiftUI

// MARK: - ChatAIAssistantView

struct ChatAIAssistantView: View {
    let sessionId: String

    @StateObject private var chatVM: ChatAIAssistantViewModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("image_style") private var selectedImageStyle: String = "ghibli"

    @State private var inputText = ""
    @State private var showExitSheet = false
    @State private var isClosingSession = false
    @State private var isGeneratingImage = false
    @State private var errorToast: String? = nil

    // ── scroll proxy for auto-scroll to bottom ──
    @State private var scrollToBottom = false

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

                    // 对话流
                    chatScrollView

                    // 底部输入栏
                    inputBar
                }

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
            Button("Convert to image") { handleGenerateImage() }
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
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Message...", text: $inputText, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 15, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .disabled(chatVM.isStreaming)

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatVM.isStreaming
                        ? .white.opacity(0.25)
                        : .white)
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatVM.isStreaming)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.6))
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        chatVM.send(text: text)
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
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 60) }

            Text(message.content)
                .font(.system(size: 15, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(isUser ? .trailing : .leading)
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
