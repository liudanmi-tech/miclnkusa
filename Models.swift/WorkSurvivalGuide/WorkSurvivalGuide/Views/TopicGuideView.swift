//
//  TopicGuideView.swift
//  WorkSurvivalGuide
//
//  AI Chat 引导面板：6 个板块卡片 + 点击后展示 3 条 topic 气泡
//  模块基础信息（emoji/label/color）硬编码在 Swift，永远可显示
//  20 条 topics 从 Cloudflare R2 拉取，UserDefaults 缓存供离线使用
//

import SwiftUI

// MARK: - 静态模块定义（硬编码，UI 常量）

private struct ModuleDef {
    let id: String
    let label: String
    let emoji: String
    let color: String   // hex
}

private let kModules: [ModuleDef] = [
    ModuleDef(id: "work",           label: "Work",             emoji: "💼", color: "#6C5CE7"),
    ModuleDef(id: "school",         label: "School",           emoji: "📚", color: "#0984E3"),
    ModuleDef(id: "romance",        label: "Romance / Dating", emoji: "💔", color: "#E17055"),
    ModuleDef(id: "friends_family", label: "Friends / Family", emoji: "👥", color: "#00B894"),
    ModuleDef(id: "money_future",   label: "Money / Future",   emoji: "🤝", color: "#FDCB6E"),
    ModuleDef(id: "body_emotions",  label: "Body / Emotions",  emoji: "🫀", color: "#FD79A8"),
]

// MARK: - R2 Topic Store（Cloudflare R2 拉取 20 条 topics，UserDefaults 离线缓存）

private struct GenZModuleData: Decodable {
    let modules: [GenZModuleJSON]
}
private struct GenZModuleJSON: Decodable {
    let id: String
    let topics: [GenZTopicJSON]
}
private struct GenZTopicJSON: Decodable {
    let opening_question: String
}

private final class GenZTopicStore {
    static let shared = GenZTopicStore()

    private static let r2URL    = "https://pub-8a9e994d008c4d3e875ef722bded6ab5.r2.dev/static/genz_topics.json"
    private static let cacheKey = "genz_topics_cache_v1"

    /// moduleId → [opening_question]
    private(set) var topicsMap: [String: [String]] = [:]
    private var isFetching = false

    private init() {
        loadFromCache()
    }

    private func loadFromCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let decoded = try? JSONDecoder().decode(GenZModuleData.self, from: data) else { return }
        topicsMap = Dictionary(uniqueKeysWithValues: decoded.modules.map {
            ($0.id, $0.topics.map(\.opening_question))
        })
    }

    func fetchIfNeeded() async {
        guard topicsMap.isEmpty, !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        guard let url = URL(string: Self.r2URL) else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(GenZModuleData.self, from: data)
            let map = Dictionary(uniqueKeysWithValues: decoded.modules.map {
                ($0.id, $0.topics.map(\.opening_question))
            })
            await MainActor.run { self.topicsMap = map }
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        } catch {
            // 网络失败：有缓存则已有数据，无缓存则 topicsMap 为空（下次重试）
        }
    }

    /// 按轮换索引取 count 条 topic（避免每次看到相同问题）
    func nextTopics(moduleId: String, count: Int = 3) -> [String] {
        guard let topics = topicsMap[moduleId], !topics.isEmpty else { return [] }
        let key = "chat_topic_idx_\(moduleId)"
        let start = UserDefaults.standard.integer(forKey: key)
        let total = topics.count
        let result = (0..<count).map { topics[(start + $0) % total] }
        UserDefaults.standard.set((start + count) % total, forKey: key)
        return result
    }
}

// MARK: - TopicGuideView

struct TopicGuideView: View {
    /// 用户点击气泡后回调 (moduleId, topicText)
    let onSendTopic: (String, String) -> Void

    @State private var selectedId: String? = nil
    @State private var topicBubbles: [String] = []
    @State private var isLoadingTopics = false
    @State private var bubblesVisible = false

    private let store = GenZTopicStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── 6张板块卡片（永远显示，不依赖 R2）──
            moduleGrid
                .padding(.horizontal, 16)
                .padding(.top, 12)

            // ── 分割线 ──
            if selectedId != nil {
                Divider()
                    .background(Color.white.opacity(0.12))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            // ── Topic 气泡 ──
            topicBubblesArea
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
        .task {
            // 后台静默拉取 R2 topics（不阻塞 UI）
            await store.fetchIfNeeded()
        }
    }

    // MARK: Grid

    private var moduleGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(kModules, id: \.id) { mod in
                ModuleCardView(mod: mod, isSelected: selectedId == mod.id)
                    .onTapGesture { handleTap(mod.id) }
            }
        }
    }

    // MARK: Bubbles

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
                ForEach(Array(topicBubbles.enumerated()), id: \.offset) { idx, q in
                    TopicBubbleButton(text: q, accentColor: accentColor(for: selectedId)) {
                        onSendTopic(selectedId ?? "", q)
                    }
                    .opacity(bubblesVisible ? 1 : 0)
                    .offset(y: bubblesVisible ? 0 : 12)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75).delay(Double(idx) * 0.08),
                               value: bubblesVisible)
                }
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: Logic

    private func handleTap(_ moduleId: String) {
        guard moduleId != selectedId else { return }
        selectedId = moduleId
        topicBubbles = []
        bubblesVisible = false
        isLoadingTopics = true

        if store.topicsMap.isEmpty {
            // R2 还没加载完成，先发起拉取再展示
            Task {
                await store.fetchIfNeeded()
                await MainActor.run {
                    guard selectedId == moduleId else { return }
                    setTopicsFromLocal(moduleId)
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard selectedId == moduleId else { return }
                setTopicsFromLocal(moduleId)
            }
        }
    }

    private func setTopicsFromLocal(_ moduleId: String) {
        let topics = store.nextTopics(moduleId: moduleId)
        if topics.isEmpty {
            // R2 尚未就绪且无缓存，展示一条引导文案兜底
            topicBubbles = ["Tell me what's been on your mind lately..."]
        } else {
            topicBubbles = topics
        }
        showBubbles()
    }

    private func showBubbles() {
        isLoadingTopics = false
        bubblesVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { bubblesVisible = true }
    }

    private func accentColor(for moduleId: String?) -> Color {
        guard let id = moduleId,
              let mod = kModules.first(where: { $0.id == id }) else {
            return Color(hex: "#6C5CE7")
        }
        return Color(hex: mod.color)
    }
}

// MARK: - 板块卡片

private struct ModuleCardView: View {
    let mod: ModuleDef
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(mod.emoji)
                .font(.system(size: 32))
            Text(mod.label)
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
                        .stroke(isSelected ? Color(hex: mod.color) : Color.clear, lineWidth: 2)
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
            RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)).frame(height: 48)
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
