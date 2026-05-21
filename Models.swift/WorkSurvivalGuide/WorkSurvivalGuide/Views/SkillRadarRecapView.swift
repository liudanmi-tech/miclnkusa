//
//  SkillRadarRecapView.swift
//  WorkSurvivalGuide
//
//  5-page Spotify Wrapped-style recap for Skill Radar
//

import SwiftUI

// MARK: - Container

struct SkillRadarRecapView: View {
    let recap: RecapData
    let periodLabel: String

    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0
    @State private var appeared = false
    @State private var bgColor = Color(hex: "#080C14")
    @State private var selectedRange: RadarTimeRange = .thisWeek
    @State private var isLoadingRange = false
    @State private var displayRecap: RecapData

    init(recap: RecapData, periodLabel: String) {
        self.recap = recap
        self.periodLabel = periodLabel
        self._displayRecap = State(initialValue: recap)
    }

    private let pageColors: [String] = [
        "#080C14", "#120A03", "#041A0F", "#040F0C", "#0D0820"
    ]

    private func colorForPage(_ page: Int) -> Color {
        if page == 2, let p3 = displayRecap.page3 {
            return recapPage3BG(mood: p3.dominantMood)
        }
        return Color(hex: pageColors[min(page, pageColors.count - 1)])
    }

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()
                .animation(.easeInOut(duration: 0.35), value: bgColor)

            // Page content
            Group {
                switch currentPage {
                case 0:
                    RecapPage1View(page1: displayRecap.page1, periodLabel: selectedRange.rawValue, appeared: appeared)
                case 1:
                    if let p2 = displayRecap.page2 {
                        RecapPage2View(page2: p2, appeared: appeared)
                    } else {
                        placeholderPage(text: "最好的时刻", icon: "star.fill")
                    }
                case 2:
                    if let p3 = displayRecap.page3 {
                        RecapPage3View(page3: p3, appeared: appeared)
                    } else {
                        placeholderPage(text: "你的感受", icon: "heart.fill")
                    }
                case 3:
                    if let p4 = displayRecap.page4 {
                        RecapPage4View(page4: p4, coverImageUrl: displayRecap.page2?.coverImageUrl, appeared: appeared)
                    } else {
                        placeholderPage(text: "技能说了什么", icon: "chart.bar.fill")
                    }
                case 4:
                    if let p5 = displayRecap.page5 {
                        RecapPage5View(page5: p5, appeared: appeared, onDismiss: { dismiss() })
                    } else {
                        placeholderPage(text: "接下来", icon: "arrow.right.circle.fill")
                    }
                default:
                    EmptyView()
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: currentPage)

            // Progress dots + close button
            VStack {
                HStack {
                    RecapProgressDots(currentPage: currentPage, total: 5)
                        .padding(.leading, 20)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .padding(.trailing, 20)
                }
                .padding(.top, 60)
                Spacer()
            }

            // Time range selector — page 1 only
            if currentPage == 0 {
                VStack {
                    Spacer()
                    VStack(spacing: 8) {
                        HStack(spacing: 24) {
                            // Left arrow
                            Button {
                                navigateRange(-1)
                            } label: {
                                Image(systemName: "chevron.left.circle.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(
                                        selectedRange == RadarTimeRange.allCases.first
                                        ? .white.opacity(0.15)
                                        : .white.opacity(0.55)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedRange == RadarTimeRange.allCases.first || isLoadingRange)

                            // Period label / loading
                            ZStack {
                                if isLoadingRange {
                                    ProgressView()
                                        .tint(.white.opacity(0.6))
                                        .scaleEffect(0.9)
                                } else {
                                    Text(selectedRange.rawValue)
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundColor(.white.opacity(0.85))
                                        .transition(.opacity)
                                        .id(selectedRange)
                                }
                            }
                            .frame(width: 120, height: 24)
                            .animation(.easeInOut(duration: 0.2), value: isLoadingRange)

                            // Right arrow
                            Button {
                                navigateRange(1)
                            } label: {
                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(
                                        selectedRange == RadarTimeRange.allCases.last
                                        ? .white.opacity(0.15)
                                        : .white.opacity(0.55)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedRange == RadarTimeRange.allCases.last || isLoadingRange)
                        }

                        Text("← swipe to change period, tap to continue →")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.white.opacity(0.28))
                    }
                    .padding(.bottom, 52)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: currentPage)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isLoadingRange else { return }
            if currentPage < 4 {
                withAnimation(.easeInOut(duration: 0.35)) {
                    bgColor = colorForPage(currentPage + 1)
                }
                appeared = false
                currentPage += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    appeared = true
                }
            } else {
                dismiss()
            }
        }
        .onAppear {
            bgColor = colorForPage(0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                appeared = true
            }
        }
        .onChange(of: currentPage) { _ in
            appeared = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                appeared = true
            }
        }
    }

    private func navigateRange(_ direction: Int) {
        let cases = RadarTimeRange.allCases
        guard let idx = cases.firstIndex(of: selectedRange) else { return }
        let newIdx = idx + direction
        guard newIdx >= 0 && newIdx < cases.count else { return }
        let newRange = cases[newIdx]
        selectedRange = newRange
        isLoadingRange = true
        Task {
            // Direct API call — do NOT touch SkillsRadarViewModel.shared.recap,
            // otherwise the parent WeeklyStatsDetailSheet would immediately
            // switch away from this view when recap becomes nil.
            let range = newRange.dateRange
            if let data = try? await NetworkManager.shared.getSkillsRadar(
                startDate: range.start, endDate: range.end
            ), let newRecap = data.recap {
                await MainActor.run {
                    appeared = false
                    withAnimation(.easeInOut(duration: 0.25)) { displayRecap = newRecap }
                    isLoadingRange = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        appeared = true   // re-triggers CountingText + stagger animations
                    }
                }
            } else {
                await MainActor.run { isLoadingRange = false }
            }
        }
    }

    @ViewBuilder
    private func placeholderPage(text: String, icon: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.3))
            Text(text)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helper: Page 3 BG Color

