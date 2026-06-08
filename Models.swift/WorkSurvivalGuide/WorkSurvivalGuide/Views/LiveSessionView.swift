//
//  LiveSessionView.swift
//  WorkSurvivalGuide
//
//  Live Mode 实时录制界面
//
//  架构说明：
//    - turn 展示直接读 liveManager.transcript（@ObservedObject→@Published 链，100% 响应）
//    - SSE 事件（建议/技能卡/摘要）用独立 @State 数组存储
//    - displayItems: 计算属性按 turnIndex 边界将 SSE 事件插入 turn 流
//    - 不再有 chatItems 中间层，消除同步失效问题
//
//  UI 结构：
//    Header → Summary（有内容才显示）→ Chat 流 → Stop bar
//

import SwiftUI

// MARK: - Chat Item Models

private enum ChatItem: Identifiable {
    case turn(LiveTurnItem)
    case suggestion(SuggestionData)
    case skillCards(SkillBatchData)

    var id: String {
        switch self {
        case .turn(let t):        return "t-\(t.id)"
        case .suggestion(let d):  return "s-\(d.id)"
        case .skillCards(let d):  return "k-\(d.id)"
        }
    }
}

private struct SuggestionData: Identifiable {
    let id        = UUID()
    let text:       String
    let emotion:    String
    let afterTurn:  Int     // 在第几条 turn 之后插入（turn_index）
}

private struct SkillCardData: Identifiable {
    let id         = UUID()
    let skillId:    String
    let skillName:  String
    let category:   String
    let confidence: Double
    let advice:     String
    let reminder:   String
}

private struct SkillBatchData: Identifiable {
    let id         = UUID()
    let cards:      [SkillCardData]
    let afterTurn:  Int     // 在第几条 turn 之后插入（batch_end turn_index）
}

// MARK: - Main View

struct LiveSessionView: View {

    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    // liveManager.transcript 是 @Published，@ObservedObject 保证变更触发重渲
    @ObservedObject private var liveManager = LiveSessionManager.shared
    @ObservedObject private var sseClient   = LiveSSEClient.shared

    // ── Session 生命周期 ────────────────────────────────────────────────────
    @State private var sessionId:  String?
    @State private var isStarting: Bool    = true
    @State private var startError: String?

    // ── 停止录音流程 ────────────────────────────────────────────────────────
    @State private var showStopAlert:      Bool = false
    @State private var isStopping:         Bool = false
    @State private var endResponse:        LiveSessionEndResponse?
    @State private var showSpeakerConfirm: Bool = false
    @State private var showProcessingDone: Bool = false

    // ── SSE 事件存储（不含 turn，turn 来自 liveManager.transcript）───────────
    @State private var suggestionItems:  [SuggestionData]  = []
    @State private var skillBatchItems:  [SkillBatchData]  = []
    @State private var segmentContext:   String            = ""

    // ── 合并展示列表（computed，每次 body 渲染自动更新）─────────────────────
    private var displayItems: [ChatItem] {
        var result: [ChatItem] = []
        var suggIdx  = 0
        var skillIdx = 0

        for turn in liveManager.transcript {
            result.append(.turn(turn))
            // 插入在该 turn 之后的建议
            while suggIdx < suggestionItems.count
                    && suggestionItems[suggIdx].afterTurn <= turn.turnIndex {
                result.append(.suggestion(suggestionItems[suggIdx]))
                suggIdx += 1
            }
            // 插入在该 turn 之后的技能批次
            while skillIdx < skillBatchItems.count
                    && skillBatchItems[skillIdx].afterTurn <= turn.turnIndex {
                result.append(.skillCards(skillBatchItems[skillIdx]))
                skillIdx += 1
            }
        }

        // 把还没插入的 SSE 尾部事件追加到末尾
        while suggIdx  < suggestionItems.count  { result.append(.suggestion(suggestionItems[suggIdx]));  suggIdx  += 1 }
        while skillIdx < skillBatchItems.count  { result.append(.skillCards(skillBatchItems[skillIdx])); skillIdx += 1 }

        return result
    }

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
        .onAppear  { startLiveSession() }
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

    // MARK: - Summary 区域（有 segment_context 才显示）

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
                    if liveManager.transcript.isEmpty && suggestionItems.isEmpty && skillBatchItems.isEmpty {
                        emptyState
                    } else {
                        ForEach(displayItems) { item in
                            chatItemView(item)
                                .id(item.id)
                        }
                    }
                    // 滚动锚点
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            // transcript 新增 turn 时自动滚到底
            .onChange(of: liveManager.transcript.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            // SSE 事件新增时也滚到底
            .onChange(of: suggestionItems.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onChange(of: skillBatchItems.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
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
            ProgressView().scaleEffect(1.4).tint(Color(hex: "#00D4FF"))
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

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().scaleEffect(1.5).tint(Color(hex: "#00D4FF"))
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

    /// 只设置 SSE 事件回调。Turn 展示直接读 liveManager.transcript，无需回调。
    private func setupSSECallbacks() {
        // 快速建议（每 3 turn）→ 插入对话流
        LiveSSEClient.shared.onSuggestion = { [self] payload in
            let text      = payload["text"]        as? String ?? ""
            let emotion   = payload["emotion_tag"] as? String ?? ""
            let turnIndex = payload["turn_index"]  as? Int    ?? max(0, liveManager.transcript.count - 1)
            guard !text.isEmpty else { return }
            suggestionItems.append(SuggestionData(text: text, emotion: emotion, afterTurn: turnIndex))
        }

        // 技能匹配结果（每 10 turn）→ 插入对话流
        LiveSSEClient.shared.onAnalysisReady = { [self] payload in
            guard let rawCards = payload["skill_cards"] as? [[String: Any]],
                  !rawCards.isEmpty else { return }
            let range     = payload["turn_range"] as? [Int] ?? []
            let afterTurn = range.last ?? max(0, liveManager.transcript.count - 1)
            let cards = rawCards.compactMap { d -> SkillCardData? in
                guard let sid  = d["skill_id"]  as? String,
                      let name = d["skill_name"] as? String else { return nil }
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
            skillBatchItems.append(SkillBatchData(cards: cards, afterTurn: afterTurn))
        }

        // Segment 摘要（每 10 turn 改写）→ 更新顶部 Summary
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
            if isMe { Spacer(minLength: 60) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
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
                            .fill(isMe ? Color(white: 0.20) : Color(white: 0.16))
                    )
                    .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
            }

            if !isMe { Spacer(minLength: 60) }
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
            ZStack {
                Circle().fill(Color(white: 0.22)).frame(width: 28, height: 28)
                Text("AI")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
            }

            HStack(alignment: .top, spacing: 5) {
                if !data.emotion.isEmpty {
                    Text(data.emotion).font(.system(size: 13))
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

            Spacer(minLength: 60)
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
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)

            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: iconName)
                        .font(.system(size: 14))
                        .foregroundColor(accentColor)
                }
                .padding(.top, 1)

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
