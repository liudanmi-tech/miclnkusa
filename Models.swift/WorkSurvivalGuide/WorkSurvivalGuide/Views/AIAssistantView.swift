//
//  AIAssistantView.swift
//  WorkSurvivalGuide
//
//  AI Assistant 全屏对话页
//

import SwiftUI
import AVFoundation
import Speech

// MARK: - Main View

struct AIAssistantView: View {
    let sessionId: String
    let skillCard: SkillCard
    let sceneImages: [SceneImage]
    let baseURL: String
    var onDismiss: (() -> Void)? = nil

    @StateObject private var vm: AIAssistantViewModel
    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool

    // Voice input
    @State private var isRecording = false
    @StateObject private var voiceService = VoiceInputService()

    init(sessionId: String, skillCard: SkillCard, sceneImages: [SceneImage], baseURL: String, onDismiss: (() -> Void)? = nil) {
        self.sessionId = sessionId
        self.skillCard = skillCard
        self.sceneImages = sceneImages
        self.baseURL = baseURL
        self.onDismiss = onDismiss
        _vm = StateObject(wrappedValue: AIAssistantViewModel(sessionId: sessionId, skillCard: skillCard))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AppColors.cardBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Navigation Bar ──────────────────────────────────────────
                navBar

                // ── Restored banner ─────────────────────────────────────────
                if vm.isRestored {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12))
                        Text("已恢复上次对话")
                            .font(.system(size: 12, design: .rounded))
                        Spacer()
                        Button {
                            vm.clearHistory()
                        } label: {
                            Text("重新开始")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(Color(hex: "#5E7C8B"))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundColor(AppColors.headerText.opacity(0.5))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.04))
                }

                // ── Image Stack ─────────────────────────────────────────────
                if !sceneImages.isEmpty {
                    imageStack
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }

                Divider()
                    .background(Color(hex: "#E8DCC6").opacity(0.4))

                // ── Chat ScrollView ──────────────────────────────────────────
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // Data source tags
                            dataSourceTags
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                                .padding(.bottom, 8)

                            // Message history
                            ForEach(vm.messages) { msg in
                                MessageBubble(message: msg)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 10)
                                    .id(msg.id)
                            }

                            // Streaming text (current AI response)
                            if !vm.streamingText.isEmpty || vm.isStreaming {
                                StreamingBubble(
                                    text: vm.streamingText,
                                    isStreaming: vm.isStreaming
                                )
                                .padding(.horizontal, 16)
                                .padding(.bottom, 10)
                                .id("streaming")
                            }

                            // Error
                            if let err = vm.errorMessage {
                                Text(err)
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundColor(.red.opacity(0.8))
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 8)
                            }

                            // Suggestions
                            if !vm.suggestions.isEmpty && !vm.isStreaming {
                                suggestionsGrid
                                    .padding(.horizontal, 16)
                                    .padding(.top, 4)
                                    .padding(.bottom, 12)
                            }

                            // Bottom padding for input bar
                            Color.clear.frame(height: 80)
                                .id("bottom")
                        }
                    }
                    .onTapGesture { inputFocused = false }
                    .onChange(of: vm.streamingText) { _ in
                        withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                    }
                    .onChange(of: vm.messages.count) { _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: vm.suggestions) { _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }

            // ── Input Bar (floating above keyboard) ─────────────────────────
            inputBar
        }
        .onAppear {
            vm.initSession()
        }
    }

    // MARK: - Navigation Bar

    private var navBar: some View {
        HStack(spacing: 12) {
            Button {
                onDismiss?()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppColors.headerText)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.06))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Assistant")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(AppColors.headerText)
                Text(vm.skillCard.accordionTitle)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColors.headerText.opacity(0.5))
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppColors.cardBackground)
    }

    // MARK: - Image Stack

    private var imageStack: some View {
        let imgs = Array(sceneImages.prefix(3))
        return ZStack(alignment: .bottomLeading) {
            ForEach(Array(imgs.enumerated().reversed()), id: \.offset) { i, img in
                let rotation: Double = i == 0 ? 0 : i == 1 ? 3 : -5
                let offsetX: CGFloat = i == 0 ? 0 : i == 1 ? 6 : -8
                let offsetY: CGFloat = i == 0 ? 0 : CGFloat(i) * 4

                GeometryReader { geo in
                    ImageLoaderView(
                        imageUrl: img.getAccessibleImageURL(baseURL: baseURL),
                        imageBase64: img.imageBase64,
                        placeholder: "",
                        contentMode: .fill
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .cornerRadius(12)
                }
                .frame(width: 140, height: 110)
                .rotationEffect(.degrees(rotation))
                .offset(x: offsetX, y: offsetY)
            }
        }
        .frame(height: 130)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    // MARK: - Data Source Tags

    private var dataSourceTags: some View {
        HStack(spacing: 8) {
            TagChip(icon: "✨", text: vm.skillName, color: Color(hex: "#7C5CBF"))
            if vm.memoryUsed {
                TagChip(icon: "🌐", text: "记忆整合", color: Color(hex: "#2D7DD2"))
            }
            Spacer()
        }
    }

    // MARK: - Suggestions Grid

    private var suggestionsGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("猜你想问")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(AppColors.headerText.opacity(0.45))
                .padding(.bottom, 2)

            let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(vm.suggestions, id: \.self) { q in
                    Button {
                        inputFocused = false
                        vm.selectSuggestion(q)
                    } label: {
                        Text(q)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(AppColors.headerText)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.black.opacity(0.07))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            // Voice button (press and hold)
            MicButton(isRecording: $isRecording) {
                voiceService.startRecording()
            } onRelease: {
                voiceService.stopRecording { transcribed in
                    if let text = transcribed, !text.isEmpty {
                        inputText = text
                    }
                }
            }

            // Text field
            ZStack(alignment: .leading) {
                if inputText.isEmpty {
                    Text(isRecording ? "松开发送..." : "输入消息...")
                        .font(.system(size: 15, design: .rounded))
                        .foregroundColor(AppColors.headerText.opacity(0.35))
                        .padding(.leading, 14)
                }
                TextField("", text: $inputText)
                    .focused($inputFocused)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundColor(AppColors.headerText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .submitLabel(.send)
                    .onSubmit { sendMessage() }
            }
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.07))
                    .overlay(Capsule().stroke(Color(hex: "#E8DCC6").opacity(0.3), lineWidth: 1))
            )

            // 发送 / 停止 按钮
            if vm.isStreaming {
                // 生成中 → 点击停止
                Button(action: { vm.cancelStream() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color(hex: "#E57373")))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                // 空闲 → 发送
                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(inputText.isEmpty ? AppColors.headerText.opacity(0.3) : Color(hex: "#5E7C8B"))
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(inputText.isEmpty
                                      ? Color.black.opacity(0.05)
                                      : Color(hex: "#5E7C8B").opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: vm.isStreaming)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(AppColors.cardBackground)
                .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func sendMessage() {
        let text = inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inputText = ""
        inputFocused = false   // 收起键盘
        vm.send(text: text)
    }
}

// MARK: - Markdown Text View

/// 轻量级 Markdown 渲染：支持 #/##/### 标题、- 列表、**bold**、*italic*
struct MarkdownTextView: View {
    let text: String
    var baseFontSize: CGFloat = 15
    var textColor: Color = AppColors.headerText

    private enum Block {
        case h1(String), h2(String), h3(String)
        case bullet(String)
        case plain(String)
        case empty
    }

    private var blocks: [Block] {
        text.components(separatedBy: "\n").map { line in
            if line.hasPrefix("### ") { return .h3(String(line.dropFirst(4))) }
            if line.hasPrefix("## ")  { return .h2(String(line.dropFirst(3))) }
            if line.hasPrefix("# ")   { return .h1(String(line.dropFirst(2))) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return .bullet(String(line.dropFirst(2))) }
            if line.hasPrefix("• ")   { return .bullet(String(line.dropFirst(2))) }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
            return .plain(line)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .h1(let t):
            inlineText(t)
                .font(.system(size: baseFontSize + 5, weight: .bold, design: .rounded))
                .foregroundColor(textColor)
                .padding(.top, 6)
        case .h2(let t):
            inlineText(t)
                .font(.system(size: baseFontSize + 3, weight: .bold, design: .rounded))
                .foregroundColor(textColor)
                .padding(.top, 4)
        case .h3(let t):
            inlineText(t)
                .font(.system(size: baseFontSize + 1, weight: .semibold, design: .rounded))
                .foregroundColor(textColor)
                .padding(.top, 2)
        case .bullet(let t):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: baseFontSize, design: .rounded))
                    .foregroundColor(textColor.opacity(0.6))
                inlineText(t)
                    .font(.system(size: baseFontSize, design: .rounded))
                    .foregroundColor(textColor)
            }
        case .plain(let t):
            inlineText(t)
                .font(.system(size: baseFontSize, design: .rounded))
                .foregroundColor(textColor)
        case .empty:
            Color.clear.frame(height: 4)
        }
    }

    private func inlineText(_ raw: String) -> Text {
        if let attr = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(raw)
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: AssistantMessage

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if isUser {
                    Text(message.content)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(hex: "#5E7C8B"))
                        )
                } else {
                    MarkdownTextView(text: message.content, baseFontSize: 15, textColor: AppColors.headerText)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.black.opacity(0.07))
                        )
                }

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(AppColors.headerText.opacity(0.3))
                    .padding(.horizontal, 4)
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Streaming Bubble

