//
//  EmojiTypePickerSheet.swift
//  WorkSurvivalGuide
//
//  Emoji 风格选择弹窗 — 3 种类型上下排列，每种显示 5 个情绪预览图
//

import SwiftUI

// MARK: - Model

private struct EmojiTypeOption: Identifiable {
    let id: String          // "self" | "dog" | "cat"
    let label: String
    let icon: String        // SF Symbol
    let emoji: String
}

private let emojiTypeOptions: [EmojiTypeOption] = [
    .init(id: "self",  label: "Self Portrait", icon: "person.crop.circle",    emoji: "🪞"),
    .init(id: "dog",   label: "Dog",           icon: "dog.fill",              emoji: "🐶"),
    .init(id: "cat",   label: "Cat",           icon: "cat.fill",              emoji: "🐱"),
]

private let emotionSlots: [String] = ["very_happy", "happy", "neutral", "slightly_sad", "sad"]

// MARK: - Sheet

struct EmojiTypePickerSheet: View {
    @Binding var selectedEmojiType: String
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingTypeId: String? = nil
    // Self 类型的预签名 URL 字典 slot → URL
    @State private var selfAvatarUrls: [String: String?] = [:]
    @State private var loadingUrls = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(emojiTypeOptions) { option in
                        EmojiTypeCard(
                            option: option,
                            isSelected: selectedEmojiType == option.id,
                            isConfirming: confirmingTypeId == option.id,
                            selfAvatarUrls: selfAvatarUrls
                        ) {
                            guard confirmingTypeId == nil else { return }
                            selectedEmojiType = option.id
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                confirmingTypeId = option.id
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                dismiss()
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(AppColors.cardBackground)
            .navigationTitle("Emoji Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(AppColors.headerText)
                }
            }
            .task {
                await loadSelfAvatarUrls()
            }
        }
    }

    private func loadSelfAvatarUrls() async {
        guard !loadingUrls else { return }
        loadingUrls = true
        do {
            let urls = try await NetworkManager.shared.fetchEmotionAvatarUrls()
            await MainActor.run { selfAvatarUrls = urls }
        } catch {
            // 静默失败：降级显示占位渐变色
        }
        loadingUrls = false
    }
}

// MARK: - EmojiTypeCard

private struct EmojiTypeCard: View {
    let option: EmojiTypeOption
    let isSelected: Bool
    let isConfirming: Bool
    let selfAvatarUrls: [String: String?]
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── 标题行 ──
            HStack(spacing: 8) {
                Image(systemName: option.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? .blue : AppColors.headerText.opacity(0.7))
                Text(option.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.primaryText)
                Text(option.emoji)
                    .font(.system(size: 15))
                Spacer()
                if isConfirming {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.blue)
                        .transition(.scale.combined(with: .opacity))
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.blue)
                }
            }

            // ── 5 个情绪预览圆图 ──
            HStack(spacing: 8) {
                ForEach(emotionSlots, id: \.self) { slot in
                    EmotionSlotPreview(
                        slot: slot,
                        emojiType: option.id,
                        selfUrl: selfAvatarUrls[slot] ?? nil
                    )
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isConfirming || isSelected ? Color.blue.opacity(0.7) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .scaleEffect(isConfirming ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isConfirming)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - EmotionSlotPreview

private let slotLabels: [String: String] = [
    "very_happy":   "Excited",
    "happy":        "Happy",
    "neutral":      "Calm",
    "slightly_sad": "Slight",
    "sad":          "Sad",
]

private let slotColors: [String: Color] = [
    "very_happy":   Color(red: 1.0, green: 0.85, blue: 0.2),
    "happy":        Color(red: 0.5, green: 0.85, blue: 0.5),
    "neutral":      Color(red: 0.6, green: 0.75, blue: 0.95),
    "slightly_sad": Color(red: 0.85, green: 0.65, blue: 0.95),
    "sad":          Color(red: 0.7, green: 0.75, blue: 0.85),
]

private struct EmotionSlotPreview: View {
    let slot: String
    let emojiType: String
    let selfUrl: String?

    @State private var loadedImage: UIImage?

    private var remoteURL: URL? {
        switch emojiType {
        case "self":
            guard let urlStr = selfUrl else { return nil }
            return URL(string: urlStr)
        default:
            let base = NetworkManager.shared.getBaseURL()
            let apiBase = base.hasSuffix("/api/v1") ? String(base.dropLast(7)) : base
            return URL(string: "\(apiBase)/api/v1/emoji-presets/\(emojiType)/\(slot)")
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(slotColors[slot] ?? Color.gray.opacity(0.4))
                    .frame(width: 48, height: 48)
                if let img = loadedImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                }
            }
            Text(slotLabels[slot] ?? slot)
                .font(.system(size: 9))
                .foregroundColor(AppColors.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .onAppear { loadImage(force: false) }
        .onChange(of: selfUrl) { _ in loadImage(force: true) }
    }

    private func loadImage(force: Bool = false) {
        guard let url = remoteURL else { return }
        // force=true 时允许覆盖（self 类型 URL 延迟到达）
        if !force && loadedImage != nil { return }
        let urlStr = url.absoluteString
        if let cached = ImageCacheManager.shared.image(for: urlStr) {
            loadedImage = cached
            return
        }
        URLSession.shared.dataTask(with: url) { data, response, _ in
            // 非 200 时不缓存（避免缓存 404 响应）
            guard let data = data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: data) else { return }
            ImageCacheManager.shared.cache(img, for: urlStr)
            DispatchQueue.main.async { loadedImage = img }
        }.resume()
    }
}
