//
//  AIAssistantViewModel.swift
//  WorkSurvivalGuide
//

import Foundation
import Combine

// MARK: - Chat Message Model

struct AssistantMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let timestamp = Date()

    enum MessageRole { case user, assistant }
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

    // Immutable context
    let sessionId: String
    let skillCard: SkillCard

    init(sessionId: String, skillCard: SkillCard) {
        self.sessionId = sessionId
        self.skillCard = skillCard
        self.skillName = skillCard.skillName
    }

    // MARK: - Public API

    /// 页面出现时自动触发首条 AI 开场白
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

    // MARK: - Private

    private func streamRequest(message: String) {
        suggestions = []
        isStreaming = true
        streamingText = ""
        errorMessage = nil

        let history: [[String: String]] = messages.map { msg in
            ["role": msg.role == .user ? "user" : "assistant",
             "content": msg.content]
        }

        NetworkManager.shared.streamAssistantChat(
            sessionId: sessionId,
            skillId: skillCard.skillId,
            message: message,
            history: history,
            onMeta: { [weak self] skillName, memoryUsed in
                self?.skillName = skillName
                self?.memoryUsed = memoryUsed
            },
            onToken: { [weak self] token in
                self?.streamingText += token
            },
            onSuggestions: { [weak self] items in
                self?.suggestions = items
            },
            onDone: { [weak self] in
                guard let self else { return }
                if !streamingText.isEmpty {
                    messages.append(AssistantMessage(role: .assistant, content: streamingText))
                }
                streamingText = ""
                isStreaming = false
            },
            onError: { [weak self] err in
                self?.streamingText = ""
                self?.isStreaming = false
                self?.errorMessage = err
            }
        )
    }
}
