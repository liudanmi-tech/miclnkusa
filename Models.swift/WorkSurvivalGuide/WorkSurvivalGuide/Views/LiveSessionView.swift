//
//  LiveSessionView.swift
//  WorkSurvivalGuide
//
//  Live Mode 实时录制界面
//
//  UI 结构（对应 conversation detail mockup）：
//    ┌─────────────────────────────────────────┐
//    │  Header：眼镜状态 / 计时器 / REC 指示   │
//    ├─────────────────────────────────────────┤
//    │  Summary（segment_context，有内容才显示）│
//    ├─────────────────────────────────────────┤
//    │  Chat 流（ChatItem 列表）                │
//    │    .turn      → 左/右气泡               │
//    │    .suggestion → 内联 AI tip            │
//    │    .skillCards → 内联技能卡片组          │
//    ├─────────────────────────────────────────┤
//    │  Stop bar                               │
//    └─────────────────────────────────────────┘
//

import SwiftUI

// MARK: - Chat Item Models（file-private）

private enum ChatItem: Identifiable {
    case turn(LiveTurnItem)
    case suggestion(SuggestionData)
    case skillCards(SkillBatchData)

    var id: String {
        switch self {
        case .turn(let t):       return "t-\(t.id)"
        case .suggestion(let d): return "s-\(d.id)"
        case .skillCards(let d): return "k-\(d.id)"
        }
    }
}

private struct SuggestionData: Identifiable {
    let id = UUID()
    let text: String
    let emotion: String
}

private struct SkillCardData: Identifiable {
    let id = UUID()
    let skillId: String
    let skillName: String
    let category: String
    let confidence: Double
    let advice: String
    let reminder: String
}

private struct SkillBatchData: Identifiable {
    let id = UUID()
    let cards: [SkillCardData]
}

// MARK: - Main View

struct LiveSessionView: View {

    /// 完成后回调（Speaker 确认完成后调用，调用方负责 dismiss）
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var liveManager = LiveSessionManager.shared
    @ObservedObject private var sseClient   = LiveSSEClient.shared

    // ── Session 生命周期 ────────────────────────────────────────────────────
    @State private var sessionId:  String?
    @State private var isStarting: Bool   = true
    @State private var startError: String?

    // ── 停止录音流程 ────────────────────────────────────────────────────────
    @State private var showStopAlert:      Bool = false
    @State private var isStopping:         Bool = false
    @State private var endResponse:        LiveSessionEndResponse?
    @State private var showSpeakerConfirm: Bool = false
    @State private var showProcessingDone: Bool = false

    // ── 聊天内容 ────────────────────────────────────────────────────────────
    @State private var chatItems:      [ChatItem] = []
    @State private var segmentContext: String     = ""

