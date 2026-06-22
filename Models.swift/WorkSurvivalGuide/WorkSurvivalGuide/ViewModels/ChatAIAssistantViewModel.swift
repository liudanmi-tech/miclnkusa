//
//  ChatAIAssistantViewModel.swift
//  WorkSurvivalGuide
//
//  对话式 AI 助手 ViewModel（chat session 模式，无需录音）
//

import Foundation
import Combine

// MARK: - Chat Persistence

private struct ChatHistoryPersistence: Codable {
    let savedAt: Date
    let messages: [AssistantMessage]
}

private enum ChatSessionStore {
    static let ttl: TimeInterval = 7 * 24 * 3600  // 7 天
    static let maxMessages = 40

    static func key(_ sessionId: String) -> String {
        "chat_session_\(sessionId)"
    }

    static func load(_ sessionId: String) -> [AssistantMessage] {
        guard let data = UserDefaults.standard.data(forKey: key(sessionId)),
              let history = try? JSONDecoder().decode(ChatHistoryPersistence.self, from: data),
              Date().timeIntervalSince(history.savedAt) < ttl
        else { return [] }
        return history.messages
    }

    static func save(_ messages: [AssistantMessage], sessionId: String) {
        guard !messages.isEmpty else { return }
        let trimmed = Array(messages.suffix(maxMessages))
        let h = ChatHistoryPersistence(savedAt: Date(), messages: trimmed)
        if let data = try? JSONEncoder().encode(h) {
            UserDefaults.standard.set(data, forKey: key(sessionId))
        }
    }

    static func clear(_ sessionId: String) {
        UserDefaults.standard.removeObject(forKey: key(sessionId))
    }
}

// MARK: - ViewModel

@MainActor
final class ChatAIAssistantViewModel: ObservableObject {

    // MARK: Published State

    @Published var messages: [AssistantMessage] = []
    @Published var streamingText: String = ""         // 服务端已收到的全量文本（内部追踪）
    @Published var displayedStreamingText: String = "" // 打字机逐字显示的文本（UI 绑定）
    @Published var isStreaming: Bool = false
    @Published var suggestions: [String] = []
    /// 技能标签（收到 skill_tags SSE 后更新）
    @Published var skillTags: [String] = []
    /// true = 第1条消息已发出，等待 skill_tags 返回
    @Published var isMatchingSkills: Bool = false
    /// 当前生效的技能 ID（由 skill_tags 更新，skill_drift 未实现时保持不变）
    @Published var currentSkillId: String = "emotion_recognition"
    /// 最后一轮 meta 事件的情绪状态，退出时作为 Moment 卡片 emoji 占位
    @Published var lastMoodState: String? = nil
    @Published var errorMessage: String? = nil
    @Published var showPaywall: Bool = false
    @Published var showProLimitToast: Bool = false
    /// baseline_init SSE：当前阶段（"ask" / "save"），nil 表示无 baseline 流程
    @Published var baselinePhase: String? = nil
    /// 重入时从服务端拉取历史中
    @Published var isLoadingHistory: Bool = false

    // MARK: Immutable

    let sessionId: String

    // MARK: Private

    private var streamTask: Task<Void, Never>?
    private var compensationTask: Task<Void, Never>?
    private var typewriterTask: Task<Void, Never>?    // 打字机 Task
    private var hasReceivedSkillTags: Bool = false
    private var pendingMemeURL: String?

    // MARK: Init

    init(sessionId: String) {
        self.sessionId = sessionId
        let saved = ChatSessionStore.load(sessionId)
        if !saved.isEmpty {
            self.messages = saved
        }
    }

    // MARK: - Public API

    /// 对话是否为空（决定退出时是否展示 ActionSheet）
    var isConversationEmpty: Bool { messages.isEmpty }

