//
//  RecordingButtonView.swift
//  WorkSurvivalGuide
//

import SwiftUI

struct RecordingButtonView: View {
    @ObservedObject var viewModel: RecordingViewModel
    @ObservedObject private var taskListVM = TaskListViewModel.shared
    var onUploadTap: () -> Void = {}
    var onTextInputTap: () -> Void = {}

    // 是否正在显示灵动岛开场消息框
    @State private var isIntro: Bool = true
    @State private var introTimer: Timer? = nil
    // 文字脉冲动画
    @State private var textPulse: Bool = false

    /// 上一条录音仍在分析中（非录音过程中）
    private var isLocked: Bool {
        taskListVM.isProcessing && !viewModel.isRecording && !viewModel.isUploading
    }

    private let circleSize: CGFloat = 64
    private let pillWidth: CGFloat = 272
    // pill 高度 = circleSize，只让宽度变化，保证动效干净
    private let pillHeight: CGFloat = 64

    var body: some View {
        // trailing 对齐：右边缘固定 → 向右收起效果
        ZStack(alignment: .trailing) {
            // 聚光灯锚点：始终与圆形按钮重合，不随 pill 展开变大
            Color.clear
                .frame(width: circleSize, height: circleSize)
                .allowsHitTesting(false)
                .tourHighlight(.recordingButton)

            Button(action: handleTap) {
                ZStack {
                    // ── 毛玻璃背景（同 BottomNavView）──────────────────
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .frame(
                            width: isIntro ? pillWidth : circleSize,
                            height: pillHeight
                        )
                        .overlay(
                            Capsule()
                                .stroke(borderGradient, lineWidth: isIntro ? 1.2 : 2)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 4)

                    // ── 内容区域 ────────────────────────────────────────
                    if isIntro {
                        // 消息框文字（分析中/创建中时显示 spinner）
                        HStack(spacing: 10) {
                            if isLocked || viewModel.isCreatingSession {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.75)))
                                    .scaleEffect(0.75)
                            } else {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.75))
                            }

                            Text(isLocked ? "Analyzing..." : viewModel.isCreatingSession ? "Starting chat..." : "Tell me what happened today")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(isLocked ? 0.5 : (textPulse ? 1.0 : 0.75)))
                                .lineLimit(1)
                                .animation(
                                    isLocked ? .none : .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                                    value: textPulse
                                )
                        }
                        .transition(.opacity)
                    } else {
                        // 圆形按钮图标
                        Group {
                            if viewModel.isCreatingSession || isLocked {
                                // 创建中 / 分析中：显示 spinner
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.6)))
                                    .scaleEffect(0.9)
                            } else {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isUploading || isLocked || viewModel.isCreatingSession)
        }
        .animation(.spring(response: 0.52, dampingFraction: 0.80), value: isIntro)
        .onAppear {
            textPulse = true
            startIntroTimer()
        }
        .onDisappear {
            cancelTimer()
        }
        // 开始创建 session 时若 intro 还没消，强制收起
        .onChange(of: viewModel.isCreatingSession) { creating in
            if creating && isIntro {
                dismissIntro()
            }
        }
    }

    // MARK: - Actions

    private func handleTap() {
        // 引导第3步：只要点击了按钮就推进
        if TourManager.shared.currentStep == .recordingButton {
            TourManager.shared.advance()
        }

        guard !isLocked else { return }

        if isIntro { dismissIntro() }
        viewModel.createChatSession()
    }

    // MARK: - Timer

    private func startIntroTimer() {
        cancelTimer()
        introTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            DispatchQueue.main.async { dismissIntro() }
        }
    }

    private func cancelTimer() {
        introTimer?.invalidate()
        introTimer = nil
    }

    private func dismissIntro() {
        cancelTimer()
        withAnimation(.spring(response: 0.52, dampingFraction: 0.80)) {
            isIntro = false
        }
    }

    // MARK: - Style

    /// 边缘光晕渐变（上亮下暗，仿灵动岛高光）
    private var borderGradient: AngularGradient {
        AngularGradient(
            colors: [
                .white.opacity(0.55),
                .white.opacity(0.12),
                .white.opacity(0.55),
                .white.opacity(0.12),
            ],
            center: .center
        )
    }
}
