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
//  需要 iOS 15+（URLSession.bytes）
//

import Foundation
import Combine

// MARK: - SSE Event Models

struct LiveSSEEvent {
    let id: Int
    let type: String            // "transcript" | "suggestion" | "analysis_ready" | "segment_context" | "image_ready" | "session_end"
    let payload: [String: Any]
}

// MARK: - LiveSSEClient

class LiveSSEClient: ObservableObject {

    static let shared = LiveSSEClient()

    // MARK: - Published 状态

    @Published var isConnected: Bool = false

    // MARK: - 事件回调（供 LiveSessionViewModel 绑定）

    var onTranscript:      (([String: Any]) -> Void)?
    var onSuggestion:      (([String: Any]) -> Void)?
    var onAnalysisReady:   (([String: Any]) -> Void)?
    var onSegmentContext:  (([String: Any]) -> Void)?
    var onImageReady:      (([String: Any]) -> Void)?
    var onSessionEnd:      (() -> Void)?

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
        let config = AppConfig.shared
        let baseURL = config.useTestServer
            ? "http://34.74.255.48"
            : "https://api.yohomie.art"

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
            // H-1 断线重连：携带上次收到的最大 event id
            if lastEventId > 0 {
                request.setValue("\(lastEventId)", forHTTPHeaderField: "Last-Event-ID")
                print("[SSE] 重连，Last-Event-ID=\(lastEventId)")
            }

            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                guard let httpResp = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }

                guard httpResp.statusCode == 200 else {
                    print("[SSE] 响应非 200: \(httpResp.statusCode)，\(reconnectDelay)s 后重连")
                    try? await Task.sleep(nanoseconds: sleepNs(reconnectDelay))
                    backoff()
                    continue
                }

                DispatchQueue.main.async { self.isConnected = true }
                resetBackoff()

                // 解析 SSE 行流
                await parseSSELines(bytes)

                // 流结束（服务端正常关闭）
                DispatchQueue.main.async { self.isConnected = false }
                print("[SSE] 流结束，\(reconnectDelay)s 后重连")

            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                DispatchQueue.main.async { self.isConnected = false }
                print("[SSE] 连接错误: \(error)，\(reconnectDelay)s 后重连")
            }

            try? await Task.sleep(nanoseconds: sleepNs(reconnectDelay))
            backoff()
        }
    }

    /// 逐行解析 SSE 流，一次完整事件（空行结束）后派发
    private func parseSSELines(_ bytes: URLSession.AsyncBytes) async {
        var currentId: Int?
        var currentEvent: String = "message"
        var currentData: String = ""

        do {
            for try await line in bytes.lines {
                if Task.isCancelled { return }

                if line.hasPrefix("id:") {
                    let rawId = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    currentId = Int(rawId)

                } else if line.hasPrefix("event:") {
                    currentEvent = String(line.dropFirst(6).trimmingCharacters(in: .whitespaces))

                } else if line.hasPrefix("data:") {
                    currentData = String(line.dropFirst(5).trimmingCharacters(in: .whitespaces))

                } else if line.hasPrefix(":") {
                    // SSE comment（心跳 ping），忽略，不更新 lastEventId

                } else if line.isEmpty {
                    // 空行 = 事件分隔符，派发当前累积的事件
                    if !currentData.isEmpty {
                        let eventId = currentId ?? 0
                        if eventId > 0 { lastEventId = eventId }
                        await dispatchEvent(id: eventId, type: currentEvent, dataStr: currentData)
                    }
                    // 重置状态，准备接收下一条
                    currentId = nil
                    currentEvent = "message"
                    currentData = ""
                }
            }
        } catch {
            if !Task.isCancelled {
                print("[SSE] 解析流错误: \(error)")
            }
        }
    }

    /// 把解析好的事件派发到对应回调
    private func dispatchEvent(id: Int, type: String, dataStr: String) async {
        guard let payloadData = dataStr.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            print("[SSE] payload JSON 解析失败: \(dataStr)")
            return
        }

        let event = LiveSSEEvent(id: id, type: type, payload: payload)
        print("[SSE] 收到事件 id=\(id) type=\(type)")

        await MainActor.run {
            switch event.type {
            case "transcript":
                self.onTranscript?(payload)
            case "suggestion":
                self.onSuggestion?(payload)
            case "analysis_ready":
                self.onAnalysisReady?(payload)
            case "segment_context":
                self.onSegmentContext?(payload)
            case "image_ready":
                self.onImageReady?(payload)
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
