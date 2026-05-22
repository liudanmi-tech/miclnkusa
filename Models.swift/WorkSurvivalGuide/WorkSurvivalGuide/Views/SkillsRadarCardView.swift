//
//  SkillsRadarCardView.swift
//  WorkSurvivalGuide
//
//  技能雷达卡片：Level 1 场景雷达图（无二级）
//  详情页由 SkillsRadarDetailPage 承载：雷达图 + 高光时刻 + 分场景技能表现/推荐
//

import SwiftUI

// MARK: - Radar Card (Level 1 only, used in carousel)

struct SkillsRadarCardView: View {
    @StateObject private var vm = SkillsRadarViewModel.shared
    let startDate: String
    let endDate: String
    let periodLabel: String

    var body: some View {
        ZStack {
            // Background: deep blue-black gradient
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#080C14"), Color(hex: "#0D0820")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                )

            // Blurred Gemini image bg (when recap cover available)
            if let urlStr = vm.recap?.page1.coverUrls.first {
                ImageLoaderView(imageUrl: urlStr, imageBase64: nil, contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 8)
                    .opacity(0.55)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            // Vignette overlay
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.45), Color.black.opacity(0.65)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Content
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("⚡ Skills Radar")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text(periodLabel)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.25))
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Spacer()

                if vm.isLoading {
                    HStack { Spacer(); ProgressView().tint(.white.opacity(0.4)); Spacer() }
                } else if let p1 = vm.recap?.page1 {
                    // Core stats row
                    HStack(spacing: 0) {
                        cardStat(value: "\(p1.totalSessions)", label: "Moments")
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 0.5, height: 32)
                        cardStat(value: "\(p1.totalScenes)", label: "Scenes")
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 0.5, height: 32)
                        cardStat(value: "\(p1.totalSkillsHit)", label: "Skills")
                    }
                    .padding(.horizontal, 14)

                    // Scene pills
                    HStack(spacing: 6) {
                        ForEach(vm.scenes.prefix(3)) { scene in
                            Text(scene.scene_emoji + " " + scene.scene_label)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.75))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                } else {
                    Text("Record skills, unlock stories")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.white.opacity(0.3))
                        .padding(.horizontal, 14)
                }

                Spacer()

                // 5 chapter dots
                HStack(spacing: 5) {
                    ForEach(0..<5, id: \.self) { i in
                        Circle()
                            .fill(vm.recap != nil
                                  ? (i == 0 ? Color(hex: "#B8A4FF") : Color.white.opacity(0.2))
                                  : Color.white.opacity(0.08))
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .padding(.horizontal, 20)
        .task {
            await vm.load(startDate: startDate, endDate: endDate)
        }
    }

    @ViewBuilder
    private func cardStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Radar Time Range

enum RadarTimeRange: String, CaseIterable {
    case thisWeek  = "This Week"
    case lastWeek  = "Last Week"
    case past30    = "Past 30 Days"

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var dateRange: (start: String, end: String) {
        let cal = Calendar.current
        let today = Date()
        switch self {
        case .thisWeek:
            let monday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today))!
            return (RadarTimeRange.fmt.string(from: monday), RadarTimeRange.fmt.string(from: today))
        case .lastWeek:
            let monday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today))!
            let lastMon = cal.date(byAdding: .day, value: -7, to: monday)!
            let lastSun = cal.date(byAdding: .day, value: -1, to: monday)!
            return (RadarTimeRange.fmt.string(from: lastMon), RadarTimeRange.fmt.string(from: lastSun))
        case .past30:
            let start = cal.date(byAdding: .day, value: -29, to: today)!
            return (RadarTimeRange.fmt.string(from: start), RadarTimeRange.fmt.string(from: today))
        }
    }
}

// MARK: - Radar Pill Tab Bar

struct RadarPillTabs: View {
    @Binding var selected: RadarTimeRange

    var body: some View {
        HStack(spacing: 6) {
            ForEach(RadarTimeRange.allCases, id: \.self) { range in
                let isSelected = selected == range
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selected = range }
                } label: {
                    Text(range.rawValue)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(isSelected ? Color(hex: "#45B7D1") : .white.opacity(0.4))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color(hex: "#45B7D1").opacity(0.15) : Color.clear)
                                .overlay(
                                    Capsule().stroke(
                                        isSelected ? Color(hex: "#45B7D1").opacity(0.4) : Color.clear,
                                        lineWidth: 0.8
                                    )
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }
}

// MARK: - Detail Page (opened from sheet — radar + highlights + insight)

struct SkillsRadarDetailPage: View {
    @StateObject private var vm = SkillsRadarViewModel.shared
    @StateObject private var insightVM = RadarInsightViewModel()
    let startDate: String
    let endDate: String
    let periodLabel: String

