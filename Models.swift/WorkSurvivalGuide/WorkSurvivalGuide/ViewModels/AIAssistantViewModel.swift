//
//  AIAssistantViewModel.swift
//  WorkSurvivalGuide
//

import Foundation
import Combine
import UIKit

// MARK: - Chat Message Model

struct AssistantMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    let memeURL: String?       // non-nil → 这是一条梗图消息（独立消息行）
    let skillName: String?     // AI 回复时关联的技能名，用于消息气泡标签
    let audioFileURL: String?  // non-nil → 这是一条语音消息，值为本地 .m4a 文件绝对路径

    var isMeme: Bool  { memeURL != nil }
    var isVoice: Bool { audioFileURL != nil }

    /// 普通文字消息
    init(role: MessageRole, content: String, skillName: String? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.memeURL = nil
        self.skillName = skillName
        self.audioFileURL = nil
    }

    /// 梗图消息工厂
    static func meme(url: String) -> AssistantMessage {
        AssistantMessage(id: UUID(), role: .assistant, content: "", timestamp: Date(),
                         memeURL: url, skillName: nil, audioFileURL: nil)
    }

    /// 语音消息工厂
    static func voice(fileURL: String) -> AssistantMessage {
        AssistantMessage(id: UUID(), role: .user, content: "[Voice message]", timestamp: Date(),
                         memeURL: nil, skillName: nil, audioFileURL: fileURL)
    }

    private init(id: UUID, role: MessageRole, content: String, timestamp: Date,
                 memeURL: String?, skillName: String?, audioFileURL: String?) {
        self.id = id; self.role = role; self.content = content
        self.timestamp = timestamp; self.memeURL = memeURL; self.skillName = skillName
        self.audioFileURL = audioFileURL
    }

    /// 返回一条 content 已更新为转写文本的副本（保留其他所有字段，用于语音消息转写）
    func withTranscript(_ text: String) -> AssistantMessage {
        AssistantMessage(id: id, role: role, content: text, timestamp: timestamp,
                         memeURL: memeURL, skillName: skillName, audioFileURL: audioFileURL)
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
        "assistant_chat_\(sessionId)"   // 同一录音下所有技能共享同一对话
    }

    // MARK: 追踪上次使用的 skillId，用于切换检测
    private static func lastSkillKey(sessionId: String) -> String {
        "assistant_last_skill_\(sessionId)"
    }
    static func saveLastSkill(_ skillId: String, sessionId: String) {
        UserDefaults.standard.set(skillId, forKey: lastSkillKey(sessionId: sessionId))
    }
    static func loadLastSkill(sessionId: String) -> String? {
        UserDefaults.standard.string(forKey: lastSkillKey(sessionId: sessionId))
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
        UserDefaults.standard.removeObject(forKey: lastSkillKey(sessionId: sessionId))
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
    @Published var showPaywall: Bool = false       // Free 用户超出轮数 → 弹订阅墙
    @Published var showProLimitToast: Bool = false // Pro 用户超出轮数 → 友好提示
    /// 本次打开时是否恢复了历史记录
    @Published var isRestored: Bool = false

    // Immutable context
    let sessionId: String
    let skillCard: SkillCard

    private var streamTask: Task<Void, Never>?
    private var pendingMemeURL: String?   // onMeme 暂存，onDone 时追加在文字之后

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

    /// 页面出现时自动触发开场白或技能切换回复
    func initSession() {
        guard !isStreaming else { return }
        if messages.isEmpty {
            // 首次进入：正常 __INIT__
            ChatHistoryStore.saveLastSkill(skillCard.skillId, sessionId: sessionId)
            streamRequest(message: "__INIT__")
        } else {
            // 有历史：检测是否切换了技能
            let lastSkillId = ChatHistoryStore.loadLastSkill(sessionId: sessionId)
            if lastSkillId != skillCard.skillId {
                ChatHistoryStore.saveLastSkill(skillCard.skillId, sessionId: sessionId)
                streamRequest(message: "__SWITCH__")
            }
            // 同一技能重新进入 → 静默恢复，不触发任何请求
        }
    }

    /// 用户发送文字消息（可附带图片，最多3张）
    func send(text: String, images: [UIImage] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty, !isStreaming else { return }
        let count = images.count
        let displayText = trimmed.isEmpty
            ? (count == 1 ? "（分享了一张图片）" : "（分享了\(count)张图片）")
            : trimmed
        messages.append(AssistantMessage(role: .user, content: displayText))
        streamRequest(message: trimmed.isEmpty ? "（图片消息）" : trimmed, images: images)
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
        pendingMemeURL = nil
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

    private func streamRequest(message: String, images: [UIImage] = []) {
        streamTask?.cancel()
        suggestions = []
        isStreaming = true
        streamingText = ""
        errorMessage = nil

        let history: [[String: String]] = messages.map { msg in
            ["role": msg.role == .user ? "user" : "assistant",
             "content": msg.content]
        }

        // 将图片压缩为 JPEG base64（最长边限制 1024px，减少 token 消耗）
        let imageBase64List: [String] = images.prefix(3).compactMap { img in
            let maxDim: CGFloat = 1024
            let scale = min(1.0, maxDim / max(img.size.width, img.size.height))
            let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: newSize)) }
            return resized.jpegData(compressionQuality: 0.75)?.base64EncodedString()
        }

        streamTask = NetworkManager.shared.streamAssistantChat(
            sessionId: sessionId,
            skillId: skillCard.skillId,
            message: message,
            history: history,
            imageBase64List: imageBase64List,
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
            onMeme: { [weak self] gifURL in
                Task { @MainActor [weak self] in
                    self?.pendingMemeURL = gifURL   // 暂存，等文字先 append
                }
            },
            onDone: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // 1. 先提交文字（带技能名标签）
                    if !self.streamingText.isEmpty {
                        self.messages.append(AssistantMessage(role: .assistant, content: self.streamingText, skillName: self.skillName))
                    }
                    // 2. 再追加梗图（文字之后）
                    if let memeURL = self.pendingMemeURL {
                        self.messages.append(.meme(url: memeURL))
                        self.pendingMemeURL = nil
                    }
                    self.streamingText = ""
                    self.isStreaming = false
                    self.persistMessages()
                }
            },
            onError: { [weak self] err in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.streamingText = ""
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
}
