//
//  SharePickerSheet.swift
//  WorkSurvivalGuide
//
//  多图分享面板：选择漫画 → Instagram Stories 或系统分享
//

import SwiftUI
import Photos
import TikTokBusinessSDK

// MARK: - Share Picker Sheet

struct SharePickerSheet: View {
    let imageURLs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>

    init(imageURLs: [String]) {
        self.imageURLs = imageURLs
        _selected = State(initialValue: Set(imageURLs))
    }

    private var isInstagramAvailable: Bool {
        guard let url = URL(string: "instagram://camera") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.08, blue: 0.12)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)

                Text("Select comics to share")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.top, 16)
                    .padding(.bottom, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(imageURLs, id: \.self) { url in
                            ComicThumbnailCell(url: url, isSelected: selected.contains(url)) {
                                if selected.contains(url) { selected.remove(url) }
                                else { selected.insert(url) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                Spacer().frame(height: 24)

                VStack(spacing: 12) {
                    if isInstagramAvailable {
                        Button(action: instagramTap) {
                            Label(
                                selected.isEmpty ? "Instagram Stories" : "Instagram Stories (\(selected.count))",
                                systemImage: "camera.fill"
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(selected.isEmpty ? Color.white.opacity(0.1) : Color(hex: "#405DE6"))
                            .foregroundColor(selected.isEmpty ? .white.opacity(0.4) : .white)
                            .cornerRadius(12)
                            .font(.system(size: 15, weight: .semibold))
                        }
                        .disabled(selected.isEmpty)
                    }

                    Button("Cancel") { dismiss() }
                        .foregroundColor(.white.opacity(0.5))
                        .font(.system(size: 15))
                        .padding(.vertical, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    private func instagramTap() {
        TikTokBusiness.trackEvent("ClickButton", withProperties: [
            "content_id": "share_instagram",
            "content_type": "comic",
            "quantity": selected.count
        ])
        let urls = imageURLs.filter { selected.contains($0) }
        let images = urls.compactMap { ImageCacheManager.shared.image(for: $0) }
        dismiss()
        guard !images.isEmpty, let igURL = URL(string: "instagram://camera") else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                for img in images { PHAssetChangeRequest.creationRequestForAsset(from: img) }
            } completionHandler: { _, _ in
                DispatchQueue.main.async { UIApplication.shared.open(igURL) }
            }
        }
    }

}

// MARK: - Comic Thumbnail Cell

struct ComicThumbnailCell: View {
    let url: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .aspectRatio(4/5, contentMode: .fit)
                .frame(width: 90)
                .overlay(ImageLoaderView(imageUrl: url, imageBase64: nil, contentMode: .fill))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color(hex: "#405DE6") : Color.clear, lineWidth: 3)
                )
                .opacity(isSelected ? 1.0 : 0.4)

            Circle()
                .fill(isSelected ? Color(hex: "#405DE6") : Color.white.opacity(0.25))
                .frame(width: 22, height: 22)
                .overlay(
                    Group {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                )
                .padding(6)
        }
        .onTapGesture(perform: onTap)
    }
}