    @State private var selectedRange: RadarTimeRange = .thisWeek
    @State private var showRecap = false

    private var activeStart: String { selectedRange.dateRange.start }
    private var activeEnd:   String { selectedRange.dateRange.end }

    private var totalSessions: Int {
        vm.scenes.reduce(0) { $0 + $1.session_count }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                // ── Time range pill tabs + Story button ────────────────
                HStack(spacing: 0) {
                    RadarPillTabs(selected: $selectedRange)
                    if vm.recap != nil {
                        Button { showRecap = true } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Story")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(Color(hex: "#B8A4FF"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color(hex: "#B8A4FF").opacity(0.12))
                                    .overlay(Capsule().stroke(Color(hex: "#B8A4FF").opacity(0.4), lineWidth: 0.8))
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 20)
                    }
                }
                .padding(.bottom, 8)

                if vm.isLoading {
                    Spacer()
                    ProgressView().tint(.white.opacity(0.5))
                    Spacer()
                } else if vm.scenes.isEmpty {
                    Spacer()
                    Text("No skill data this period")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(.white.opacity(0.35))
                    Spacer()
                } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 24) {

                            // ── Radar Chart + [Insight] button ────────────
                            ZStack(alignment: .topTrailing) {
                                RadarChartView(
                                    axes: vm.scenes.map {
                                        RadarAxis(
                                            id: $0.scene_id,
                                            label: $0.scene_emoji + "\n" + $0.scene_label,
                                            value: $0.normalizedValue,
                                            dotColor: Color(hex: "#45B7D1")
                                        )
                                    },
                                    fillColor: Color(hex: "#45B7D1"),
                                    onTapAxisIndex: nil
                                )
                                .frame(height: 220)

                                // Insight button — visible when idle or complete
                                if insightVM.state == .idle || insightVM.state == .complete {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.4)) {
                                            proxy.scrollTo("insightAnchor", anchor: .top)
                                        }
                                        if insightVM.state == .idle {
                                            insightVM.generate(
                                                startDate: activeStart,
                                                endDate: activeEnd,
                                                totalSessions: totalSessions
                                            )
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "sparkles")
                                                .font(.system(size: 10, weight: .semibold))
                                            Text("Insight")
                                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        }
                                        .foregroundColor(Color(hex: "#45B7D1"))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule()
                                                .fill(Color(hex: "#45B7D1").opacity(0.12))
                                                .overlay(Capsule().stroke(Color(hex: "#45B7D1").opacity(0.35), lineWidth: 0.8))
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 8)
                                    .padding(.trailing, 4)
                                }
                            }
                            .padding(.horizontal, 20)

                            // ── 高光时刻 ──────────────────────────────────
                            if !vm.highlights.isEmpty {
                                RadarSectionHeader(title: "Recent Highlights")
                                VStack(spacing: 10) {
                                    ForEach(vm.highlights) { h in
                                        RadarHighlightCard(highlight: h)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }

                            // ── Insight 锚点 + 内容 ────────────────────────
                            Color.clear.frame(height: 1).id("insightAnchor")

                            switch insightVM.state {
                            case .idle:
                                EmptyView()

                            case .loading:
                                HStack {
                                    Spacer()
                                    VStack(spacing: 8) {
                                        ProgressView().tint(Color(hex: "#45B7D1"))
                                        Text("Generating insights...")
                                            .font(.system(size: 11, design: .rounded))
                                            .foregroundColor(.white.opacity(0.35))
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 32)

                            case .streaming, .complete:
                                ForEach(insightVM.scenes) { scene in
                                    SceneInsightBlock(
                                        scene: scene,
                                        isStreaming: insightVM.streamingSceneId == scene.sceneId
                                    )
                                }

                            case .tooFew:
                                Text("Not enough recordings yet. Come back after a few more conversations to unlock your Insight.")
                                    .font(.system(size: 13, design: .rounded))
                                    .foregroundColor(.white.opacity(0.4))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 24)
                                    .frame(maxWidth: .infinity)

                            case .error(let msg):
                                Text(msg)
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundColor(Color(hex: "#F87171").opacity(0.8))
                                    .padding(.horizontal, 16)
                            }
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 48)
                    }
                }
                }  // else (has data)
            }  // VStack(spacing: 0)
        }
        .fullScreenCover(isPresented: $showRecap) {
            if let recap = vm.recap {
                SkillRadarRecapView(recap: recap, periodLabel: selectedRange.rawValue)
            }
        }
        .task(id: activeStart + activeEnd) {
            insightVM.resetAndCheckCache(startDate: activeStart, endDate: activeEnd, totalSessions: 0)
            vm.reset()
            await vm.load(startDate: activeStart, endDate: activeEnd)
            insightVM.resetAndCheckCache(
                startDate: activeStart,
                endDate: activeEnd,
                totalSessions: totalSessions
            )
        }
    }
}

