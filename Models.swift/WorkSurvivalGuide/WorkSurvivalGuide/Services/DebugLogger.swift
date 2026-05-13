//
//  DebugLogger.swift
//  WorkSurvivalGuide
//
//  仅 DEBUG 构建可见的日志收集单例，供 DebugPanelView 展示。
//

#if DEBUG
import Foundation
import UIKit

// MARK: - Log Entry

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let level: Level
    let category: Category
    let message: String

    enum Level { case info, success, warning, error }

    enum Category: String {
        case upload   = "📤"
        case analysis = "🔍"
        case skills   = "🎯"
        case images   = "🖼️"
        case network  = "🌐"
        case ui       = "👆"
        case system   = "⚙️"
    }

    var levelColor: String {
        switch level {
        case .info:    return "#60A5FA"
        case .success: return "#34D399"
        case .warning: return "#FBBF24"
        case .error:   return "#F87171"
        }
    }

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.S"
        return f.string(from: timestamp)
    }
}

// MARK: - DebugLogger

final class DebugLogger: ObservableObject {
    static let shared = DebugLogger()

    private let maxEntries = 150
    private var observers: [NSObjectProtocol] = []

    @Published private(set) var logs: [DebugLogEntry] = []
    @Published private(set) var sessionId: String?
    @Published private(set) var uploadStatus:   String = "—"
    @Published private(set) var analysisStatus: String = "—"
    @Published private(set) var skillStatus:    String = "—"
    @Published private(set) var imageStatus:    String = "—"
    @Published private(set) var lastError:      String?
    /// 用户点击事件列表（最近 20 条）
    @Published private(set) var tapEvents: [String] = []

    private init() { registerNotifications() }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public API

    func setSession(_ id: String?) {
        run {
            self.sessionId = id
            if let id {
                self.append(.success, .system, "Session: \(id.prefix(8))…")
            }
        }
    }

    func setUploadStatus(_ s: String) {
        run { self.uploadStatus = s }
    }

    func setAnalysisStatus(_ s: String) {
        run { self.analysisStatus = s }
    }

    func setSkillStatus(_ s: String) {
        run { self.skillStatus = s }
    }

    func setImageStatus(_ s: String) {
        run { self.imageStatus = s }
    }

    func log(_ level: DebugLogEntry.Level, _ category: DebugLogEntry.Category, _ message: String) {
        run { self.append(level, category, message) }
    }

    func recordTap(_ label: String) {
        run {
            let stamp = DateFormatter().then { $0.dateFormat = "HH:mm:ss" }.string(from: Date())
            self.tapEvents.insert("[\(stamp)] \(label)", at: 0)
            if self.tapEvents.count > 20 { self.tapEvents = Array(self.tapEvents.prefix(20)) }
            self.append(.info, .ui, "Tap: \(label)")
        }
    }

    func clear() {
        run {
            self.logs.removeAll()
            self.sessionId     = nil
            self.uploadStatus  = "—"
            self.analysisStatus = "—"
            self.skillStatus   = "—"
            self.imageStatus   = "—"
            self.lastError     = nil
            self.tapEvents.removeAll()
        }
    }

    // MARK: - Private

    private func run(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() }
        else { DispatchQueue.main.async(execute: block) }
    }

    private func append(_ level: DebugLogEntry.Level, _ category: DebugLogEntry.Category, _ message: String) {
        let entry = DebugLogEntry(level: level, category: category, message: message)
        logs.insert(entry, at: 0)
        if logs.count > maxEntries { logs = Array(logs.prefix(maxEntries)) }
        if level == .error { lastError = message }
    }

    // MARK: - Notification Observers

    private func registerNotifications() {
        let nc = NotificationCenter.default
        func observe(_ name: String, handler: @escaping (Notification) -> Void) {
            let obs = nc.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main, using: handler)
            observers.append(obs)
        }

        observe("NewTaskCreated") { [weak self] notif in
            guard let task = notif.object as? TaskItem else { return }
            self?.sessionId     = task.id
            self?.uploadStatus  = "Creating…"
            self?.analysisStatus = "—"
            self?.skillStatus   = "—"
            self?.imageStatus   = "—"
            self?.append(.info, .upload, "New task: \(task.id.prefix(8))")
        }

        observe("TaskStatusUpdated") { [weak self] notif in
            guard let task = notif.object as? TaskItem else { return }
            let desc = task.progressDescription.map { " · \($0)" } ?? ""
            self?.append(.info, .analysis, "Status → \(task.status.rawValue)\(desc)")
        }

        observe("TaskProgressUpdated") { [weak self] notif in
            guard let info = notif.userInfo,
                  let desc = info["progressDescription"] as? String else { return }
            self?.analysisStatus = desc
            self?.append(.info, .analysis, desc)
        }

        observe("TaskAnalysisCompleted") { [weak self] notif in
            guard let task = notif.object as? TaskItem else { return }
            let hasCover = task.coverImageUrl != nil
            self?.imageStatus = hasCover ? "Done ✓ cover=yes" : "Done (no cover)"
            self?.append(.success, .images, "Completed · cover=\(hasCover) · \(task.id.prefix(8))")
        }

        observe("TaskAnalysisFailed") { [weak self] notif in
            let msg = (notif.userInfo?["message"] as? String) ?? "Unknown error"
            self?.lastError = msg
            self?.append(.error, .analysis, "Failed: \(msg)")
        }

        observe("TaskAnalysisTimeout") { [weak self] notif in
            let msg = (notif.userInfo?["message"] as? String) ?? "Timeout"
            self?.append(.warning, .analysis, "Timeout: \(msg)")
        }

        observe("TaskDeleted") { [weak self] notif in
            if let taskId = notif.object as? String {
                self?.append(.warning, .system, "Task deleted: \(taskId.prefix(8))")
            }
        }

        observe("TaskSummaryAvailable") { [weak self] notif in
            guard let info = notif.userInfo,
                  let summary = info["summary"] as? String else { return }
            self?.append(.success, .analysis, "Summary: \(summary.prefix(50))…")
        }
    }
}

// MARK: - DateFormatter helper
private extension DateFormatter {
    func then(_ configure: (DateFormatter) -> Void) -> DateFormatter {
        configure(self); return self
    }
}
#endif
