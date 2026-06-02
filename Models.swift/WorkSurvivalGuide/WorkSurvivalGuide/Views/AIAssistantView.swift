//
//  AIAssistantView.swift
//  WorkSurvivalGuide
//
//  AI Assistant 全屏对话页
//

import SwiftUI
import AVFoundation
import Speech
import ImageIO
import UIKit
import PhotosUI

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
    @State private var isVoiceMode = false
    @StateObject private var voiceService = VoiceInputService()

    // Photo attachment (max 3)
    @State private var attachedImages: [UIImage] = []
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

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
                        Text("Previous conversation restored")
                            .font(.system(size: 12, design: .rounded))
                        Spacer()
                        Button {
                            vm.clearHistory()
                        } label: {
                            Text("Start over")
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
                        .padding(.top, 8)
                        .padding(.bottom, 2)
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
        .sheet(isPresented: $vm.showPaywall) {
            SubscriptionView()
        }
        .alert("You've reached the chat limit", isPresented: $vm.showProLimitToast) {
            Button("OK", role: .cancel) { vm.showProLimitToast = false }
        } message: {
            Text("Pro members can have up to 50 conversation turns per recording. Start a new recording to continue chatting.")
        }
        .onChange(of: selectedPhotoItems) { newItems in
            Task {
                var loaded: [UIImage] = []
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        loaded.append(uiImage)
                    }
                }
                attachedImages = loaded
            }
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
                .frame(width: 94, height: 74)
                .rotationEffect(.degrees(rotation))
                .offset(x: offsetX, y: offsetY)
            }
        }
        .frame(height: 88)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    // MARK: - Data Source Tags

    private var dataSourceTags: some View {
        HStack(spacing: 8) {
            TagChip(icon: "✨", text: vm.skillName, color: Color(hex: "#7C5CBF"))
            if vm.memoryUsed {
                TagChip(icon: "🌐", text: "Memory Sync", color: Color(hex: "#2D7DD2"))
            }
            Spacer()
        }
    }

    // MARK: - Suggestions Grid

    private var suggestionsGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You might want to ask")
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
        VStack(spacing: 0) {
            // ── 图片缩略图（有附件时显示，最多3张）─────────────────────────────
            if !attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(attachedImages.enumerated()), id: \.offset) { index, image in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Button(action: {
                                    attachedImages.remove(at: index)
                                    if index < selectedPhotoItems.count {
                                        selectedPhotoItems.remove(at: index)
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white)
                                        .shadow(color: .black.opacity(0.4), radius: 2)
                                }
                                .buttonStyle(.plain)
                                .offset(x: 8, y: -8)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 80)
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // ── 输入行 ────────────────────────────────────────────────────────
            HStack(spacing: 10) {
                if isVoiceMode {
                    // ── 语音录制模式 ─────────────────────────────────────────────
                    // 声波字段（占满宽度）
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                        VoiceWaveformView()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.80))
                            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                    )

                    // 取消按钮（■）
                    Button(action: cancelVoiceMode) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color(hex: "#6B7280")))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))

                    // 发送按钮（样式与文字模式发送按钮一致）
                    Button(action: sendVoiceMessage) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(hex: "#5E7C8B"))
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color(hex: "#5E7C8B").opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))

                } else {
                    // ── 文字输入模式 ─────────────────────────────────────────────
                    // 图片选择按钮（➕，最多3张）
                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: 3,
                        matching: .images
                    ) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 30))
                                .foregroundColor(AppColors.headerText.opacity(attachedImages.isEmpty ? 0.6 : 0.9))
                            if !attachedImages.isEmpty {
                                Text("\(attachedImages.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 14, height: 14)
                                    .background(Circle().fill(Color(hex: "#5E7C8B")))
                                    .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    // 语音输入按钮（单击切换）
                    Button(action: startVoiceMode) {
                        Image(systemName: "mic.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(AppColors.headerText.opacity(0.6))
                    }
                    .buttonStyle(.plain)

                    // 文字输入框
                    ZStack(alignment: .leading) {
                        if inputText.isEmpty {
                            Text("Type a message...")
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

                    // 发送 / 停止生成 按钮
                    let canSend = !inputText.isEmpty || !attachedImages.isEmpty
                    if vm.isStreaming {
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
                        Button(action: sendMessage) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(canSend
                                                 ? Color(hex: "#5E7C8B")
                                                 : AppColors.headerText.opacity(0.3))
                                .frame(width: 38, height: 38)
                                .background(
                                    Circle()
                                        .fill(canSend
                                              ? Color(hex: "#5E7C8B").opacity(0.15)
                                              : Color.black.opacity(0.05))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isVoiceMode)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: vm.isStreaming)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: attachedImages.isEmpty)
        .background(
            Rectangle()
                .fill(AppColors.cardBackground)
                .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText
        let images = attachedImages
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        inputText = ""
        attachedImages = []
        selectedPhotoItems = []
        inputFocused = false
        vm.send(text: text, images: images)
    }

    private func startVoiceMode() {
        inputFocused = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            isVoiceMode = true
        }
        voiceService.startRecording()
    }

    private func cancelVoiceMode() {
        voiceService.stopRecording { _ in }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            isVoiceMode = false
        }
        // 不唤起键盘
    }

    private func sendVoiceMessage() {
        let images = attachedImages
        voiceService.stopRecording { transcribed in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                isVoiceMode = false
            }
            let hasText = transcribed != nil && !transcribed!.isEmpty
            if hasText || !images.isEmpty {
                attachedImages = []
                selectedPhotoItems = []
                vm.send(text: transcribed ?? "", images: images)
            }
        }
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
        // 梗图消息：独立消息行，左对齐
        if message.isMeme, let url = message.memeURL {
            HStack(alignment: .bottom, spacing: 0) {
                MemeGifBubble(gifURL: url)
                Spacer(minLength: 60)
            }
        } else {
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
}

// MARK: - Meme GIF Bubble

private struct MemeGifBubble: View {
    let gifURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            AnimatedGIFView(url: gifURL)
                .frame(width: 210, height: 168)   // 5:4 比例，与标准梗图接近
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.14), radius: 6, x: 0, y: 2)

            // KLIPY 归因标注
            HStack(spacing: 3) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 8))
                Text("Powered by KLIPY")
                    .font(.system(size: 9, design: .monospaced))
            }
            .foregroundColor(AppColors.headerText.opacity(0.28))
            .padding(.leading, 4)
        }
    }
}

