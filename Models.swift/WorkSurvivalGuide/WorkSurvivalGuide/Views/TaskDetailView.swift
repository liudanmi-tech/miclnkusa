//
//  TaskDetailView.swift
//  WorkSurvivalGuide
//
//  Moment 详情页 - 重新设计：图片轮播 + 信息卡 + 技能卡
//

import SwiftUI

struct TaskDetailView: View {
    let task: TaskItem
    @State private var detail: TaskDetailResponse?
    @State private var strategyAnalysis: StrategyAnalysisResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @StateObject private var audioPlayer = SessionAudioPlayerService()
    @State private var showReportMenu = false
    @State private var reportSubmitted = false
    @State private var showSummarySheet = false
    @State private var strategyIsLoading = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppColors.background.ignoresSafeArea()
                PaperGridBackground().ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // ── Header ──
                        DetailHeaderView(onReportTap: {
                            withAnimation(.easeInOut(duration: 0.25)) { showReportMenu = true }
                        })
                        .padding(.horizontal, 15.99)
                        .padding(.top, 10)
                        .padding(.bottom, 14)

                        // ── Scene image carousel（全宽，4:3 比例与服务端生成一致）──
                        let sceneImgs = strategyAnalysis?.sceneImages ?? []
                        let imgW = geometry.size.width
                        let imgH = imgW * 3.0 / 4.0   // 4:3 aspect ratio
                        SceneRestoreImageCarouselView(
                            sceneImages: sceneImgs,
                            baseURL: NetworkManager.shared.getBaseURL()
                        )
                        .frame(width: imgW, height: imgH)
                        .clipped()