private struct StreamingBubble: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                if text.isEmpty && isStreaming {
                    // 加载动画
                    HStack(spacing: 5) {
                        ForEach(0..<3) { i in
                            Circle()
                                .fill(AppColors.headerText.opacity(0.4))
                                .frame(width: 6, height: 6)
                                .animation(
                                    .easeInOut(duration: 0.5)
                                    .repeatForever()
                                    .delay(Double(i) * 0.15),
                                    value: isStreaming
                                )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.07)))
                } else {
                    // 流式渲染：富文本 + 光标
                    MarkdownTextView(
                        text: text + (isStreaming ? " ▌" : ""),
                        baseFontSize: 15,
                        textColor: AppColors.headerText
                    )
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.07)))
                }
            }
            Spacer(minLength: 60)
        }
    }
}

// MARK: - Tag Chip

private struct TagChip: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(icon).font(.system(size: 11))
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Mic Button

private struct MicButton: View {
    @Binding var isRecording: Bool
    var onPress: () -> Void
    var onRelease: () -> Void

    var body: some View {
        Image(systemName: isRecording ? "waveform.circle.fill" : "mic.circle.fill")
            .font(.system(size: 30))
            .foregroundColor(isRecording ? Color(hex: "#F87171") : AppColors.headerText.opacity(0.6))
            .scaleEffect(isRecording ? 1.15 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isRecording)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isRecording {
                            isRecording = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        isRecording = false
                        onRelease()
                    }
            )
    }
}

// MARK: - Voice Input Service

@MainActor
final class VoiceInputService: NSObject, ObservableObject {
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        ?? SFSpeechRecognizer(locale: Locale.current)

    private var onResultCallback: ((String?) -> Void)?
    private var lastTranscription: String = ""

    func startRecording() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else { return }
            DispatchQueue.main.async { self?._startEngine() }
        }
    }

    private func _startEngine() {
        recognitionTask?.cancel()
        recognitionTask = nil

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let req = recognitionRequest else { return }
        req.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        recognitionTask = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            if let r = result {
                self?.lastTranscription = r.bestTranscription.formattedString
            }
        }

        let fmt = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.recognitionRequest?.append(buf)
        }

        audioEngine.prepare()
        try? audioEngine.start()
        lastTranscription = ""
    }

    func stopRecording(completion: @escaping (String?) -> Void) {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let result = lastTranscription.isEmpty ? nil : lastTranscription
        lastTranscription = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            completion(result)
        }
    }
}
