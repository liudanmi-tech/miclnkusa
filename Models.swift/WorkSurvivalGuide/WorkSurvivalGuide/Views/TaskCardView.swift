//
//  TaskCardView.swift
//  WorkSurvivalGuide
//
//  任务卡片组件 - 1:1 图片卡片，策略首图填充，底部半透明蒙层展示标题与时间
//  loading 阶段：居中播放阶段 GIF（卡片宽/高的 1/2）+ 状态文字；有封面后替换为封面图
//

import SwiftUI
import UIKit

struct TaskCardView: View {
    let task: TaskItem
    /// 封面图 404 时置为 true，切换为占位内容
    @State private var coverLoadFailed = false
    /// loading 倒计时已过秒数
    @State private var loadingElapsed: Int = 0
    @State private var loadTimer: Timer?
    @ObservedObject private var profileVM = ProfileViewModel.shared
    @ObservedObject private var selfCache = SelfEmojiURLCache.shared

    private var baseURL: String {
        NetworkManager.shared.getBaseURL()
    }

    private var hasCoverImage: Bool {
        guard let url = task.coverImageUrl, !url.isEmpty else { return false }
        return true
    }

    /// archived 但封面图还没来：图片正在后台生成中
    private var isGeneratingImages: Bool {
        if task.sessionType == "chat" {
            return task.coverType == "generated" && task.coverImageUrl == nil
        }
        return task.status == .archived && task.coverImageUrl == nil
    }