// MARK: - Scene Insight Block (streaming scene card)

private struct SceneInsightBlock: View {
    let scene: SceneInsightResult
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Scene header
            HStack(spacing: 8) {
                Text(scene.sceneEmoji).font(.system(size: 16))
                Text(scene.sceneLabel)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Text("\(scene.sessionCount) recordings")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 16)

            // AI Insight text (streaming)
            if !scene.insightText.isEmpty || isStreaming {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#45B7D1").opacity(0.7))
                        .padding(.top, 2)
                    Text(scene.insightText + (isStreaming ? "▋" : ""))
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                        .lineSpacing(4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(hex: "#45B7D1").opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(hex: "#45B7D1").opacity(0.15), lineWidth: 0.6)
                )
                .padding(.horizontal, 16)
            }

            // Skills + Recs — 流式完成后才显示
            if !isStreaming {
                let activeSkills = scene.skills.filter { $0.hit_count > 0 }
                if !activeSkills.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Skill Performance")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .padding(.horizontal, 16)
                        VStack(spacing: 5) {
                            ForEach(activeSkills) { skill in
                                SkillRowCard(skill: skill)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if !scene.recommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recommended")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .padding(.horizontal, 16)
                        VStack(spacing: 5) {
                            ForEach(scene.recommendations) { rec in
                                RecommendationRow(rec: rec, onAdded: {})
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }

            Divider()
                .background(Color.white.opacity(0.07))
                .padding(.horizontal, 16)
        }
    }
}

// MARK: - Section Header

private struct RadarSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
    }
}

// MARK: - Highlight Card (moment-style row)

struct RadarHighlightCard: View {
    let highlight: RadarHighlight

    var body: some View {
        HStack(spacing: 12) {
            // Cover image (56×56, same as WeeklySessionRow)
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(white: 0.18))
                if let url = highlight.cover_image_url, !url.isEmpty {
                    ImageLoaderView(
                        imageUrl: url,
                        imageBase64: nil,
                        placeholder: "",
                        contentMode: .fill
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text(highlight.scene_emoji)
                        .font(.system(size: 22))
                }
            }
            .frame(width: 56, height: 56)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.session_title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                // Skills hit
                HStack(spacing: 4) {
                    ForEach(highlight.skill_labels.prefix(3), id: \.self) { label in
                        Text(label)
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundColor(Color(hex: "#34D399"))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: "#34D399").opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Text(highlight.session_date)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.35))
                    Text("·")
                        .foregroundColor(.white.opacity(0.2))
                    Text(highlight.scene_emoji + " " + highlight.scene_label)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

// MARK: - Per-Scene Assessment Section

private struct SceneAssessmentSection: View {
    let scene: RadarScene
    @StateObject private var vm = SkillsRadarViewModel.shared