                        // ── Info card ──
                        MomentInfoCard(
                            sceneDescription: currentSceneDescription,
                            onSummaryTap: { showSummarySheet = true },
                            audioPlayer: audioPlayer,
                            moodEmoji: moodEmoji,
                            moodState: moodState,
                            startTime: task.startTime,
                            strategyIsLoading: strategyIsLoading
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        // ── Skills card ──
                        if let skillCards = strategySkillCards, !skillCards.isEmpty {
                            MomentSkillsCard(
                                sceneCategoryName: primarySceneCategory,
                                skillCards: skillCards
                            )
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        } else if strategyIsLoading {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Analyzing skills…")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 20)
                        }

                        // Error state
                        if let errorMessage = errorMessage {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(.orange)
                                Text(errorMessage)
                                    .font(.system(size: 14, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                                Button(action: { loadAll() }) {
                                    Text("Retry")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 20).padding(.vertical, 10)
                                        .background(Color.blue).cornerRadius(8)
                                }
                            }
                            .padding(.top, 32)
                        }

                        Spacer(minLength: 40)
                    }
                    .frame(width: geometry.size.width)
                }

                // Full-screen loading overlay
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView().scaleEffect(1.5).tint(AppColors.headerText)
                            Text("Loading…")
                                .font(.system(size: 16, design: .rounded))
                                .foregroundColor(AppColors.headerText)
                        }
                        .padding(24)
                        .background(Color.white)
                        .cornerRadius(12)
                    }
                }

                // Report menu
                if showReportMenu {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) { showReportMenu = false }
                        }
                        .transition(.opacity)

                    ReportMenuPanel(
                        sessionId: task.id,
                        submitted: $reportSubmitted,
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.25)) { showReportMenu = false }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom))
                }
            }
            .navigationBarHidden(true)
            .onDisappear { audioPlayer.stop() }
            .onAppear { loadAll() }
            .sheet(isPresented: $showSummarySheet) {
                SummarySheet(
                    summary: detail?.summary ?? task.summary,
                    dialogues: detail?.dialogues ?? []
                )
            }
        }
    }

    // MARK: - Computed helpers

    private var currentSceneDescription: String? {
        let imgs = strategyAnalysis?.sceneImages?.filter {
            ($0.imageUrl != nil && !($0.imageUrl?.isEmpty ?? true))
            || ($0.imageBase64 != nil && !($0.imageBase64?.isEmpty ?? true))
        } ?? []
        // Show first valid scene description
        let desc = imgs.first?.sceneDescription ?? ""
        return desc.isEmpty ? nil : desc
    }

    private var moodEmoji: String? {
        strategyAnalysis?.skillCards?
            .first(where: { $0.contentType == "emotion" })?
            .content?.moodEmoji
    }

    private var moodState: String? {
        strategyAnalysis?.skillCards?
            .first(where: { $0.contentType == "emotion" })?
            .content?.moodState
    }

    /// Strategy + scene skill cards (exclude emotion/mental_health always-run cards)
    private var strategySkillCards: [SkillCard]? {
        guard let cards = strategyAnalysis?.skillCards else { return nil }
        let filtered = cards.filter { $0.contentType != "emotion" && $0.contentType != "mental_health" }
        return filtered.isEmpty ? nil : filtered
    }

    private var primarySceneCategory: String? {
        if let cat = strategyAnalysis?.sceneCategory, !cat.isEmpty { return cat }
        if let first = strategySkillCards?.first(where: { !$0.sceneCategory.isEmpty }) {
            return first.sceneCategory
        }
        return nil
    }

    // MARK: - Loading

    private func loadAll() {
        loadTaskDetail()
        if task.status == .archived {
            loadStrategyAnalysis()
        }
    }

    private func loadTaskDetail(silent: Bool = false) {
        let cacheManager = DetailCacheManager.shared
        if let cached = cacheManager.getCachedDetail(sessionId: task.id) {
            self.detail = cached
            self.audioPlayer.setAudioUrl(cached.audioUrl)
            return
        }
        if let existing = detail, !existing.dialogues.isEmpty { return }
        if cacheManager.isLoadingDetail(for: task.id) { return }

        if !silent { isLoading = true }
        errorMessage = nil
        cacheManager.setLoadingDetail(true, for: task.id)

        Task {
            defer { cacheManager.setLoadingDetail(false, for: task.id) }
            do {
                let taskDetail = try await NetworkManager.shared.getTaskDetail(sessionId: task.id)
                cacheManager.cacheDetail(taskDetail, for: task.id)
                await MainActor.run {
                    self.detail = taskDetail
                    self.audioPlayer.setAudioUrl(taskDetail.audioUrl)
                    self.isLoading = false
                    self.errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = friendlyError(error)
                }
            }
        }
    }

    private func loadStrategyAnalysis() {
        let cacheManager = DetailCacheManager.shared
        if let cached = cacheManager.getCachedStrategy(sessionId: task.id) {
            self.strategyAnalysis = cached
            return
        }
        if strategyIsLoading { return }
        strategyIsLoading = true

        Task {
            do {
                let response = try await NetworkManager.shared.getStrategyAnalysis(sessionId: task.id)
                cacheManager.cacheStrategy(response, for: task.id)
                await MainActor.run {
                    self.strategyAnalysis = response
                    self.strategyIsLoading = false
                }
            } catch {
                await MainActor.run { self.strategyIsLoading = false }
            }
        }
    }

    private func friendlyError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.code == -1001 || error.localizedDescription.contains("timeout") {
            return "Request timed out. Please check your connection."
        } else if ns.code == 404 { return "Moment not found." }
        else if ns.code == 401 || ns.code == 403 { return "Authentication failed, please log in again." }
        return "Failed to load: \(error.localizedDescription)"
    }
}

// MARK: - MomentInfoCard