    /// 重入时从服务端拉取历史对话（若 UserDefaults 缓存已有则跳过）
    func loadHistory() async {
        guard messages.isEmpty else { return }  // 缓存命中，无需拉取
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let history = try await NetworkManager.shared.fetchChatHistory(sessionId: sessionId)
            guard !history.isEmpty else { return }
            let loaded: [AssistantMessage] = history.compactMap { dict in
                guard let role = dict["role"], let content = dict["content"] else { return nil }
                return AssistantMessage(role: role == "user" ? .user : .assistant, content: content)
            }
            messages = loaded
            ChatSessionStore.save(messages, sessionId: sessionId)
        } catch {
            print("⚠️ [ChatAIAssistantViewModel] loadHistory failed: \(error.localizedDescription)")
        }
    }

    /// 构建服务端 close / generate-image 接口所需的 conversation 数组
    func conversationForServer() -> [[String: String]] {
        messages.compactMap { msg -> [String: String]? in
            guard !msg.isMeme else { return nil }
            return ["role": msg.role == .user ? "user" : "assistant",
                    "content": msg.content]
        }
    }

    /// 标记某模块已被使用（TopicGuideView 回调）
    func markModuleUsed(_ moduleId: String) {
        let key = "chat_used_modules"
        var used = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !used.contains(moduleId) {
            used.append(moduleId)
            UserDefaults.standard.set(used, forKey: key)
        }
    }

    /// 发送一条消息
    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        // 第1条消息启动技能匹配指示器
        if messages.isEmpty {
            isMatchingSkills = true
            hasReceivedSkillTags = false
        }

        messages.append(AssistantMessage(role: .user, content: trimmed))
        streamRequest(message: trimmed)
    }

    /// 发送语音消息。fileURL 用于消息气泡本地回放；audioData 用于上传服务器。
    func sendAudio(audioData: Data, fileURL: URL) {
        guard !isStreaming else { return }

        if messages.isEmpty {
            isMatchingSkills = true
            hasReceivedSkillTags = false
        }

        messages.append(.voice(fileURL: fileURL.path))
        streamAudioRequest(audioData: audioData)
    }

    /// 停止当前生成，保留已输出内容
    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        typewriterTask?.cancel()
        typewriterTask = nil
        if !streamingText.isEmpty {
            messages.append(AssistantMessage(role: .assistant, content: streamingText))
            persistMessages()
        }
        streamingText = ""
        displayedStreamingText = ""
        isStreaming = false
        pendingMemeURL = nil
    }

    // MARK: - Private

    private func persistMessages() {
        ChatSessionStore.save(messages, sessionId: sessionId)
    }

    private func streamRequest(message: String) {
        streamTask?.cancel()
        typewriterTask?.cancel()
        typewriterTask = nil
        suggestions = []
        isStreaming = true
        streamingText = ""
        displayedStreamingText = ""
        errorMessage = nil

        // history = 全部已有消息（含刚追加的用户消息，与 AIAssistantViewModel 保持一致）
        let history: [[String: String]] = messages.compactMap { msg in
            guard !msg.isMeme else { return nil }
            return ["role": msg.role == .user ? "user" : "assistant",
                    "content": msg.content]
        }

        let deviceLanguage = Locale.preferredLanguages.first?.components(separatedBy: "-").first ?? "en"

        streamTask = NetworkManager.shared.streamAssistantChat(
            sessionId: sessionId,
            skillId: currentSkillId,
            message: message,
            history: history,
            isChatSession: true,
            userLanguage: deviceLanguage,
            onMeta: { [weak self] _, _ in
                // 主字段由 onMoodState 处理
                _ = self
            },
            onToken: { [weak self] token in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.streamingText += token
                    self.ensureTypewriterRunning()
                }
            },
            onSuggestions: { [weak self] items in
                Task { @MainActor [weak self] in
                    self?.suggestions = items
                }
            },
            onSkillTags: { [weak self] tags in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // tags 是 skill_id 列表（如 ["salary_negotiation", "emotion_recognition"]）
                    // 转为可读名称用于 UI 显示
                    self.skillTags = tags.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
                    self.isMatchingSkills = false
                    self.hasReceivedSkillTags = true
                    self.compensationTask?.cancel()
                    // 用第一个匹配到的技能 ID 更新后续请求的 skillId（emotion_recognition 排最后）
                    if let firstId = tags.first(where: { $0 != "emotion_recognition" }) ?? tags.first,
                       !firstId.isEmpty {
                        self.currentSkillId = firstId
                    }
                }
            },
            onMoodState: { [weak self] mood in
                Task { @MainActor [weak self] in
                    if let mood = mood { self?.lastMoodState = mood }
                }
            },
            onBaselineInit: { [weak self] _, phase in
                Task { @MainActor [weak self] in
                    self?.baselinePhase = phase
                }
            },
            onDone: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // 停止打字机，立即同步到完整文本
                    self.typewriterTask?.cancel()
                    self.typewriterTask = nil
                    if !self.streamingText.isEmpty {
                        self.messages.append(
                            AssistantMessage(role: .assistant, content: self.streamingText)
                        )
                    }
                    if let memeURL = self.pendingMemeURL {
                        self.messages.append(.meme(url: memeURL))
                        self.pendingMemeURL = nil
                    }
                    self.streamingText = ""
                    self.displayedStreamingText = ""
                    self.isStreaming = false
                    self.persistMessages()

                    // 补偿机制：第1轮若 skill_tags 未到，轮询 strategy
                    if !self.hasReceivedSkillTags && self.messages.count <= 2 {
                        self.startSkillTagsCompensation()
                    }
                }
            },
            onError: { [weak self] err in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.typewriterTask?.cancel()
                    self.typewriterTask = nil
                    self.streamingText = ""
                    self.displayedStreamingText = ""
                    self.isStreaming = false
                    if err == "chat_limit_reached" {
                        if SubscriptionManager.shared.isPro {
                            self.showProLimitToast = true
                        } else {
                            self.showPaywall = true
                        }
                    } else {
                        self.errorMessage = err
                    }
                }
            }
        )
    }

    /// 语音消息请求（复用 streamRequest 的回调链）
    private func streamAudioRequest(audioData: Data) {
        streamTask?.cancel()
        typewriterTask?.cancel()
        typewriterTask = nil
        suggestions = []
        isStreaming = true
        streamingText = ""
        displayedStreamingText = ""
        errorMessage = nil

        // history 包含刚追加的 "🎤 Voice message" user bubble
        let history: [[String: String]] = messages.compactMap { msg in
            guard !msg.isMeme else { return nil }
            return ["role": msg.role == .user ? "user" : "assistant",
                    "content": msg.content]
        }

        let deviceLanguage = Locale.preferredLanguages.first?.components(separatedBy: "-").first ?? "en"

        streamTask = NetworkManager.shared.streamAssistantChatAudio(
            sessionId: sessionId,
            skillId: currentSkillId,
            history: history,
            userLanguage: deviceLanguage,
            audioData: audioData,
            onTranscript: { [weak self] text in
                Task { @MainActor [weak self] in
                    guard let self, !text.isEmpty else { return }
                    // 用转写文本替换语音消息的占位内容，使 generate-image-from-chat 能获取真实内容
                    if let idx = self.messages.lastIndex(where: { $0.isVoice }) {
                        self.messages[idx] = self.messages[idx].withTranscript(text)
                    }
                }
            },
            onToken: { [weak self] token in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.streamingText += token
                    self.ensureTypewriterRunning()
                }
            },
            onSuggestions: { [weak self] items in
                Task { @MainActor [weak self] in self?.suggestions = items }
            },
            onDone: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.typewriterTask?.cancel()
                    self.typewriterTask = nil
                    if !self.streamingText.isEmpty {
                        self.messages.append(AssistantMessage(role: .assistant, content: self.streamingText))
                    }
                    if let memeURL = self.pendingMemeURL {
                        self.messages.append(.meme(url: memeURL))
                        self.pendingMemeURL = nil
                    }
                    self.streamingText = ""
                    self.displayedStreamingText = ""
                    self.isStreaming = false
                    self.isMatchingSkills = false
                    self.persistMessages()
                }
            },
            onError: { [weak self] err in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.typewriterTask?.cancel()
                    self.typewriterTask = nil
                    self.streamingText = ""
                    self.displayedStreamingText = ""
                    self.isStreaming = false
                    if err == "chat_limit_reached" {
                        if SubscriptionManager.shared.isPro {
                            self.showProLimitToast = true
                        } else {
                            self.showPaywall = true
                        }
                    } else {
                        self.errorMessage = err
                    }
                }
            }
        )
    }

    // MARK: - Typewriter Effect

    /// 启动打字机 Task（若已在运行则不重复启动）。
    /// 每 20ms 从 streamingText 取一个字符追加到 displayedStreamingText，
    /// 与服务端推送速率完全解耦，保证流畅逐字显示。
    private func ensureTypewriterRunning() {
        guard typewriterTask == nil else { return }
        typewriterTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.displayedStreamingText.count < self.streamingText.count {
                let idx = self.streamingText.index(
                    self.streamingText.startIndex,
                    offsetBy: self.displayedStreamingText.count
                )
                self.displayedStreamingText.append(self.streamingText[idx])
                try? await Task.sleep(nanoseconds: 20_000_000)  // 20ms ≈ 50字/秒
            }
            self.typewriterTask = nil
        }
    }

    // MARK: - Skill Tags Compensation

    private func startSkillTagsCompensation() {
        compensationTask?.cancel()
        compensationTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            guard !Task.isCancelled, !hasReceivedSkillTags else { return }
            await fetchSkillTagsFromServer(retryCount: 1)
        }
    }

    private func fetchSkillTagsFromServer(retryCount: Int) async {
        do {
            let strategy = try await NetworkManager.shared.getStrategyAnalysis(sessionId: sessionId)
            let tags = (strategy.skillCards ?? []).map { $0.skillName }
            if !tags.isEmpty {
                skillTags = tags
                isMatchingSkills = false
                hasReceivedSkillTags = true
            } else if retryCount > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await fetchSkillTagsFromServer(retryCount: retryCount - 1)
            } else {
                isMatchingSkills = false
            }
        } catch {
            if retryCount > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await fetchSkillTagsFromServer(retryCount: retryCount - 1)
            } else {
                isMatchingSkills = false
            }
        }
    }
}
