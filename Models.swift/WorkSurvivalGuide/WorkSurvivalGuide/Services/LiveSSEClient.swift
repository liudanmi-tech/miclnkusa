//
//  LiveSSEClient.swift
//  WorkSurvivalGuide
//
//  Live Mode SSE 事件订阅客户端
//
//  职责：
//    - 连接 GET /api/v1/live/sessions/{id}/events?token=JWT
//    - 解析 SSE 格式（id: / event: / data: / 空行分隔）
//    - 断线后携带 Last-Event-ID 自动重连（指数退避，最长 16s）
//    - 通过 @Published / 回调把事件分发给 LiveSessionViewModel
//
//  SSE 格式：
//    id: 1042
//    event: transcript
//    data: {"turn_index":5,"speaker":"user","text":"..."}
//
//    : ping
//
//  实现说明：
//    使用 URLSessionDataDelegate 代替 URLSession.bytes(for:) + AsyncBytes。
//    didReceive(data:) 每收到一块数据立即回调，无内部缓冲，解决 iOS HTTP/HTTPS 缓冲问题。
//

import Foundation
import Combine

// MARK: - SSE Event Models

struct LiveSSEEvent {
    let id: Int
    let type: String            // "transcript" | "suggestion" | "analysis_ready" | "segment_context" | "image_ready" | "session_end"
    let payload: [String: Any]
}

// MARK: - Internal SSE Message

private enum SSEMessage: Sendable {
    case httpStatus(Int)
    case text(String)
}

// MARK: - URLSessionDataDelegate Bridge

/// 将 URLSessionDataDelegate 回调桥接为 AsyncStream<SSEMessage>。
/// didReceive(data:) 每次收到数据块立即调用，无 URLSession 内部缓冲。
private final class SSEDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<SSEMessage>.Continuation
    private var lineBuffer: String = ""
    private var statusDelivered = false

    init(continuation: AsyncStream<SSEMessage>.Continuation) {
        self.continuation = continuation
    }

    // HTTP 响应头到达：先 yield 状态码
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        continuation.yield(.httpStatus(code))
        statusDelivered = true
        completionHandler(code == 200 ? .allow : .cancel)
    }

    // 每收到一块 body 立即调用（无缓冲）
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        lineBuffer += chunk
        // 按换行符切行，完整行立即 yield
        while let idx = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<idx])
            lineBuffer.removeSubrange(lineBuffer.startIndex...idx)
            continuation.yield(.text(line))
        }
    }

    // 连接结束（正常或错误）
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if !statusDelivered {
            continuation.yield(.httpStatus(0))
        }
        if !lineBuffer.isEmpty {
            continuation.yield(.text(lineBuffer))
            lineBuffer = ""
        }
        continuation.finish()
    }
}

// MARK: - LiveSSEClient

class LiveSSEClient: ObservableObject {

    static let shared = LiveSSEClient()

    // MARK: - Published 状态

    @Published var isConnected: Bool = false

    /// 快速建议事件缓存（直接 @Published，供 View 观察，避免 struct 值拷贝捕获失效）
    @Published var rawSuggestions:         [[String: Any]] = []
    /// 技能分析事件缓存
    @Published var rawSkillBatches:        [[String: Any]] = []
    /// Segment 摘要文本
    @Published var rawSegmentContext:      String          = ""
    /// 声纹识别确认事件（speaker_identified）
    @Published var rawSpeakerIdentified:   [[String: Any]] = []

    // MARK: - 事件回调（供 LiveSessionViewModel 绑定）

    var onTranscript:         (([String: Any]) -> Void)?
    var onSuggestion:         (([String: Any]) -> Void)?
    var onAnalysisReady:      (([String: Any]) -> Void)?
    var onSegmentContext:     (([String: Any]) -> Void)?
    var onImageReady:         (([String: Any]) -> Void)?
    var onSessionEnd:         (() -> Void)?
    var onSpeakerIdentified:  (([String: Any]) -> Void)?

    // MARK: - Private

    private var streamTask: Task<Void, Never>?
    private var lastEventId: Int = 0
    private var sessionId: String?
    private var token: String?
    private var reconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 16.0

    private init() {}

    // MARK: - 公共接口

    /// 开始订阅 SSE 事件流
    func connect(sessionId: String, token: String) {
        disconnect()    // 确保旧连接已清理
        self.sessionId = sessionId
        self.token = token
        self.lastEventId = 0
        self.reconnectDelay = 1.0
        // 重置事件缓存
        rawSuggestions         = []
        rawSkillBatches        = []
        rawSegmentContext      = ""
        rawSpeakerIdentified   = []
        startStream()
    }

