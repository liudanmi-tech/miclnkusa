//
//  TourOverlayView.swift
//  WorkSurvivalGuide
//
//  全局聚光灯引导层
//

import SwiftUI

// MARK: - TourOverlayView

struct TourOverlayView: View {
    @ObservedObject private var tour = TourManager.shared

    var body: some View {
        ZStack {
            if let step = tour.currentStep, tour.highlightFrame != .zero {
                let fr = tour.highlightFrame
                let r = max(fr.width, fr.height) / 2 + 22

                // Dimmed overlay with circular cutout (purely visual, no hit-testing)
                SpotlightMask(cx: fr.midX, cy: fr.midY, r: r)
                    .fill(Color.black.opacity(0.72), style: FillStyle(eoFill: true))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // Pulsing ring (purely visual)
                PulsingRing(radius: r)
                    .position(x: fr.midX, y: fr.midY)
                    .id(step)
                    .allowsHitTesting(false)

                TooltipBubble(step: step, frame: fr, spotRadius: r, tour: tour)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: tour.currentStep)
        .ignoresSafeArea()
    }

}

// MARK: - Tooltip（含 Skip / 关闭按钮）

private struct TooltipBubble: View {
    let step: TourStep
    let frame: CGRect
    let spotRadius: CGFloat
    let tour: TourManager

    private var screenH: CGFloat { UIScreen.main.bounds.height }
    private var screenW: CGFloat { UIScreen.main.bounds.width }
    private var isInBottomHalf: Bool { frame.midY > screenH * 0.55 }

    private var tipY: CGFloat {
        isInBottomHalf
            ? frame.midY - spotRadius - 60
            : frame.midY + spotRadius + 60
    }
    private var clampedX: CGFloat {
        min(max(frame.midX, 150), screenW - 150)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isInBottomHalf { arrow }
            bubbleContent
            if isInBottomHalf { arrow }
        }
        .position(x: clampedX, y: tipY)
    }

    // 气泡主体：提示文字 + 分割线 + step/Skip 行
    private var bubbleContent: some View {
        VStack(spacing: 0) {
            Text(step.tooltip)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.12))

            HStack {
                if let label = step.label {
                    Text(label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                if step.isMainTour {
                    Button("Skip") { tour.skipMainTour() }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                } else {
                    Button(action: { tour.dismissExtraTip() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(white: 0.14))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        )
    }

    private var arrow: some View {
        ArrowShape()
            .fill(Color(white: 0.14))
            .frame(width: 14, height: 7)
            .rotationEffect(isInBottomHalf ? .degrees(0) : .degrees(180))
    }
}

private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Spotlight mask (even-odd fill)

private struct SpotlightMask: Shape {
    var cx: CGFloat
    var cy: CGFloat
    var r:  CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(cx, cy), r) }
        set { cx = newValue.first.first; cy = newValue.first.second; r = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect)
        p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        return p
    }
}

// MARK: - Pulsing ring

private struct PulsingRing: View {
    let radius: CGFloat
    @State private var go = false

    var body: some View {
        Circle()
            .stroke(Color.white.opacity(go ? 0 : 0.5), lineWidth: 2)
            .frame(width: radius * 2, height: radius * 2)
            .scaleEffect(go ? 1.3 : 1.0)
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: go)
            .onAppear { go = true }
    }
}

// MARK: - TourHighlight modifier (reports element frame to TourManager)

private struct TourHighlightModifier: ViewModifier {
    let step: TourStep
    @ObservedObject private var tour = TourManager.shared

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        if tour.currentStep == step {
                            tour.setHighlightFrame(geo.frame(in: .global))
                        }
                    }
                    .onChange(of: tour.currentStep) { s in
                        if s == step {
                            tour.setHighlightFrame(geo.frame(in: .global))
                        }
                    }
            }
        )
    }
}

extension View {
    /// Apply spotlight highlight for a tour step. Pass nil to skip.
    @ViewBuilder
    func tourHighlight(_ step: TourStep?) -> some View {
        if let step = step {
            modifier(TourHighlightModifier(step: step))
        } else {
            self
        }
    }
}