// MARK: - Animated GIF View

struct AnimatedGIFView: UIViewRepresentable {
    let url: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        return iv
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        uiView.image = nil

        guard let gifURL = URL(string: url) else { return }
        Task.detached(priority: .userInitiated) {
            guard let (data, _) = try? await URLSession.shared.data(from: gifURL) else { return }
            let image = UIImage.animatedGIF(data: data)
            await MainActor.run { uiView.image = image }
        }
    }

    final class Coordinator: NSObject {
        var loadedURL: String?
    }
}

// MARK: - UIImage GIF Extension

extension UIImage {
    /// 从 GIF 数据创建动画 UIImage
    static func animatedGIF(data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }

        var frames: [UIImage] = []
        var totalDuration: Double = 0
        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            let delay = gifFrameDelay(source: source, index: i)
            totalDuration += delay
            frames.append(UIImage(cgImage: cgImage))
        }
        return UIImage.animatedImage(with: frames, duration: max(totalDuration, 0.5))
    }

    private static func gifFrameDelay(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] else {
            return 0.1
        }
        if let d = gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double, d > 0.01 { return d }
        if let d = gif[kCGImagePropertyGIFDelayTime as String] as? Double, d > 0.01 { return d }
        return 0.1
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

// MARK: - Voice Waveform View

/// 语音录制时的声波动效（TimelineView 驱动，正弦叠加产生自然波动）
private struct VoiceWaveformView: View {
    private let barCount = 22

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { i in
                    let h = barHeight(index: i, date: context.date)
                    Capsule()
                        .fill(Color.white.opacity(0.72))
                        .frame(width: 2.5, height: h)
                        .animation(.spring(response: 0.28, dampingFraction: 0.62), value: h)
                }
            }
            // 固定高度：柱子在内部动，不撑大父容器
            .frame(height: 28)
            .clipped()
            .frame(maxWidth: .infinity)
        }
    }

    /// 每根柱子的高度：两个不同频率正弦波叠加，产生类似真实音量的波动
    private func barHeight(index: Int, date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let f1 = 3.8 + Double(index) * 0.21
        let f2 = 7.3 + Double(index) * 0.16
        let v = (sin(t * f1) + sin(t * f2 + Double(index) * 0.9) * 0.55 + 1.55) / 3.1
        return max(3, CGFloat(v) * 26)
    }
}

// MARK: - Voice Input Service

@MainActor
final class VoiceInputService: NSObject, ObservableObject {
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
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