private func recapPage3BG(mood: String) -> Color {
    switch mood {
    case "高兴":   return Color(hex: "#041A0F")
    case "焦虑":   return Color(hex: "#1A0C04")
    case "亢奋":   return Color(hex: "#120A1F")
    case "悲伤":   return Color(hex: "#040A1A")
    default:       return Color(hex: "#0A0E1A")  // 平常心
    }
}

// MARK: - Shared Helpers

// Counting number animation
struct CountingText: View {
    let target: Int
    let suffix: String
    let font: Font
    let color: Color

    @State private var display = 0

    init(target: Int, suffix: String = "", font: Font = .system(size: 80, weight: .bold, design: .rounded), color: Color = .white) {
        self.target = target
        self.suffix = suffix
        self.font = font
        self.color = color
    }

    var body: some View {
        Text("\(display)\(suffix)")
            .font(font)
            .foregroundColor(color)
            .onAppear {
                display = 0
                guard target > 0 else { display = 0; return }
                let interval = max(0.05, 0.6 / Double(target))
                var current = 0
                Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
                    current += 1
                    display = current
                    if current >= target {
                        timer.invalidate()
                    }
                }
            }
    }
}

// Staggered word reveal
struct StaggeredWords: View {
    let text: String
    let appeared: Bool
    let baseDelay: Double
    let fontSize: CGFloat
    let weight: Font.Weight
    let color: Color

    init(text: String, appeared: Bool, baseDelay: Double = 0, fontSize: CGFloat = 16, weight: Font.Weight = .regular, color: Color = .white) {
        self.text = text
        self.appeared = appeared
        self.baseDelay = baseDelay
        self.fontSize = fontSize
        self.weight = weight
        self.color = color
    }

    private var words: [String] { text.components(separatedBy: " ") }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                Text(word)
                    .font(.system(size: fontSize, weight: weight, design: .rounded))
                    .foregroundColor(color)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 6)
                    .animation(
                        .spring(response: 0.4, dampingFraction: 0.75)
                            .delay(baseDelay + Double(i) * 0.07),
                        value: appeared
                    )
            }
        }
    }
}

// Ripple circle
struct RippleView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: 2.0)) / 2.0
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxR = min(size.width, size.height) / 2
                let r = maxR * phase
                let opacity = 1.0 - phase
                var ring = Path()
                ring.addEllipse(in: CGRect(
                    x: center.x - r, y: center.y - r,
                    width: r * 2, height: r * 2
                ))
                ctx.stroke(ring, with: .color(.white.opacity(opacity * 0.35)), lineWidth: 1.5)
            }
        }
    }
}

// Progress dots
struct RecapProgressDots: View {
    let currentPage: Int
    let total: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i == currentPage ? Color.white : Color.white.opacity(0.2))
                    .frame(width: i == currentPage ? 18 : 6, height: 4)
                    .animation(.spring(response: 0.3), value: currentPage)
            }
        }
    }
}