    /// Returns local GIF resource name for current loading stage, nil if no GIF should show
    private var cardGIFName: String? {
        if task.status == .recording { return nil }
        if isGeneratingImages { return "04" }
        guard task.status == .analyzing, let desc = task.progressDescription else { return nil }
        // Group 1: saving_audio, transcribing
        if desc == "Upload complete" || desc.hasPrefix("Saving audio") || desc.hasPrefix("Transcribing") {
            return "01"
        }
        // Group 2: matching_profiles → strategy_matched_n
        if desc.hasPrefix("Matching profiles") || desc.hasPrefix("Identifying scene")
            || desc.hasPrefix("Matching skills") || desc.hasPrefix("Matched") || desc == "Skills matched" {
            return "02"
        }
        // Group 3: strategy_executing, strategy_done（不含 Generating images）
        if desc.hasPrefix("Processing skills") || desc == "Strategy ready" {
            return "03"
        }
        // Group 4: strategy_images → oss_upload → gemini_analysis → voiceprint（Gemini 生成封面全程）
        if desc.hasPrefix("Generating images") || desc.hasPrefix("Uploading to cloud")
            || desc.hasPrefix("Analyzing conversation") || desc.hasPrefix("Matching speakers") {
            return "04"
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 主内容区：封面图 或 占位（GIF + 文字）
            if hasCoverImage, let url = task.coverImageUrl, !coverLoadFailed {
                ImageLoaderView(
                    imageUrl: accessibleImageURL(url),
                    imageBase64: nil,
                    placeholder: "Loading",
                    contentMode: .fill,
                    onLoadFailed: { coverLoadFailed = true }
                )
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .onChange(of: task.id) { _ in coverLoadFailed = false }
            } else {
                placeholderContent
            }

            // 底部渐变蒙层
            overlayGradient

            // 底部信息栏：毛玻璃 + 标题/时间/时长
            VStack {
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    if task.status == .archived || task.status == .completed {
                        Text(task.cardTitle ?? task.refinedTitle)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.95))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Text(formattedTime)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                        Spacer()
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.25))
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// loading 占位：顶部状态文字 + 倒计时，居中 GIF（卡片 1/3）
    private var placeholderContent: some View {
        GeometryReader { geo in
            ZStack {
                placeholderBackground
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 顶部信息：阶段文字 + 倒计时（两行，相互独立）
                VStack(spacing: 3) {
                    if !placeholderText.isEmpty {
                        Text(placeholderText)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(placeholderTextColor)
                            .multilineTextAlignment(.center)
                    }
                    if let cd = countdownText {
                        Text(cd)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundColor(placeholderTextColor.opacity(0.75))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // GIF 或图标：卡片正中，1/3 大小
                if let gifName = cardGIFName {
                    LocalGIFView(name: gifName)
                        .frame(width: geo.size.width / 3, height: geo.size.width / 3)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    placeholderIcon
                }
            }
            .onAppear {
                guard task.status == .analyzing || isGeneratingImages else { return }
                loadingElapsed = 0
                loadTimer?.invalidate()
                loadTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    loadingElapsed += 1
                }
            }
            .onDisappear {
                loadTimer?.invalidate()
                loadTimer = nil
            }
        }
    }

    /// 倒计时显示文字（仅 analyzing / isGeneratingImages 状态）
    private var countdownText: String? {
        guard task.status == .analyzing || isGeneratingImages else { return nil }
        switch loadingElapsed {
        case 0..<60:    return "Est. ~3 min"
        case 60..<120:  return "Est. ~2 min"
        case 120..<150: return "Est. ~1 min"
        case 150..<180: return "Est. 30s"
        default:        return "Please be patient..."
        }
    }

    private var placeholderBackground: Color {
        switch task.status {
        case .recording:
            return Color(hex: "#1E3A5F").opacity(0.9)
        case .analyzing:
            return Color(hex: "#4A3F00").opacity(0.9)
        case .archived, .completed:
            return isGeneratingImages ? Color(hex: "#4A3F00").opacity(0.9) : Color(white: 0.15)
        case .burned, .failed:
            return Color(hex: "#4A1C1C").opacity(0.9)
        case .chatActive:
            return Color(hex: "#1A2B3C").opacity(0.9)
        }
    }

    private var placeholderIcon: some View {
        Group {
            switch task.status {
            case .recording:
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 36))
                    .foregroundColor(Color(hex: "#60A5FA"))
            case .analyzing:
                Image(systemName: "waveform")
                    .font(.system(size: 36))
                    .foregroundColor(Color(hex: "#FBBF24"))
            case .archived, .completed:
                if isGeneratingImages {
                    ProgressView()
                        .tint(Color(hex: "#FBBF24"))
                        .scaleEffect(1.5)
                } else if task.sessionType == "chat", let mood = task.emotionMood {
                    let slot = moodSlot(for: mood)
                    if let url = chatMoodImageURL(slot: slot) {
                        ImageLoaderView(imageUrl: url, imageBase64: nil, contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(Circle())
                    } else {
                        Text(moodEmoji(for: mood))
                            .font(.system(size: 48))
                    }
                } else {
                    QuotationMarkView(size: 32, color: Color.white.opacity(0.6), opacity: 0.7, isGrayStyle: true)
                }
            case .burned, .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(Color(hex: "#F87171"))
            case .chatActive:
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 32))
                    .foregroundColor(Color.white.opacity(0.6))
            }
        }
    }

    private func moodEmoji(for mood: String) -> String {
        switch mood {
        case "Happy", "Excited":   return "😊"
        case "Content":            return "🙂"
        case "Anxious":            return "😰"
        case "Frustrated":         return "😤"
        case "Sad":                return "😢"
        case "Angry":              return "😠"
        case "Overwhelmed":        return "😵"
        default:                   return "😐"
        }
    }

    private func moodSlot(for mood: String) -> String {
        // 对齐 sessions.mood_state 9 个枚举 → 5 个情绪槽（单一权威映射）
        switch mood {
        case "Excited":                         return "very_happy"
        case "Happy", "Content":               return "happy"
        case "Neutral":                         return "neutral"
        case "Anxious", "Frustrated", "Angry": return "slightly_sad"
        case "Sad", "Overwhelmed":             return "sad"
        default:                                return "neutral"
        }
    }

    private func chatMoodImageURL(slot: String) -> String? {
        let emojiType = profileVM.selfEmojiType
        switch emojiType {
        case "self":
            return selfCache.url(for: slot)
        case "dog", "cat":
            let base = NetworkManager.shared.getBaseURL()
            let apiBase = base.hasSuffix("/api/v1") ? String(base.dropLast(7)) : base
            return "\(apiBase)/api/v1/emoji-presets/\(emojiType)/\(slot)"
        default:
            return nil
        }
    }

    private var placeholderText: String {
        switch task.status {
        case .recording:
            return "Recording"
        case .analyzing:
            return task.progressDescription ?? "Analyzing"
        case .archived, .completed:
            return isGeneratingImages ? "Generating image" : ""
        case .burned:
            return "Burned"
        case .failed:
            return "Analysis Failed"
        case .chatActive:
            return "Chat in progress"
        }
    }

    private var placeholderTextColor: Color {
        switch task.status {
        case .recording:
            return Color(hex: "#60A5FA")
        case .analyzing:
            return Color(hex: "#FBBF24")
        case .archived, .completed:
            return isGeneratingImages ? Color(hex: "#FBBF24") : Color.white.opacity(0.6)
        case .burned, .failed:
            return Color(hex: "#F87171")
        case .chatActive:
            return Color.white.opacity(0.6)
        }
    }

    private var overlayGradient: some View {
        VStack {
            Spacer()
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(0.65)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 100)
        }
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: task.startTime)
    }

    private func accessibleImageURL(_ url: String) -> String {
        if url.contains("/api/v1/images/") || url.hasPrefix("http") {
            return url
        }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return "\(base)/images/\(task.id)/0"
    }
}

// MARK: - LocalGIFView

/// Loads and plays a GIF from the app bundle by resource name (without extension).
struct LocalGIFView: UIViewRepresentable {
    let name: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        // 让 UIImageView 服从 SwiftUI 的 frame，不用图片原始尺寸撑开布局
        iv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        iv.setContentHuggingPriority(.defaultLow, for: .vertical)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        load(into: iv, coordinator: context.coordinator)
        return iv
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        guard context.coordinator.loadedName != name else { return }
        load(into: uiView, coordinator: context.coordinator)
    }

    private func load(into iv: UIImageView, coordinator: Coordinator) {
        coordinator.loadedName = name
        guard let url = Bundle.main.url(forResource: name, withExtension: "gif"),
              let data = try? Data(contentsOf: url) else { return }
        iv.image = UIImage.animatedGIF(data: data)
    }

    final class Coordinator: NSObject {
        var loadedName: String?
    }
}
