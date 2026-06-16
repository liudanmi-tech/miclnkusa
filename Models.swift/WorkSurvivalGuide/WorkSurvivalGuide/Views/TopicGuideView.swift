//
//  TopicGuideView.swift
//  WorkSurvivalGuide
//
//  AI Chat 引导面板：6 个板块卡片 + 点击后展示 3 条 topic 气泡
//  JSON 从 Cloudflare R2 拉取，UserDefaults 缓存供离线使用
//  新用户：本地缓存 JSON 随机轮换取 3 条
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

// MARK: - R2 Topic Store（Cloudflare R2 拉取，UserDefaults 离线缓存）

private final class GenZTopicStore {
    static let shared = GenZTopicStore()

    /// R2 公开 URL（生产 bucket，静态内容无需区分测试/生产）
    private static let r2URL = "https://pub-8a9e994d008c4d3e875ef722bded6ab5.r2.dev/static/genz_topics.json"
    private static let cacheKey = "genz_topics_cache_v1"

    private(set) var modules: [GenZModule] = []

    private init() {
        // 启动时从 UserDefaults 缓存恢复（离线可用）
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let decoded = try? JSONDecoder().decode(GenZModuleData.self, from: data) {
            modules = decoded.modules
        }
    }

    /// 从 R2 拉取最新数据，写入内存 + UserDefaults 缓存
    func fetchFromR2() async {
        guard let url = URL(string: Self.r2URL) else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(GenZModuleData.self, from: data)
            await MainActor.run { self.modules = decoded.modules }
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        } catch {
            // 网络失败：已有缓存则继续使用
        }
    }

    func module(id: String) -> GenZModule? {
        modules.first { $0.id == id }
    }

    /// 取 count 条 opening_question（按 usedIndex 轮换，避免重复）
    func nextTopics(moduleId: String, count: Int = 3) -> [String] {
        guard let mod = module(id: moduleId), !mod.topics.isEmpty else { return [] }
        let key = "chat_topic_idx_\(moduleId)"
        let startIdx = UserDefaults.standard.integer(forKey: key)
        let total = mod.topics.count
        let result = (0..<count).map { mod.topics[(startIdx + $0) % total].opening_question }
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
    @State private var bubblesVisible = false
    @State private var isStoreLoading = false   // R2 首次拉取中（无缓存时）

    private let store = GenZTopicStore.shared
    private let moduleIds = ["work", "school", "romance", "friends_family", "money_future", "body_emotions"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── 6张板块卡片 ──
            moduleGrid
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .opacity(isStoreLoading ? 0.4 : 1.0)
                .allowsHitTesting(!isStoreLoading)

            // ── 分割线（选中后出现）──
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
        .task {
            // 首次打开：无缓存时从 R2 拉取
            if store.modules.isEmpty {
                isStoreLoading = true
                await store.fetchFromR2()
                isStoreLoading = false
            }
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
                    ModuleCardView(module: mod, isSelected: selectedModuleId == moduleId)
                        .onTapGesture { handleModuleTap(moduleId) }
                } else {
                    // 数据还未加载时的占位卡片
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 80)
                }
            }
        }
    }

    // MARK: - Topic Bubbles

    @ViewBuilder
    private var topicBubblesArea: some View {
        if isLoadingTopics {
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

        let usedKey = "chat_used_modules"
        let usedModules = UserDefaults.standard.stringArray(forKey: usedKey) ?? []
        let isReturning = usedModules.contains(moduleId)
        let lang = Locale.preferredLanguages.first ?? "en"

        if isReturning {
            // 老用户：调服务端 API
            Task {
                do {
                    let resp = try await NetworkManager.shared.getChatTopics(module: moduleId, userLanguage: lang)
                    await MainActor.run {
                        guard selectedModuleId == moduleId else { return }
                        topicBubbles = (resp.source == "memory" && !resp.topics.isEmpty)
                            ? resp.topics
                            : store.nextTopics(moduleId: moduleId)
                        showBubbles()
                    }
                } catch {
                    await MainActor.run {
                        guard selectedModuleId == moduleId else { return }
                        topicBubbles = store.nextTopics(moduleId: moduleId)
                        showBubbles()
                    }
                }
            }
        } else {
            // 新用户：直接用本地缓存 JSON
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard selectedModuleId == moduleId else { return }
                topicBubbles = store.nextTopics(moduleId: moduleId)
                showBubbles()
            }
        }
    }

    private func showBubbles() {
        isLoadingTopics = false
        bubblesVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            bubblesVisible = true
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
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.09)))
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
            GeometryReader { geo in
                LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                               startPoint: .leading, endPoint: .trailing)
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