// MARK: - Page 1: Cover

struct RecapPage1View: View {
    let page1: RecapPage1
    let periodLabel: String
    let appeared: Bool

    var body: some View {
        ZStack {
            // Blurred mosaic bg
            if !page1.coverUrls.isEmpty {
                GeometryReader { geo in
                    ZStack {
                        ForEach(Array(page1.coverUrls.enumerated()), id: \.offset) { idx, urlStr in
                            ImageLoaderView(imageUrl: urlStr, imageBase64: nil, contentMode: .fill)
                                .frame(
                                    width: geo.size.width * 0.6,
                                    height: geo.size.height * 0.5
                                )
                                .clipped()
                                .offset(
                                    x: CGFloat(idx - 1) * geo.size.width * 0.3,
                                    y: CGFloat(idx % 2 == 0 ? -1 : 1) * geo.size.height * 0.1
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 28)
                    .opacity(0.35)
                }
                .ignoresSafeArea()
            }

            // Vignette
            LinearGradient(
                colors: [Color.black.opacity(0.8), Color.clear, Color.black.opacity(0.9)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Session count — big hero number
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    if appeared {
                        CountingText(
                            target: page1.totalSessions,
                            font: .system(size: 96, weight: .bold, design: .rounded),
                            color: Color(hex: "#B8A4FF")
                        )
                    } else {
                        Text("0")
                            .font(.system(size: 96, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "#B8A4FF"))
                    }
                }
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5), value: appeared)

                Text("个时刻")
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.75))
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)
                    .animation(.easeOut(duration: 0.5).delay(0.15), value: appeared)

                Spacer().frame(height: 40)

                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("横跨")
                            .font(.system(size: 18, design: .rounded))
                            .foregroundColor(.white.opacity(0.55))
                        Text("\(page1.totalScenes)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "#B8A4FF"))
                        Text("个场景")
                            .font(.system(size: 18, design: .rounded))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
                    .animation(.easeOut(duration: 0.45).delay(0.3), value: appeared)

                    HStack(spacing: 6) {
                        Text("\(page1.totalSkillsHit)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "#B8A4FF"))
                        Text("项技能随你出现")
                            .font(.system(size: 18, design: .rounded))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
                    .animation(.easeOut(duration: 0.45).delay(0.45), value: appeared)

                    if !page1.topSceneLabel.isEmpty {
                        HStack(spacing: 6) {
                            Text("最常出现于")
                                .font(.system(size: 16, design: .rounded))
                                .foregroundColor(.white.opacity(0.4))
                            Text(page1.topSceneEmoji + " " + page1.topSceneLabel)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(.easeOut(duration: 0.45).delay(0.6), value: appeared)
                    }
                }

                Spacer().frame(height: 20)

                Text(periodLabel)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.white.opacity(0.3))
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.4).delay(0.75), value: appeared)

                Spacer().frame(height: 100)
            }
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - Page 2: Best Session

struct RecapPage2View: View {
    let page2: RecapPage2
    let appeared: Bool

    var body: some View {
        ZStack {
            Color(hex: "#120A03").ignoresSafeArea()

            // Image: top-aligned with horizontal padding, fixed height
            VStack(spacing: 0) {
                if let urlStr = page2.coverImageUrl, !urlStr.isEmpty {
                    ImageLoaderView(imageUrl: urlStr, imageBase64: nil, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: UIScreen.main.bounds.height * 0.52)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 20)
                        .padding(.top, 60)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeIn(duration: 0.8), value: appeared)
                }
                Spacer()
            }

            // Dark gradient from image bottom into content area
            VStack {
                Spacer().frame(height: UIScreen.main.bounds.height * 0.35)
                LinearGradient(
                    colors: [Color.clear, Color(hex: "#120A03")],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 160)
                Spacer()
            }