    private var activeSkills: [RadarSkill] { scene.skills.filter { $0.hit_count > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Scene header
            HStack(spacing: 8) {
                Text(scene.scene_emoji)
                    .font(.system(size: 16))
                Text(scene.scene_label)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Text("\(scene.session_count) recordings")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 16)

            // 技能表现
            if !activeSkills.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("技能表现")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.35))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .padding(.horizontal, 16)
                    VStack(spacing: 5) {
                        ForEach(activeSkills) { skill in
                            SkillRowCard(skill: skill)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // 推荐添加
            if !scene.recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("推荐添加")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.35))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .padding(.horizontal, 16)
                    VStack(spacing: 5) {
                        ForEach(scene.recommendations) { rec in
                            RecommendationRow(rec: rec, onAdded: {
                                vm.markRecommendationAdded(skillId: rec.skill_id)
                            })
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            Divider()
                .background(Color.white.opacity(0.07))
                .padding(.horizontal, 16)
        }
    }
}

// MARK: - Skill Row (active)

private struct SkillRowCard: View {
    let skill: RadarSkill

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.skill_label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        Circle()
                            .fill(i < skill.pipCount ? Color(hex: "#45B7D1") : Color.white.opacity(0.1))
                            .frame(width: 5, height: 5)
                    }
                    if let level = skill.level {
                        Text(level)
                            .font(.system(size: 9, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                            .padding(.leading, 2)
                    }
                }
            }
            Spacer()
            SparklineView(data: skill.sparkline)
                .frame(width: 48, height: 18)
            HStack(spacing: 2) {
                Text(skill.trendSymbol).font(.system(size: 10, weight: .bold))
                Text(skill.trendLabel).font(.system(size: 9, design: .rounded))
            }
            .foregroundColor(skill.trendColor)
            .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - Recommendation Row

private struct RecommendationRow: View {
    let rec: RadarRecommendation
    let onAdded: () -> Void
    @State private var added = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.skill_label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                Text(rec.reason)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(.white.opacity(0.3))
                    .lineLimit(1)
            }
            Spacer()
            Button(action: { guard !added else { return }; added = true; onAdded() }) {
                HStack(spacing: 3) {
                    Image(systemName: added ? "checkmark" : "plus")
                        .font(.system(size: 9, weight: .bold))
                    Text(added ? "Added" : "Add")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .foregroundColor(added ? Color(hex: "#34D399") : Color(hex: "#45B7D1"))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(
                            added ? Color(hex: "#34D399").opacity(0.5) : Color(hex: "#45B7D1").opacity(0.5),
                            lineWidth: 0.8
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - Sparkline

private struct SparklineView: View {
    let data: [Int]

    var body: some View {
        Canvas { ctx, size in
            guard !data.isEmpty else { return }
            let n = data.count
            let step = size.width / CGFloat(max(n - 1, 1))
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height / 2))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(baseline, with: .color(.white.opacity(0.07)), lineWidth: 0.8)
            var linePath = Path()
            var started = false
            for (i, val) in data.enumerated() {
                let x = CGFloat(i) * step
                let y = val == 1 ? size.height * 0.12 : size.height * 0.88
                if !started { linePath.move(to: CGPoint(x: x, y: y)); started = true }
                else { linePath.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(linePath, with: .color(.white.opacity(0.2)), lineWidth: 1)
            for (i, val) in data.enumerated() {
                let x = CGFloat(i) * step
                let y = val == 1 ? size.height * 0.12 : size.height * 0.88
                ctx.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)),
                         with: .color(val == 1 ? Color(hex: "#34D399") : Color.white.opacity(0.12)))
            }
        }
    }
}

// MARK: - Radar Chart

struct RadarAxis: Identifiable {
    let id: String
    let label: String
    let value: Double
    let dotColor: Color
}

struct RadarChartView: View {
    let axes: [RadarAxis]
    let fillColor: Color
    let onTapAxisIndex: ((Int) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxR = min(size.width, size.height) / 2 - 28
            let n = axes.count
            guard n >= 2 else {
                return AnyView(
                    Text(axes.first?.label ?? "")
                        .foregroundColor(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                )
            }
            return AnyView(
                ZStack {
                    Canvas { ctx, sz in
                        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                        let r = min(sz.width, sz.height) / 2 - 28
                        for ring in [0.33, 0.66, 1.0] as [Double] {
                            var p = Path()
                            for i in 0..<n {
                                let pt = radarPoint(c: c, r: r * ring, i: i, n: n)
                                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                            }
                            p.closeSubpath()
                            ctx.stroke(p, with: .color(.white.opacity(ring == 1.0 ? 0.1 : 0.06)), lineWidth: 0.6)
                        }
                        for i in 0..<n {
                            var ap = Path()
                            ap.move(to: c)
                            ap.addLine(to: radarPoint(c: c, r: r, i: i, n: n))
                            ctx.stroke(ap, with: .color(.white.opacity(0.08)), lineWidth: 0.6)
                        }
                    }
                    Canvas { ctx, sz in
                        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                        let r = min(sz.width, sz.height) / 2 - 28
                        var p = Path()
                        for (i, axis) in axes.enumerated() {
                            let pt = radarPoint(c: c, r: r * CGFloat(axis.value), i: i, n: n)
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                        p.closeSubpath()
                        ctx.fill(p, with: .color(fillColor.opacity(0.22)))
                        ctx.stroke(p, with: .color(fillColor.opacity(0.65)), lineWidth: 1.5)
                    }
                    ForEach(Array(axes.enumerated()), id: \.element.id) { idx, axis in
                        let dotPt = radarPoint(c: center, r: maxR * CGFloat(axis.value), i: idx, n: n)
                        let labelPt = radarPoint(c: center, r: maxR + 18, i: idx, n: n)
                        Circle()
                            .fill(axis.dotColor)
                            .frame(width: 7, height: 7)
                            .position(dotPt)
                        Text(axis.label)
                            .font(.system(size: 8.5, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 60)
                            .position(labelPt)
                        if onTapAxisIndex != nil {
                            Circle()
                                .fill(Color.clear)
                                .frame(width: 36, height: 36)
                                .contentShape(Circle())
                                .position(dotPt)
                                .onTapGesture { onTapAxisIndex?(idx) }
                        }
                    }
                }
            )
        }
    }

    private func radarPoint(c: CGPoint, r: CGFloat, i: Int, n: Int) -> CGPoint {
        let angle = -Double.pi / 2 + Double(i) * 2 * Double.pi / Double(n)
        return CGPoint(x: c.x + r * CGFloat(cos(angle)),
                       y: c.y + r * CGFloat(sin(angle)))
    }
}