    // MARK: - body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let error = startError {
                startErrorView(error)
            } else if isStarting {
                startingView
            } else {
                mainContent
            }

            if showProcessingDone {
                processingOverlay
            }
        }
        .onAppear { startLiveSession() }
        .onDisappear { cleanupIfNeeded() }
        .alert("结束录音", isPresented: $showStopAlert) {
            Button("结束", role: .destructive) { beginStopFlow() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确认结束本次 Live 录音？")
        }
        .sheet(isPresented: $showSpeakerConfirm) {
            if let resp = endResponse, let sid = sessionId {
                SpeakerConfirmationSheet(
                    sessionId: sid,
                    speakerMappings: resp.speaker_mappings ?? [],
                    onCompleted: {
                        showSpeakerConfirm = false
                        showProcessingDone = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            onCompleted()
                            dismiss()
                        }
                    }
                )
            }
        }
    }

    // MARK: - 主内容

    private var mainContent: some View {
        VStack(spacing: 0) {
            headerBar

            if !segmentContext.isEmpty {
                summarySection
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.3), value: segmentContext.isEmpty)
            }

            chatArea
            stopBar
        }
    }

    // MARK: - 顶部状态栏

    private var headerBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(liveManager.isGlassesAvailable ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(liveManager.isGlassesAvailable ? "眼镜已连接" : "内置麦克风")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
            }

            Spacer()

            Text(formatElapsed(liveManager.elapsedSeconds))
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)

            Spacer()

            HStack(spacing: 4) {
                if liveManager.sessionState == .active {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("REC")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.red)
                } else {
                    ProgressView().scaleEffect(0.6).tint(.white)
                }
            }
            .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(white: 0.07))
    }

    // MARK: - Segment Summary 区域

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                Text("Summary")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .textCase(.uppercase)
            }
            Text(segmentContext)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.82))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.10))
    }

    // MARK: - Chat 区域

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if chatItems.isEmpty {
                        emptyState
                    } else {
                        ForEach(chatItems) { item in
                            chatItemView(item)
                                .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onChange(of: chatItems.count) { _ in
                if let last = chatItems.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chatItemView(_ item: ChatItem) -> some View {
        switch item {
        case .turn(let turn):
            TurnBubble(turn: turn)
        case .suggestion(let data):
            InlineSuggestionBubble(data: data)
        case .skillCards(let batch):
            VStack(spacing: 6) {
                ForEach(batch.cards) { card in
                    LiveSkillCardView(card: card)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.12))
            Text("等待对话开始…")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - 底部停止栏

    private var stopBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.08))
            HStack {
                Spacer()
                Button {
                    showStopAlert = true
                } label: {
                    HStack(spacing: 8) {
                        if isStopping {
                            ProgressView().tint(.white).scaleEffect(0.8)
                        } else {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 22))
                        }
                        Text(isStopping ? "正在结束…" : "结束录音")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.red.opacity(isStopping ? 0.5 : 0.85))
                    )
                }
                .disabled(isStopping)
                Spacer()
            }
            .padding(.vertical, 16)
            .background(Color(white: 0.05))
        }
    }

    // MARK: - 启动中 / 错误

    private var startingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(Color(hex: "#00D4FF"))
            Text("正在连接…")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func startErrorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text("启动失败")
                .font(.title3.bold())
                .foregroundColor(.white)
            Text(error)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Button("关闭") { dismiss() }
                .foregroundColor(Color(hex: "#00D4FF"))
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 处理中遮罩

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(Color(hex: "#00D4FF"))
                Text("正在生成分析报告…")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                Text("稍后可在历史记录中查看")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
    }

    // MARK: - 生命周期

    private func startLiveSession() {
        let token = KeychainManager.shared.getToken() ?? ""
        guard !token.isEmpty else {
            startError = "请先登录"
            isStarting = false
            return
        }

        Task {
            do {
                let resp = try await NetworkManager.shared.createLiveSession()
                let sid  = resp.session_id
                await MainActor.run {
                    sessionId  = sid
                    isStarting = false
                }
                LiveSessionManager.shared.startSession(sessionId: sid, token: token)
                LiveSSEClient.shared.connect(sessionId: sid, token: token)
                await MainActor.run { setupSSECallbacks() }
            } catch {
                await MainActor.run {
                    startError = error.localizedDescription
                    isStarting = false
                }
            }
        }
    }

    private func setupSSECallbacks() {
        // 转录 turn（来自 WebSocket）→ 追加到 chatItems
        LiveSessionManager.shared.onTranscript = { item in
            chatItems.append(.turn(item))
        }

        // AI 实时建议（来自 SSE suggestion）→ 追加内联 tip
        LiveSSEClient.shared.onSuggestion = { payload in
            let text    = payload["text"]        as? String ?? ""
            let emotion = payload["emotion_tag"] as? String ?? ""
            guard !text.isEmpty else { return }
            chatItems.append(.suggestion(SuggestionData(text: text, emotion: emotion)))
        }

        // 技能匹配结果（来自 SSE analysis_ready）→ 追加内联技能卡片
        LiveSSEClient.shared.onAnalysisReady = { payload in
            guard let rawCards = payload["skill_cards"] as? [[String: Any]],
                  !rawCards.isEmpty else { return }
            let cards = rawCards.compactMap { d -> SkillCardData? in
                guard let sid  = d["skill_id"]   as? String,
                      let name = d["skill_name"]  as? String else { return nil }
                return SkillCardData(
                    skillId:    sid,
                    skillName:  name,
                    category:   d["category"]   as? String ?? "",
                    confidence: d["confidence"] as? Double ?? 0,
                    advice:     d["advice"]     as? String ?? "",
                    reminder:   d["reminder"]   as? String ?? ""
                )
            }
            guard !cards.isEmpty else { return }
            chatItems.append(.skillCards(SkillBatchData(cards: cards)))
        }

        // Segment 摘要更新（来自 SSE segment_context）→ 更新顶部 Summary
        LiveSSEClient.shared.onSegmentContext = { payload in
            let text = payload["text"] as? String ?? ""
            guard !text.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                segmentContext = text
            }
        }
    }

    private func beginStopFlow() {
        guard let sid = sessionId else { return }
        isStopping = true
        liveManager.stopSession()
        sseClient.disconnect()

        Task {
            do {
                let resp = try await NetworkManager.shared.endLiveSession(sessionId: sid)
                await MainActor.run {
                    endResponse        = resp
                    isStopping         = false
                    showSpeakerConfirm = true
                }
            } catch {
                await MainActor.run {
                    isStopping         = false
                    showProcessingDone = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        onCompleted()
                        dismiss()
                    }
                }
            }
        }
    }

    private func cleanupIfNeeded() {
        if liveManager.sessionState == .active {
            liveManager.stopSession()
        }
        sseClient.disconnect()
    }

    private func formatElapsed(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - 转录气泡

private struct TurnBubble: View {

    let turn: LiveTurnItem

    private var isMe: Bool { turn.speaker == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isMe { Spacer(minLength: 48) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                if !isMe {
                    Text(displayLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.38))
                        .padding(.leading, 4)
                }
                Text(turn.text)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isMe
                                  ? Color(white: 0.20)
                                  : Color(white: 0.16))
                    )
                    .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
            }

            if !isMe { Spacer(minLength: 48) }
        }
    }

    private var displayLabel: String {
        let letters = ["A", "B", "C", "D", "E"]
        if let suffix = turn.speakerLabel.components(separatedBy: "_").last,
           let n = Int(suffix), n >= 1, n - 1 < letters.count {
            return "说话人\(letters[n - 1])"
        }
        return turn.speakerLabel
    }
}

