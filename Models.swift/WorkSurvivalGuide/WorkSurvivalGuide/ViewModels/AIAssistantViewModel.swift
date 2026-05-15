//
//  AIAssistantViewModel.swift
//  WorkSurvivalGuide
//

import Foundation
import Combine

// MARK: - Chat Message Model

struct AssistantMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date

    init(role: MessageRole, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }

    enum MessageRole: String, Codable { case user, assistant }
}

// MARK: - Persistence

private struct ChatHistory: Codable {
    let savedAt: Date
    let messages: [AssistantMessage]
}

private enum ChatHistoryStore {
    static let ttl: TimeInterval = 7 * 24 * 3600   // 7 天
    static let maxMessages = 20

    static func key(sessionId: String, skillId: String) -> String {
        "assistant_chat_\(sessionId)_\(skillId)"
    }

    static func load(sessionId: String, skillId: String) -> [AssistantMessage] {
        let k = key(sessionId: sessionId, skillId: skillId)
        guard let data = UserDefaults.standard.data(forKey: k),
              let history = try? JSONDecoder().decode(ChatHistory.self, from: data),
              Date().timeIntervalSince(history.savedAt) < ttl
        else { return [] }
        return history.messages
    }

    static func save(_ messages: [AssistantMessage], sessionId: String, skillId: String) {
        guard !messages.isEmpty else { return }
        let k = key(sessionId: sessionId, skillId: skillId)
        let trimmed = Array(messages.suffix(maxMessages))
        let history = ChatHistory(savedAt: Date(), messages: trimmed)
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: k)
        }
    }

    static func clear(sessionId: String, skillId: String) {
        UserDefaults.standard.removeObject(forKey: key(sessionId: sessionId, skillId: skillId))
    }
}

// MARK: - ViewModel

@MainActor
final class AIAssistantViewModel: ObservableObject {

    // Published state
    @Published var messages: [AssistantMessage] = []
    @Published var streamingText: String = ""
    @Published var isStreaming: Bool = false
    @Published var suggestions: [String] = []
    @Published var skillName: String = ""
    @Published var memoryUsed: Bool = false
    @Published var errorMessage: String? = nil
    /// 本次打开时是否恢复了历史记录
    @Published var isRestored: Bool = false

    // Immutable context
    let sessionId: String
    let skillCard: SkillCard

    private var streamTask: Task<Void, Never>?

    init(sessionId: String, skillCard: SkillCard) {
        self.sessionId = sessionId
        self.skillCard = skillCard
        self.skillName = skillCard.skillName

        // 恢复历史记录
        let saved = ChatHistoryStore.load(sessionId: sessionId, skillId: skillCard.skillId)
        if !saved.isEmpty {
            self.messages = saved
            self.isRestored = true
        }
    }

    // MARK: - Public API

    /// 页面出现时自动触发首条 AI 开场白（仅首次，历史恢复时跳过）
    func initSession() {
        guard messages.isEmpty, !isStreaming else { return }
        streamRequest(message: "__INIT__")
    }

    /// 用户发送文字消息
    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        messages.append(AssistantMessage(role: .user, content: trimmed))
        streamRequest(message: trimmed)
    }

    /// 点击猜你想问
    func selectSuggestion(_ question: String) {
        guard !isStreaming else { return }
        send(text: question)
    }

    /// 停止当前生成，保留已输出内容
    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        if !streamingText.isEmpty {
            messages.append(AssistantMessage(role: .assistant, content: streamingText))
            persistMessages()
        }
        streamingText = ""
        isStreaming = false
    }

    /// 手动清除历史，重新开始
    func clearHistory() {
        messages = []
        suggestions = []
        isRestored = false
        ChatHistoryStore.clear(sessionId: sessionId, skillId: skillCard.skillId)
        streamRequest(message: "__INIT__")
    }

    // MARK: - Private

    private func persistMessages() {
        ChatHistoryStore.save(messages, sessionId: sessionId, skillId: skillCard.skillId)
    }

    private func streamRequest(message: String) {
        streamTask?.cancel()
        suggestions = []
        isStreaming = true
        streamingText = ""
        errorMessage = nil

        let history: [[String: String]] = messages.map { msg in
            ["role": msg.role == .user ? "user" : "assistant",
             "content": msg.content]
        }

        streamTask = NetworkManager.shared.streamAssistantChat(
            sessionId: sessionId,
            skillId: skillCard.skillId,
            message: message,
            history: history,
            onMeta: { [weak self] skillName, memoryUsed in
                Task { @MainActor [weak self] in
                    self?.skillName = skillName
                    self?.memoryUsed = memoryUsed
                }
            },
            onToken: { [weak self] token in
                Task { @MainActor [weak self] in
                    self?.streamingText += token
                }
            },
            onSuggestions: { [weak self] items in
                Task { @MainActor [weak self] in
                    self?.suggestions = items
                }
            },
            onDone: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !self.streamingText.isEmpty {
                        self.messages.append(AssistantMessage(role: .assistant, content: self.streamingText))
                    }
                    self.streamingText = ""
                    self.isStreaming = false
                    self.persistMessages()   // 每轮结束后持久化
                }
            },
            onError: { [weak self] err in
                Task { @MainActor [weak self] in
                    self?.streamingText = ""
                    self?.isStreaming = false
                    self?.errorMessage = err
                }
            }
        )
    }
}
