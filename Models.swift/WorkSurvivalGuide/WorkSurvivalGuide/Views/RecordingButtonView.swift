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
                        // 消息框文字（分析中时显示 Analyzing...）
                        HStack(spacing: 10) {
                            if isLocked {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.75)))
                                    .scaleEffect(0.75)
                            } else {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.75))
                            }

                            Text(isLocked ? "Analyzing..." : "Tell me what happened today")
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
                        // 录音按钮图标
                        Group {
                            if viewModel.isRecording {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(.white)
                            } else if isLocked {
                                // 分析中：显示 spinner，禁止新录音
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.6)))
                                    .scaleEffect(0.9)
                            } else {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isUploading || isLocked)
        }
        .animation(.spring(response: 0.52, dampingFraction: 0.80), value: isIntro)
        .onAppear {
            textPulse = true
            startIntroTimer()
        }
        .onDisappear {
            cancelTimer()
        }
        // 录音过程中若 intro 还没消，强制收起
        .onChange(of: viewModel.isRecording) { recording in
            if recording && isIntro {
                dismissIntro()
            }
        }
    }

    // MARK: - Actions

    private func handleTap() {
        // 上一条录音仍在分析中，禁止开始新录音（停止当前录音不受影响）
        guard !isLocked else { return }

        if isIntro {
            // 5秒内点击：立即收起 → 进入录音
            dismissIntro()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                viewModel.startRecording()
            }
        } else {
            if viewModel.isRecording {
                viewModel.stopRecordingAndUpload()
            } else {
                viewModel.startRecording()
            }
        }
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