            // Content
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                // Header label
                Text("最重要的那一刻")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(Color(hex: "#F59E0B").opacity(0.8))
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.4).delay(0.2), value: appeared)

                Spacer().frame(height: 10)

                // Session title
                Text(page2.sessionTitle)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.35), value: appeared)

                Spacer().frame(height: 6)

                Text(page2.sceneEmoji + " " + page2.sceneLabel + "  ·  " + page2.sessionDate)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.4).delay(0.45), value: appeared)

                Spacer().frame(height: 20)

                // Skill tag pills
                FlowLayout(spacing: 8) {
                    ForEach(Array(page2.skillLabels.enumerated()), id: \.offset) { idx, label in
                        Text(label)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(Color(hex: "#F59E0B"))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(hex: "#F59E0B").opacity(0.15))
                            .clipShape(Capsule())
                            .opacity(appeared ? 1 : 0)
                            .offset(x: appeared ? 0 : -20)
                            .animation(
                                .spring(response: 0.45, dampingFraction: 0.8)
                                    .delay(0.55 + Double(idx) * 0.15),
                                value: appeared
                            )
                    }
                }

                Spacer().frame(height: 110)
            }
            .padding(.horizontal, 28)
        }
    }
}

// MARK: - Page 3: Mood

struct RecapPage3View: View {
    let page3: RecapPage3
    let appeared: Bool

    var accentColor: Color {
        switch page3.dominantMood {
        case "高兴":   return Color(hex: "#34D399")
        case "焦虑":   return Color(hex: "#FB923C")
        case "亢奋":   return Color(hex: "#A78BFA")
        case "悲伤":   return Color(hex: "#60A5FA")
        default:       return Color(hex: "#94A3B8")
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer()

                // Emoji + ripple
                ZStack {
                    RippleView()
                        .frame(width: 180, height: 180)

                    if let urlStr = page3.dominantMoodEmojiUrl, !urlStr.isEmpty {
                        ImageLoaderView(imageUrl: urlStr, imageBase64: nil, contentMode: .fill)
                            .frame(width: 100, height: 100)
                            .clipShape(Circle())
                    } else {
                        Text(page3.dominantMoodEmoji).font(.system(size: 80))
                    }
                }
                .scaleEffect(appeared ? 1 : 0.7)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.65), value: appeared)

                Spacer().frame(height: 24)

                // Dominant mood label
                Text("你的感受")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.4).delay(0.15), value: appeared)

                Spacer().frame(height: 6)

                Text(page3.dominantMood)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(accentColor)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                    .animation(.spring(response: 0.45, dampingFraction: 0.75).delay(0.25), value: appeared)

                Text("是这段时间最常出现的情绪")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.4).delay(0.35), value: appeared)

                Spacer().frame(height: 44)

                // Stats row
                HStack(spacing: 0) {
                    Spacer()
                    statColumn(value: page3.sighTotal, label: "叹气次数", color: Color(hex: "#94A3B8"))
                    Spacer()
                    Divider()
                        .frame(height: 40)
                        .background(Color.white.opacity(0.1))
                    Spacer()
                    statColumn(value: page3.hahaTotal, label: "哈哈次数", color: Color(hex: "#FBBF24"))
                    Spacer()
                }
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.45).delay(0.5), value: appeared)

                Spacer().frame(height: 100)
            }
            .padding(.horizontal, 32)
        }
    }

    @ViewBuilder
    private func statColumn(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            if appeared {
                CountingText(
                    target: value,
                    font: .system(size: 36, weight: .bold, design: .rounded),
                    color: color
                )
            } else {
                Text("0")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
        }
    }
}

// MARK: - Page 4: Skills

struct RecapPage4View: View {
    let page4: RecapPage4
    let coverImageUrl: String?
    let appeared: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer().frame(height: 100)

