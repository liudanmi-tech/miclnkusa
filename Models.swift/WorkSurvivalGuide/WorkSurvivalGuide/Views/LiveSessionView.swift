//
//  LiveSessionView.swift
//  WorkSurvivalGuide
//
//  Live Mode 实时录制界面（Step 10 C+D）
//
//  流程：
//    .onAppear → createLiveSession → startSession(WS) + connect(SSE)
//    实时展示：AI 建议气泡 + 转录气泡列表 + 计时器 + 眼镜状态
//    停止：Alert 确认 → stopSession + endLiveSession → SpeakerConfirmationSheet → 处理中遮罩 → onCompleted
//

import SwiftUI

// MARK: - Main View

struct LiveSessionView: View {

    /// 完成后回调（Speaker 确认完成后调用，调用方负责 dismiss）
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var liveManager = LiveSessionManager.shared
    @ObservedObject private var sseClient   = LiveSSEClient.shared

    // ── Session 生命周期 ────────────────────────────────────────────────────
    @State private var sessionId:   String?
    @State private var isStarting:  Bool   = true
    @State private var startError:  String?

    // ── 停止录音流程 ────────────────────────────────────────────────────────
    @State private var showStopAlert:      Bool = false
    @State private var isStopping:         Bool = false
    @State private var endResponse:        LiveSessionEndResponse?
    @State private var showSpeakerConfirm: Bool = false
    @State private var showProcessingDone: Bool = false

    // ── AI 建议（SSE suggestion 事件）──────────────────────────────────────
    @State private var suggestionText: String = ""
    @State private var emotionTag:     String = ""
    @State private var showSuggestion: Bool   = false

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

            if showSuggestion && !suggestionText.isEmpty {
                suggestionBubble
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.4), value: showSuggestion)
            }

            transcriptArea

            stopBar
        }
    }

    // MARK: - 顶部状态栏

    private var headerBar: some View {
        HStack(spacing: 16) {
            // 眼镜 / 麦克风状态
            HStack(spacing: 6) {
                Circle()
                    .fill(liveManager.isGlassesAvailable ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(liveManager.isGlassesAvailable ? "眼镜已连接" : "内置麦克风")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
            }

            Spacer()

            // 计时器
            Text(formatElapsed(liveManager.elapsedSeconds))
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)

            Spacer()

            // 录制状态指示
            HStack(spacing: 4) {
                if liveManager.sessionState == .active {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("REC")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.red)
                } else {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.white)
                }
            }
            .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(white: 0.07))
    }

    // MARK: - AI 建议气泡

    private var suggestionBubble: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(emotionTag.isEmpty ? "💡" : emotionTag)
                .font(.system(size: 22))

            VStack(alignment: .leading, spacing: 3) {
                Text("AI 建议")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "#00D4FF").opacity(0.85))
                Text(suggestionText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: "#001824"))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(hex: "#00D4FF").opacity(0.30), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - 转录气泡列表

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if liveManager.transcript.isEmpty {
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
                    } else {
                        ForEach(liveManager.transcript) { turn in
                            TurnBubble(turn: turn)
                                .id(turn.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onChange(of: liveManager.transcript.count) { _ in
                if let last = liveManager.transcript.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - 底部停止按钮栏

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
        LiveSSEClient.shared.onSuggestion = { [weak liveManager] payload in
            let text    = payload["text"]       as? String ?? ""
            let emotion = payload["emotion_tag"] as? String ?? ""
            guard !text.isEmpty else { return }
            withAnimation(.spring(response: 0.4)) {
                suggestionText = text
                emotionTag     = emotion
                showSuggestion = true
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
                // end 失败也允许用户离开
                await MainActor.run {
                    isStopping        = false
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
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
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
                                  ? Color(hex: "#0A3D6B")
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