    /// 停止订阅，清理资源
    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        DispatchQueue.main.async { self.isConnected = false }
    }

    // MARK: - 内部实现

    private func startStream() {
        guard let sessionId = sessionId, let token = token else { return }
        streamTask = Task { [weak self] in
            await self?.streamLoop(sessionId: sessionId, token: token)
        }
    }

    private func streamLoop(sessionId: String, token: String) async {
        let baseURL = AppConfig.shared.sseBaseURL

        guard let url = URL(
            string: "\(baseURL)/api/v1/live/sessions/\(sessionId)/events?token=\(token)"
        ) else {
            print("[SSE] URL 构建失败")
            return
        }

        while !Task.isCancelled {
            var request = URLRequest(url: url)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("keep-alive", forHTTPHeaderField: "Connection")
            request.timeoutInterval = 300   // SSE 长连接，5 分钟
            if lastEventId > 0 {
                request.setValue("\(lastEventId)", forHTTPHeaderField: "Last-Event-ID")
                print("[SSE] 重连，Last-Event-ID=\(lastEventId)")
            }

            // SSE 行解析状态（每次连接重置）
            var currentId: Int?
            var currentEvent = "message"
            var currentData  = ""
            var connectedLogged = false
            var statusCode = 0

            sseLoop:
            for await msg in makeSSEStream(request: request) {
                if Task.isCancelled { break }

                switch msg {
                case .httpStatus(let code):
                    statusCode = code
                    guard code == 200 else {
                        print("[SSE] 响应非 200: \(code)，\(reconnectDelay)s 后重连")
                        break sseLoop
                    }
                    DispatchQueue.main.async { self.isConnected = true }
                    resetBackoff()
                    connectedLogged = true
                    print("[SSE] ✅ HTTP 200 连接成功，开始解析流 session=\(sessionId.prefix(8))")
                    #if DEBUG || INTERNALTEST
                    DebugLogger.shared.setLiveSSEStatus("Connected ✓")
                    #endif

                case .text(let line):
                    // SSE 协议解析
                    if line.hasPrefix("id:") {
                        let rawId = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                        currentId = Int(rawId)

                    } else if line.hasPrefix("event:") {
                        currentEvent = String(line.dropFirst(6).trimmingCharacters(in: .whitespaces))

                    } else if line.hasPrefix("data:") {
                        currentData = String(line.dropFirst(5).trimmingCharacters(in: .whitespaces))

                    } else if line.hasPrefix(":") {
                        // SSE comment（心跳 ping），忽略

                    } else if line.isEmpty {
                        // 空行 = 事件分隔符，派发当前累积的事件
                        if !currentData.isEmpty {
                            let eventId = currentId ?? 0
                            if eventId > 0 { lastEventId = eventId }
                            print("[SSE] 🔔 准备派发 id=\(eventId) type=\(currentEvent)")
                            #if DEBUG || INTERNALTEST
                            DebugLogger.shared.incLiveSSERawEvent()
                            #endif
                            await dispatchEvent(id: eventId, type: currentEvent, dataStr: currentData)
                        }
                        // 重置，准备接收下一条
                        currentId    = nil
                        currentEvent = "message"
                        currentData  = ""
                    }
                }
            }

            if Task.isCancelled { return }

            // 流结束或非 200
            DispatchQueue.main.async { self.isConnected = false }
            if connectedLogged {
                print("[SSE] 流结束，\(reconnectDelay)s 后重连")
                #if DEBUG || INTERNALTEST
                DebugLogger.shared.setLiveSSEStatus("Reconnecting…")
                #endif
            }

            try? await Task.sleep(nanoseconds: sleepNs(reconnectDelay))
            backoff()
        }
    }

    /// 创建基于 URLSessionDataDelegate 的 SSE 消息流（无内部缓冲）
    private func makeSSEStream(request: URLRequest) -> AsyncStream<SSEMessage> {
        AsyncStream { continuation in
            let delegate = SSEDelegate(continuation: continuation)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    /// 把解析好的事件派发到对应回调
    private func dispatchEvent(id: Int, type: String, dataStr: String) async {
        guard let payloadData = dataStr.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            print("[SSE] payload JSON 解析失败: \(dataStr)")
            #if DEBUG || INTERNALTEST
            DebugLogger.shared.incLiveSSEParseError(dataSnippet: dataStr)
            #endif
            return
        }

        let event = LiveSSEEvent(id: id, type: type, payload: payload)
        print("[SSE] 收到事件 id=\(id) type=\(type) dataStr=\(dataStr.prefix(80))")

        await MainActor.run {
            switch event.type {
            case "transcript":
                self.onTranscript?(payload)
            case "suggestion":
                self.rawSuggestions.append(payload)
                print("[SSE] ✅ rawSuggestions count=\(self.rawSuggestions.count) text=\((payload["text"] as? String ?? "").prefix(30))")
                self.onSuggestion?(payload)
                #if DEBUG || INTERNALTEST
                DebugLogger.shared.setLiveSuggestionCount(self.rawSuggestions.count)
                #endif
            case "analysis_ready":
                self.rawSkillBatches.append(payload)
                self.onAnalysisReady?(payload)
                #if DEBUG || INTERNALTEST
                let skillCards = (payload["skill_cards"] as? [[String: Any]]) ?? []
                let names = skillCards.compactMap { $0["skill_name"] as? String }
                DebugLogger.shared.setLiveSkillMatch(count: skillCards.count, names: names)
                #endif
            case "segment_context":
                if let text = payload["text"] as? String, !text.isEmpty {
                    self.rawSegmentContext = text
                }
                self.onSegmentContext?(payload)
                #if DEBUG || INTERNALTEST
                DebugLogger.shared.setLiveSegmentCount(DebugLogger.shared.liveSegmentCount + 1)
                #endif
            case "image_ready":
                self.onImageReady?(payload)
                #if DEBUG || INTERNALTEST
                let imgUrl = (payload["image_url"] as? String) ?? (payload["url"] as? String) ?? ""
                DebugLogger.shared.setLiveImageStatus(imgUrl.isEmpty ? "Ready ✓" : "✓ \(imgUrl.suffix(30))")
                #endif
            case "speaker_identified":
                self.rawSpeakerIdentified.append(payload)
                self.onSpeakerIdentified?(payload)
            case "session_end":
                self.isConnected = false
                self.onSessionEnd?()
            default:
                break
            }
        }
    }

    // MARK: - 退避逻辑

    private func backoff() {
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
    }

    private func resetBackoff() {
        reconnectDelay = 1.0
    }

    private func sleepNs(_ seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000)
    }
}
