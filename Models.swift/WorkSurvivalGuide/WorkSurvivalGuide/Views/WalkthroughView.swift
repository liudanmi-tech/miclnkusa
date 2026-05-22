//
//  WalkthroughView.swift
//  WorkSurvivalGuide
//
//  注册完成后的 5 步线性新手引导
//

import SwiftUI

// MARK: - Data

private struct WalkthroughStep {
    let icon: String
    let title: String
    let description: String
    let gradientColors: [Color]
}

private let walkthroughSteps: [WalkthroughStep] = [
    WalkthroughStep(
        icon: "person.badge.plus",
        title: "创建档案",
        description: "为你的工作对象建立档案，记录 ta 的背景信息",
        gradientColors: [Color(hex: "#4F8EFF"), Color(hex: "#2563EB")]
    ),
    WalkthroughStep(
        icon: "waveform.and.mic",
        title: "上传录音",
        description: "把一段工作对话录制或上传，AI 自动分析内容",
        gradientColors: [Color(hex: "#3ECFCF"), Color(hex: "#0891B2")]
    ),
    WalkthroughStep(
        icon: "sparkles",
        title: "选择技能",
        description: "从技能库挑选你想练的方向，追踪每次进步",
        gradientColors: [Color(hex: "#A78BFA"), Color(hex: "#7C3AED")]
    ),
    WalkthroughStep(
        icon: "brain.head.profile",
        title: "查看 AI 分析",
        description: "进入录音详情，匹配技能后与 AI 深度对话",
        gradientColors: [Color(hex: "#34D399"), Color(hex: "#059669")]
    ),
    WalkthroughStep(
        icon: "face.smiling.fill",
        title: "选择 Emoji 风格",
        description: "在档案设置里选一个专属风格，更有个性",
        gradientColors: [Color(hex: "#FB923C"), Color(hex: "#EA580C")]
    ),
]

// MARK: - WalkthroughView

struct WalkthroughView: View {
    @AppStorage("walkthrough_completed") private var walkthroughCompleted = false
    @State private var currentStep = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                iconArea
                    .padding(.bottom, 36)
                titleArea
                Spacer()
                nextButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 48)
            }
            .padding(.horizontal, 24)
        }
        .animation(.easeInOut(duration: 0.3), value: currentStep)
    }

    // MARK: Top Bar

    private var topBar: some View {
        HStack {
            WalkthroughProgressDots(total: walkthroughSteps.count, current: currentStep)
            Spacer()
            Button("Skip") { skip() }
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.top, 56)
        .padding(.bottom, 8)
    }

    // MARK: Icon Area

    private var iconArea: some View {
        let step = walkthroughSteps[currentStep]
        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: step.gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 110, height: 110)
                .shadow(color: step.gradientColors[1].opacity(0.45), radius: 20, x: 0, y: 8)

            Image(systemName: step.icon)
                .font(.system(size: 44, weight: .medium))
                .foregroundColor(.white)
        }
    }

    // MARK: Title Area

    private var titleArea: some View {
        let step = walkthroughSteps[currentStep]
        return VStack(spacing: 12) {
            Text(step.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text(step.description)
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Next Button

    private var nextButton: some View {
        let isLast = currentStep == walkthroughSteps.count - 1
        let label = isLast ? "去创建档案 →" : "下一步 →"

        return Button(action: advance) {
            Text(label)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
        }
    }

    // MARK: Actions

    private func advance() {
        if currentStep < walkthroughSteps.count - 1 {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentStep += 1
            }
        } else {
            walkthroughCompleted = true
        }
    }

    private func skip() {
        walkthroughCompleted = true
    }
}

// MARK: - Progress Dots

private struct WalkthroughProgressDots: View {
    let total: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .frame(width: i == current ? 20 : 8, height: 8)
                    .foregroundColor(i <= current ? Color.blue : Color.white.opacity(0.2))
                    .animation(.spring(response: 0.3), value: current)
            }
        }
    }
}