// MARK: - 内联 AI 建议气泡

private struct InlineSuggestionBubble: View {

    let data: SuggestionData

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // AI 头像
            ZStack {
                Circle()
                    .fill(Color(white: 0.22))
                    .frame(width: 28, height: 28)
                Text("AI")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
            }

            HStack(alignment: .top, spacing: 6) {
                if !data.emotion.isEmpty {
                    Text(data.emotion)
                        .font(.system(size: 13))
                }
                Text(data.text)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.18))
            )

            Spacer(minLength: 48)
        }
    }
}

// MARK: - 内联技能卡片

private struct LiveSkillCardView: View {

    let card: SkillCardData

    private var accentColor: Color {
        let lc = card.category.lowercased()
        if lc.contains("social") || lc.contains("沟通") { return Color(hex: "#4A9EFF") }
        if lc.contains("language") || lc.contains("语言") { return Color(hex: "#34C759") }
        if lc.contains("emotion") || lc.contains("情绪") { return Color(hex: "#BF5AF2") }
        if lc.contains("negotiat") || lc.contains("谈判") { return Color(hex: "#FF9500") }
        return Color(hex: "#00D4FF")
    }

    private var iconName: String {
        let lc = card.category.lowercased()
        if lc.contains("social") || lc.contains("沟通") { return "person.2.fill" }
        if lc.contains("language") || lc.contains("语言") { return "globe" }
        if lc.contains("emotion") || lc.contains("情绪") { return "heart.fill" }
        if lc.contains("negotiat") || lc.contains("谈判") { return "arrow.left.arrow.right" }
        return "lightbulb.fill"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧彩色竖条
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)

            HStack(alignment: .top, spacing: 10) {
                // 图标
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: iconName)
                        .font(.system(size: 14))
                        .foregroundColor(accentColor)
                }
                .padding(.top, 1)

                // 文字内容
                VStack(alignment: .leading, spacing: 3) {
                    Text("Skill: \(card.skillName)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    if !card.advice.isEmpty {
                        Text("Advice: \(card.advice)")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.72))
                    }
                    if !card.reminder.isEmpty {
                        Text("Reminder: \(card.reminder)")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.72))
                    }
                }

                Spacer()
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
        }
        .background(Color(white: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