                // Header
                Text("技能说了什么")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(Color(hex: "#2DD4BF").opacity(0.7))
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.35), value: appeared)

                Spacer().frame(height: 28)

                // Skill rows
                VStack(spacing: 16) {
                    ForEach(Array(page4.topSkills.enumerated()), id: \.element.id) { idx, skill in
                        skillRow(skill, index: idx)
                    }
                }
                .padding(.horizontal, 28)

                Spacer().frame(height: 40)

                // Strategy quote
                if let quote = page4.strategyQuote {
                    ZStack {
                        // Blurred bg
                        if let urlStr = coverImageUrl, !urlStr.isEmpty {
                            ImageLoaderView(imageUrl: urlStr, imageBase64: nil, contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .frame(height: 140)
                                .clipped()
                                .blur(radius: 16)
                                .opacity(0.25)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            StaggeredWords(
                                text: quote.text,
                                appeared: appeared,
                                baseDelay: 0.6,
                                fontSize: 14,
                                weight: .regular,
                                color: .white.opacity(0.8)
                            )
                            .multilineTextAlignment(.leading)
                            .lineLimit(4)

                            Text(quote.sceneLabel + "  ·  " + quote.sessionDate)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(.white.opacity(0.35))
                                .opacity(appeared ? 1 : 0)
                                .animation(.easeOut(duration: 0.4).delay(1.0), value: appeared)
                        }
                        .padding(16)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 28)
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.5).delay(0.5), value: appeared)
                }

                Spacer()
            }
        }
    }

    @ViewBuilder
    private func skillRow(_ skill: RecapTopSkill, index: Int) -> some View {
        HStack(spacing: 12) {
            // Rank
            Text("#\(index + 1)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "#2DD4BF").opacity(0.5))
                .frame(width: 28, alignment: .leading)

            // Skill name
            Text(skill.skillLabel)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(.white)

            Spacer()

            // Hit count
            Text("\(skill.hitCount)x")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(Color(hex: "#2DD4BF").opacity(0.7))

            // Trend
            Text(skill.trendSymbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(
                    skill.trend == "improving" ? Color(hex: "#34D399") :
                    skill.trend == "watch"     ? Color(hex: "#FB923C") :
                                                 Color.white.opacity(0.3)
                )
        }
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : 30)
        .animation(
            .spring(response: 0.45, dampingFraction: 0.8)
                .delay(0.1 + Double(index) * 0.18),
            value: appeared
        )
    }
}

// MARK: - Page 5: Next Steps

struct RecapPage5View: View {
    let page5: RecapPage5
    let appeared: Bool
    let onDismiss: () -> Void

    @State private var btnScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("接下来")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(Color(hex: "#E879F9").opacity(0.7))
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.35), value: appeared)

            Spacer().frame(height: 36)

            VStack(alignment: .leading, spacing: 20) {
                if let improving = page5.improvingSkill {
                    nextLine(
                        prefix: "正在变强",
                        name: improving.skillLabel + " ↑",
                        color: Color(hex: "#34D399"),
                        delay: 0.1
                    )
                }

                if let watch = page5.watchSkill {
                    nextLine(
                        prefix: "可以多留意",
                        name: watch.skillLabel,
                        color: Color(hex: "#FB923C"),
                        delay: 0.25
                    )
                }

                if let rec = page5.recommendations.first {
                    nextLine(
                        prefix: "还没探索过",
                        name: rec.skillLabel,
                        color: Color(hex: "#E879F9"),
                        delay: 0.4
                    )
                }
            }
            .padding(.horizontal, 36)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer().frame(height: 52)

            // CTA Button
            Button {
                onDismiss()
            } label: {
                Text("加入我的技能库")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(hex: "#0D0820"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(hex: "#E879F9"))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .scaleEffect(btnScale)
            .padding(.horizontal, 36)
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.45).delay(0.6), value: appeared)
            .onAppear {
                guard appeared else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeInOut(duration: 0.2)) { btnScale = 1.04 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.easeInOut(duration: 0.2)) { btnScale = 1.0 }
                    }
                }
            }

            Spacer().frame(height: 32)

            // Closing line
            Text("这段时间的你，已经发生了。")
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 1.5).delay(0.9), value: appeared)

            Spacer().frame(height: 100)
        }
    }

    @ViewBuilder
    private func nextLine(prefix: String, name: String, color: Color, delay: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(prefix)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(.white.opacity(0.35))
            Text(name)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
        .animation(.spring(response: 0.45, dampingFraction: 0.75).delay(delay), value: appeared)
    }
}

// MARK: - FlowLayout helper

private struct FlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 8) { self.spacing = spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.map { $0.map { $0.dimensions.height }.max() ?? 0 }.reduce(0, +) +
                     CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowH = row.map { $0.dimensions.height }.max() ?? 0
            for item in row {
                item.view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += item.dimensions.width + spacing
            }
            y += rowH + spacing
        }
    }

    private struct RowItem {
        let view: LayoutSubview
        let dimensions: CGSize
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[RowItem]] {
        let maxW = proposal.width ?? .infinity
        var rows: [[RowItem]] = []
        var currentRow: [RowItem] = []
        var currentX: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if currentX + size.width > maxW && !currentRow.isEmpty {
                rows.append(currentRow)
                currentRow = []
                currentX = 0
            }
            currentRow.append(RowItem(view: view, dimensions: size))
            currentX += size.width + spacing
        }
        if !currentRow.isEmpty { rows.append(currentRow) }
        return rows
    }
}
