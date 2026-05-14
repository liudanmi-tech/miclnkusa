//
//  DebugPanelView.swift
//  WorkSurvivalGuide
//
//  仅 DEBUG 构建可见的悬浮调试面板。
//  - 拖拽可移动
//  - 折叠/展开
//  - 显示 sessionId、各阶段状态、用户点击、错误信息、日志流
//

#if DEBUG || INTERNALTEST
import SwiftUI

// MARK: - Main View

struct DebugPanelView: View {
    @ObservedObject private var logger = DebugLogger.shared

    @State private var isExpanded = false
    @State private var position = CGSize(width: -8, height: 120)  // 从右边向内 8pt，距顶 120pt
    @GestureState private var dragDelta = CGSize.zero
    @State private var tab: DebugTab = .status

    private enum DebugTab { case status, logs, taps }
    private let panelW: CGFloat = 310
    private let panelH: CGFloat = 430

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                // 透明底，填满屏幕，让 overlay 可以接收手势
                Color.clear

                Group {
                    if isExpanded {
                        expandedPanel
                    } else {
                        collapsedPill
                    }
                }
                .offset(
                    x: position.width + dragDelta.width,
                    y: position.height + dragDelta.height
                )
                .gesture(
                    DragGesture()
                        .updating($dragDelta) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            position.width  += value.translation.width
                            position.height += value.translation.height
                        }
                )
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: - Collapsed Pill

    private var collapsedPill: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                isExpanded = true
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: "#34D399"))
                Text("DBG")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                if logger.lastError != nil {
                    Circle()
                        .fill(Color(hex: "#F87171"))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.88))
                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded Panel

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.12))
            tabContent
        }
        .frame(width: panelW)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: "#0A0A0A").opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.6), radius: 24, x: 0, y: 12)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "ladybug.fill")
                .foregroundColor(Color(hex: "#34D399"))
                .font(.system(size: 13, weight: .bold))
            Text("Debug Panel")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)

            Spacer()

            // Tab selector
            HStack(spacing: 0) {
                tabBtn("Status", .status)
                tabBtn("Log",    .logs)
                tabBtn("Taps",   .taps)
            }
            .background(Color.white.opacity(0.07))
            .cornerRadius(7)

            // Close
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    isExpanded = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Color.white.opacity(0.35))
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Tab Content

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .status: statusTab.frame(height: panelH)
        case .logs:   logsTab.frame(height: panelH)
        case .taps:   tapsTab.frame(height: panelH)
        }
    }

    // MARK: - Status Tab

    private var statusTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {

                // Session ID
                sessionRow

                // Status grid
                VStack(spacing: 4) {
                    statusRow(icon: "arrow.up.circle.fill",   label: "Upload",   value: logger.uploadStatus,   color: "#60A5FA")
                    statusRow(icon: "waveform",               label: "Analysis", value: logger.analysisStatus, color: "#A78BFA")
                    statusRow(icon: "target",                 label: "Skills",   value: logger.skillStatus,    color: "#FBBF24")
                    statusRow(icon: "photo.stack.fill",       label: "Images",   value: logger.imageStatus,    color: "#34D399")
                }

                // Last error
                if let err = logger.lastError {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("LAST ERROR", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "#F87171").opacity(0.8))
                        Text(err)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(hex: "#F87171"))
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color(hex: "#F87171").opacity(0.1))
                    .cornerRadius(8)
                }

                // Mini log preview (last 5)
                if !logger.logs.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RECENT LOGS")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.3))
                        ForEach(logger.logs.prefix(5)) { entry in
                            miniLogRow(entry)
                        }
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(8)
                }

                // Clear button
                Button {
                    logger.clear()
                } label: {
                    HStack {
                        Spacer()
                        Label("Clear All", systemImage: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.35))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(12)
        }
    }

    private var sessionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("SESSION ID", systemImage: "key.fill")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.35))

            if let sid = logger.sessionId {
                HStack {
                    Text(sid)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "#60A5FA"))
                        .lineLimit(2)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = sid
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#60A5FA").opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("No session yet")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.25))
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }

    private func statusRow(icon: String, label: String, value: String, color: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: color))
                .frame(width: 18)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.45))
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
    }

    // MARK: - Logs Tab

    private var logsTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 1) {
                if logger.logs.isEmpty {
                    Text("No logs yet…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.25))
                        .padding(16)
                } else {
                    ForEach(logger.logs) { entry in
                        fullLogRow(entry)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Taps Tab

    private var tapsTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                if logger.tapEvents.isEmpty {
                    Text("No tap events yet.\nUser interactions will appear here.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.25))
                        .padding(16)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(logger.tapEvents, id: \.self) { event in
                        Text(event)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(hex: "#FBBF24"))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Log Row Helpers

    private func miniLogRow(_ entry: DebugLogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color(hex: entry.levelColor))
                .frame(width: 5, height: 5)
                .padding(.top, 3)
            Text("\(entry.category.rawValue) \(entry.message)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
        }
    }

    private func fullLogRow(_ entry: DebugLogEntry) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(Color(hex: entry.levelColor))
                .frame(width: 6, height: 6)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(entry.category.rawValue)
                        .font(.system(size: 10))
                    Text(entry.timeString)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.3))
                }
                Text(entry.message)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    // MARK: - Tab Button

    private func tabBtn(_ title: String, _ t: DebugTab) -> some View {
        Button { tab = t } label: {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(tab == t ? .white : Color.white.opacity(0.35))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(tab == t ? Color.white.opacity(0.15) : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        DebugPanelView()
    }
}
#endif