private struct MomentInfoCard: View {
    let sceneDescription: String?
    let onSummaryTap: () -> Void
    @ObservedObject var audioPlayer: SessionAudioPlayerService
    let moodEmoji: String?
    let moodState: String?
    let startTime: Date
    let strategyIsLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Scene description
            if let desc = sceneDescription {
                Text(desc)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if strategyIsLoading {
                Text("Analyzing scene…")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
                    .italic()
            }

            // Action row: summary | play | share --- mood
            HStack(spacing: 0) {
                // Summary button
                Button(action: onSummaryTap) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.85))
                }

                // Play/pause button
                Button(action: { audioPlayer.togglePlayback() }) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.leading, 22)
                .disabled(audioPlayer.isBuffering)

                // Share button
                Button(action: {
                    let av = UIActivityViewController(
                        activityItems: ["Shared from MicLnk"],
                        applicationActivities: nil
                    )
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let root = scene.windows.first?.rootViewController {
                        root.present(av, animated: true)
                    }
                }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.leading, 22)

                Spacer()

                // Mood
                if let emoji = moodEmoji, let state = moodState {
                    HStack(spacing: 6) {
                        Text(emoji).font(.system(size: 20))
                        Text(state)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
            }

            // Date row
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
                Text(dateString)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#1C1C1E"))
        .cornerRadius(16)
    }

    private var dateString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "yyyy/MM/dd EEEE"
        return f.string(from: startTime)
    }
}

// MARK: - MomentSkillsCard

private struct MomentSkillsCard: View {
    let sceneCategoryName: String?
    let skillCards: [SkillCard]
    @State private var selectedCard: SkillCard?

    private func iconFor(_ cat: String) -> String {
        switch cat {
        case "Work Life": return "briefcase.fill"
        case "Campus":    return "graduationcap.fill"
        case "Social":    return "person.2.fill"
        case "Family":    return "house.fill"
        case "Growth":    return "chart.line.uptrend.xyaxis"
        case "Life":      return "sparkles"
        default:          return "circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Category pill
            if let cat = sceneCategoryName, !cat.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: iconFor(cat))
                        .font(.system(size: 12, weight: .semibold))
                    Text(cat)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue)
                .cornerRadius(20)
            }

            // Skill rows
            VStack(spacing: 0) {
                ForEach(Array(skillCards.enumerated()), id: \.element.id) { idx, card in
                    Button(action: { selectedCard = card }) {
                        HStack(spacing: 12) {
                            Rectangle()
                                .fill(Color.blue)
                                .frame(width: 3)
                                .cornerRadius(2)
                                .padding(.vertical, 2)

                            Text(card.accordionTitle)
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.35))
                        }
                        .frame(minHeight: 46)
                    }
                    .buttonStyle(.plain)

                    if idx < skillCards.count - 1 {
                        Divider()
                            .background(Color.white.opacity(0.1))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#1C1C1E"))
        .cornerRadius(16)
        .sheet(item: $selectedCard) { card in
            SkillCardDetailSheet(card: card)
        }
    }
}

// MARK: - SkillCardDetailSheet  (lightweight sheet showing strategy content)

private struct SkillCardDetailSheet: View {
    let card: SkillCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let strategies = card.content?.strategies, !strategies.isEmpty {
                        ForEach(strategies) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    if let emoji = item.emoji {
                                        Text(emoji).font(.system(size: 18))
                                    }
                                    Text(item.title)
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundColor(.primary)
                                }
                                Text(item.content)
                                    .font(.system(size: 14, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .lineSpacing(5)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                    } else if let moodContent = card.content?.emotionContent {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text(moodContent.moodEmoji).font(.system(size: 36))
                                VStack(alignment: .leading) {
                                    Text(moodContent.moodState)
                                        .font(.system(size: 18, weight: .bold, design: .rounded))
                                    Text("\(moodContent.charCount) characters spoken")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                }
                            }
                            HStack(spacing: 20) {
                                Label("\(moodContent.sighCount) sighs", systemImage: "wind")
                                Label("\(moodContent.hahaCount) laughs", systemImage: "face.smiling")
                            }
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    } else {
                        Text("No details available yet.")
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 100)
                    }
                }
                .padding(20)
            }
            .navigationTitle(card.accordionTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - SummarySheet

private struct SummarySheet: View {
    let summary: String?
    let dialogues: [DialogueItem]
    @Environment(\.dismiss) private var dismiss
    @State private var showDialogue = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let summary = summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 15, weight: .regular, design: .rounded))
                            .foregroundColor(.primary)
                            .lineSpacing(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Summary not available yet.")
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(.secondary)
                    }

                    // View Details & Recording toggle
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.25)) { showDialogue.toggle() }
                    }) {
                        HStack {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 16))
                            Text("View Details & Recording")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Spacer()
                            Image(systemName: showDialogue ? "chevron.up" : "chevron.down")
                                .font(.system(size: 13))
                        }
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)

                    if showDialogue {
                        Divider()
                        DialogueReviewView(summary: nil, dialogues: dialogues)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - DetailHeaderView (unchanged)

struct DetailHeaderView: View {
    @Environment(\.presentationMode) var presentationMode
    var onReportTap: (() -> Void)? = nil

    var body: some View {
        HStack {
            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 39.98, height: 39.98)
                        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(AppColors.headerText)
                }
            }

            Spacer()

            Text("Details")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundColor(AppColors.headerText)
                .tracking(0.5)

            Spacer()

            Button(action: { onReportTap?() }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 39.98, height: 39.98)
                        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(AppColors.headerText)
                }
            }
        }
    }
}

