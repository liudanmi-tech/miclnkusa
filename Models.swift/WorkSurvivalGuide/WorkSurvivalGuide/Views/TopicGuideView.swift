//
//  TopicGuideView.swift
//  WorkSurvivalGuide
//
//  AI Chat 引导面板：6 个板块卡片 + 点击后展示 3 条 topic 气泡
//  新用户：本地 JSON 随机取 3 条
//  老用户：服务端根据历史记忆个性化生成
//

import SwiftUI

// MARK: - 本地 JSON 数据模型

private struct GenZModuleData: Decodable {
    let modules: [GenZModule]
}

private struct GenZModule: Decodable {
    let id: String
    let label: String
    let emoji: String
    let color: String
    let tagline: String
    let topics: [GenZTopic]
}

private struct GenZTopic: Decodable {
    let id: String
    let topic: String
    let opening_question: String
    let tags: [String]
}

// MARK: - 本地 JSON 加载器（单例，懒加载）

private final class GenZTopicStore {
    static let shared = GenZTopicStore()
    let modules: [GenZModule]

    private init() {
        guard let url = Bundle.main.url(forResource: "genz_topics", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(GenZModuleData.self, from: data)
        else {
            modules = []
            return
        }
        modules = decoded.modules
    }

    func module(id: String) -> GenZModule? {
        modules.first { $0.id == id }
    }

    /// 从本地 JSON 取 3 条 opening_question（按 usedIndex 轮换）
    func nextTopics(moduleId: String, count: Int = 3) -> [String] {
        guard let mod = module(id: moduleId), !mod.topics.isEmpty else { return [] }
        let key = "chat_topic_idx_\(moduleId)"
        let startIdx = UserDefaults.standard.integer(forKey: key)
        var result: [String] = []
        let total = mod.topics.count
        for i in 0..<count {
            let idx = (startIdx + i) % total
            result.append(mod.topics[idx].opening_question)
        }
        // 存下次起点（推进 count 步，但不超过 total）
        UserDefaults.standard.set((startIdx + count) % total, forKey: key)
        return result
    }
}

// MARK: - TopicGuideView

struct TopicGuideView: View {
    /// 用户点击气泡后回调，参数：(moduleId, topicText)
    let onSendTopic: (String, String) -> Void

    @State private var selectedModuleId: String? = nil
    @State private var topicBubbles: [String] = []
    @State private var isLoadingTopics = false
    @State private var bubblesVisible = false   // 气泡依次出现的动画开关

    private let store = GenZTopicStore.shared

    // 6 个模块定义（顺序固定，与设计图一致）
    private let moduleIds = ["work", "school", "romance", "friends_family", "money_future", "body_emotions"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── 6张板块卡片 ──
            moduleGrid
                .padding(.horizontal, 16)
                .padding(.top, 12)

            // ── 分割线 ──
            if selectedModuleId != nil {
                Divider()
                    .background(Color.white.opacity(0.12))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            // ── Topic 气泡区 ──
            topicBubblesArea
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
    }

    // MARK: - Module Grid

    private var moduleGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
        ]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(moduleIds, id: \.self) { moduleId in
                if let mod = store.module(id: moduleId) {
                    ModuleCardView(
                        module: mod,
                        isSelected: selectedModuleId == moduleId
                    )
                    .onTapGesture {
                        handleModuleTap(moduleId)
                    }
                }
            }
        }
    }

    // MARK: - Topic Bubbles

    @ViewBuilder
    private var topicBubblesArea: some View {
        if isLoadingTopics {
            // 骨架加载态：3 条占位动画条
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    ShimmerBubble()
                        .opacity(bubblesVisible ? 1 : 0)
                        .animation(.easeIn(duration: 0.2).delay(Double(i) * 0.08), value: bubblesVisible)
                }
            }
            .onAppear { bubblesVisible = true }
            .onDisappear { bubblesVisible = false }
        } else if !topicBubbles.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(topicBubbles.enumerated()), id: \.offset) { idx, question in
                    TopicBubbleButton(
                        text: question,
                        accentColor: accentColor(for: selectedModuleId)
                    ) {
                        onSendTopic(selectedModuleId ?? "", question)
                    }
                    .opacity(bubblesVisible ? 1 : 0)
                    .offset(y: bubblesVisible ? 0 : 12)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75).delay(Double(idx) * 0.08), value: bubblesVisible)
                }
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - Logic

    private func handleModuleTap(_ moduleId: String) {
        guard moduleId != selectedModuleId else { return }
        selectedModuleId = moduleId
        topicBubbles = []
        bubblesVisible = false
        isLoadingTopics = true

        // 判断新用户 vs 老用户
        let usedKey = "chat_used_modules"
        let usedModules = UserDefaults.standard.stringArray(forKey: usedKey) ?? []
        let isReturning = usedModules.contains(moduleId)

        if isReturning {
            // 老用户：调服务端 API
            let lang = Locale.preferredLanguages.first ?? "en"
            Task {
                do {
                    let resp = try await NetworkManager.shared.getChatTopics(
                        module: moduleId, userLanguage: lang
                    )
                    await MainActor.run {
                        if selectedModuleId == moduleId {   // 防止用户快速切换时覆盖错误模块
                            if resp.source == "memory" && !resp.topics.isEmpty {
                                topicBubbles = resp.topics
                            } else {
                                // 服务端回退 → 用本地 JSON
                                topicBubbles = store.nextTopics(moduleId: moduleId)
                            }
                            isLoadingTopics = false
                            bubblesVisible = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                bubblesVisible = true
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        if selectedModuleId == moduleId {
                            topicBubbles = store.nextTopics(moduleId: moduleId)
                            isLoadingTopics = false
                            bubblesVisible = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                bubblesVisible = true
                            }
                        }
                    }
                }
            }
        } else {
            // 新用户：本地 JSON，立即展示
            let topics = store.nextTopics(moduleId: moduleId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if selectedModuleId == moduleId {
                    topicBubbles = topics
                    isLoadingTopics = false
                    bubblesVisible = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        bubblesVisible = true
                    }
                }
            }
        }
    }

    private func accentColor(for moduleId: String?) -> Color {
        guard let id = moduleId, let mod = store.module(id: id) else {
            return Color(hex: "#6C5CE7")
        }
        return Color(hex: mod.color)
    }
}

// MARK: - 板块卡片

private struct ModuleCardView: View {
    let module: GenZModule
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(module.emoji)
                .font(.system(size: 32))
            Text(module.label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .rounded))
                .foregroundColor(.white.opacity(isSelected ? 1.0 : 0.75))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 80)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color(hex: "#2A2440") : Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color(hex: module.color) : Color.clear, lineWidth: 2)
                )
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Topic 气泡按钮

private struct TopicBubbleButton: View {
    let text: String
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // 左侧彩色竖线 accent
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.leading, 14)
                    .padding(.vertical, 4)

                Text(text)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
                    .multilineTextAlignment(.leading)
                    .padding(.leading, 10)
                    .padding(.trailing, 14)
                    .padding(.vertical, 12)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.09))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 骨架加载占位

private struct ShimmerBubble: View {
    @State private var shimmerOffset: CGFloat = -200

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.07))
                .frame(height: 48)

            // shimmer 扫光
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.12), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 120)
                .offset(x: shimmerOffset + geo.size.width * 0.3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .frame(height: 48)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                shimmerOffset = 400
            }
        }
    }
}
