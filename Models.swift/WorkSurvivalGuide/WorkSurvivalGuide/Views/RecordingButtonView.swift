//
//  RecordingButtonView.swift
//  WorkSurvivalGuide
//

import SwiftUI

struct RecordingButtonView: View {
    @ObservedObject var viewModel: RecordingViewModel
    var onUploadTap: () -> Void = {}
    var onTextInputTap: () -> Void = {}

    // 是否正在显示灵动岛开场消息框
    @State private var isIntro: Bool = true
    @State private var introTimer: Timer? = nil
    // 文字脉冲动画
    @State private var textPulse: Bool = false

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
                        // 消息框文字
                        HStack(spacing: 10) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))

                            Text("Tell me what happened today")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(textPulse ? 1.0 : 0.75))
                                .lineLimit(1)
                                .animation(
                                    .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
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
            .disabled(viewModel.isUploading)
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