// MARK: - DateTimeInfoBar (kept for backward compatibility, no longer used in main body)

struct DateTimeInfoBar: View {
    let task: TaskItem
    @ObservedObject var audioPlayer: SessionAudioPlayerService

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 18))
                    .foregroundColor(AppColors.headerText.opacity(0.8))
                Text(dateTimeString)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppColors.headerText.opacity(0.8))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 16)
            .frame(height: 37.37)
            .background(
                RoundedRectangle(cornerRadius: 9999)
                    .fill(Color.white.opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: 9999).stroke(Color.white.opacity(0.2), lineWidth: 0.69))
            )

            Spacer(minLength: 8)

            Button(action: { audioPlayer.togglePlayback() }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 49.37, height: 49.37)
                        .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.69))
                        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundColor(AppColors.headerText.opacity(0.8))
                }
            }
            .disabled(audioPlayer.isBuffering)
        }
        .frame(maxWidth: .infinity)
    }

    private var dateTimeString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "yyyy/MM/dd EEEE"
        return f.string(from: task.startTime)
    }
}

// MARK: - ReportMenuPanel (unchanged)

struct ReportMenuPanel: View {
    let sessionId: String
    @Binding var submitted: Bool
    let onDismiss: () -> Void

    private let reasons = [
        ("flag.fill",           "Inappropriate Content"),
        ("c.circle",            "Copyright Issue"),
        ("exclamationmark.shield.fill", "Violence or Hate Speech"),
        ("envelope.badge.fill", "Spam or Misleading"),
        ("questionmark.circle", "Other"),
    ]
    @State private var isSubmitting = false
    @State private var showConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 16)

            if showConfirmation {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(Color(hex: "#34D399"))
                    Text("Report Submitted")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(AppColors.primaryText)
                    Text("Thank you. We'll review this content.")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(AppColors.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .padding(.top, 8)
            } else {
                Text("Report Content")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(AppColors.primaryText)
                    .padding(.bottom, 8)

                Text("Select a reason for your report")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(AppColors.secondaryText)
                    .padding(.bottom, 16)

                VStack(spacing: 1) {
                    ForEach(reasons, id: \.1) { icon, label in
                        Button { submitReport(reason: label) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: icon)
                                    .font(.system(size: 15))
                                    .foregroundColor(AppColors.secondaryText)
                                    .frame(width: 20)
                                Text(label)
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundColor(AppColors.primaryText)
                                Spacer()
                                if isSubmitting { ProgressView().scaleEffect(0.7) }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.05))
                        }
                        .disabled(isSubmitting)
                    }
                }
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                Button("Cancel") { onDismiss() }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColors.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppColors.background)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func submitReport(reason: String) {
        isSubmitting = true
        Task {
            await NetworkManager.shared.submitReport(sessionId: sessionId, reason: reason)
            await MainActor.run {
                isSubmitting = false
                submitted = true
                withAnimation { showConfirmation = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { onDismiss() }
            }
        }
    }
}
