//
//  LiveSessionManager.swift
//  WorkSurvivalGuide
//
//  Live Mode 会话管理器
//  职责：
//    - HFP 眼镜检测（portType == .bluetoothHFP）
//    - AVAudioSession / AVAudioEngine 音频采集（16kHz Int16 mono）
//    - WebSocket 连接到后端代理（wss://.../audio-stream?token=JWT）
//    - 上行：PCM binary frames → 后端
//    - 下行：JSON transcript → @Published transcript
//
//  注：iOS → 后端 WebSocket → Gemini Live（后端代理架构，S-1）
//

import AVFoundation
import Combine
import Foundation
import UIKit

// MARK: - Models

enum LiveSessionState: Equatable {
    case idle
    case connecting    // WS 握手中
    case active        // WS 已连接，音频流发送中
    case ending        // 用户点击结束，等待后端响应
    case ended         // 录音已结束
    case error(String)
}

struct LiveTurnItem: Identifiable {
    let id = UUID()
    let turnIndex: Int
    let speakerLabel: String    // "Speaker_1" / "Speaker_2"
    let speaker: String         // "user" | "other"
    let text: String
    let timestampMs: Int
}

// MARK: - LiveSessionManager

class LiveSessionManager: NSObject, ObservableObject {

    static let shared = LiveSessionManager()

    // MARK: - Published 状态

    @Published var sessionState: LiveSessionState = .idle
    @Published var isGlassesAvailable: Bool = false
    @Published var transcript: [LiveTurnItem] = []
    @Published var elapsedSeconds: Int = 0

    // MARK: - Session 信息

    private(set) var sessionId: String?
    private var authToken: String?

    // MARK: - 事件回调（供 LiveSessionViewModel 使用）

    var onTranscript: ((LiveTurnItem) -> Void)?
    var onWSError: ((String) -> Void)?

    // MARK: - Private — WebSocket

    private var wsTask: URLSessionWebSocketTask?
    private var wsURLSession: URLSession?
    private var receiveTask: Task<Void, Never>?

    // MARK: - Private — 音频

    private var audioEngine: AVAudioEngine?
    /// PCM 缓冲区，累积到 chunkSize 再发送
    private var audioCaptureBuffer = Data()
    /// 约 100ms：16000 Hz × 0.1s × 2 bytes/sample = 3200 字节
    private let chunkSize = 3200

    // MARK: - Private — 计时器

    private var elapsedTimer: Timer?
    private var sessionStartTime: Date?

    // MARK: - Init

    private override init() {
        super.init()
        setupRouteChangeObserver()
        checkGlassesAvailability()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 眼镜检测

    /// 检测当前是否有 HFP 蓝牙输入（眼镜）在线
    func checkGlassesAvailability() {
        let hasHFP = AVAudioSession.sharedInstance()
            .availableInputs?
            .contains { $0.portType == .bluetoothHFP } ?? false
        DispatchQueue.main.async {
            self.isGlassesAvailable = hasHFP
        }
    }

    private func setupRouteChangeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        DispatchQueue.main.async { self.checkGlassesAvailability() }
    }

    // MARK: - 会话生命周期

    /// 开始 Live 录音
    /// - Parameters:
    ///   - sessionId: 后端 POST /live/sessions 返回的 session_id
    ///   - token: 当前 JWT token（WS 鉴权用 query param）
    func startSession(sessionId: String, token: String) {
        guard sessionState == .idle || sessionState == .ended else {
            print("[LiveSession] 已有活跃会话，忽略 startSession")
            return
        }

        self.sessionId = sessionId
        self.authToken = token
        self.transcript = []
        self.audioCaptureBuffer = Data()
        self.elapsedSeconds = 0
        self.sessionState = .connecting

        setupAudioSession()
        connectWebSocket(sessionId: sessionId, token: token)

        sessionStartTime = Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.sessionStartTime else { return }
            DispatchQueue.main.async {
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    /// 停止 Live 录音（用户点击结束后调用）
    func stopSession() {
        sessionState = .ending
        stopAudioCapture()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        receiveTask?.cancel()
        receiveTask = nil
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        wsURLSession?.invalidateAndCancel()
        wsURLSession = nil
        DispatchQueue.main.async { self.sessionState = .ended }
    }

    // MARK: - AVAudioSession 配置

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .voiceChat：内置软件降噪 + AEC
            // .allowBluetooth：启用 HFP 输入
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true)
            try session.setPreferredSampleRate(16000)

            // 优先选择 HFP 眼镜输入
            if let hfpInput = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try session.setPreferredInput(hfpInput)
                print("[LiveSession] HFP 输入已选定: \(hfpInput.portName)")
            } else {
                print("[LiveSession] 未检测到 HFP 设备，使用默认麦克风")
            }
        } catch {
            print("[LiveSession] AVAudioSession 配置失败: \(error)")
        }
    }

    // MARK: - AVAudioEngine 采集

    private func startAudioCapture() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // 目标格式：16kHz Int16 mono
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            print("[LiveSession] 无法创建目标音频格式")
            return
        }

        // 每次约 1600 帧 = 100ms @16kHz
        inputNode.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.convertAndEnqueue(buffer, from: inputFormat, to: targetFormat)
        }

        do {
            try engine.start()
            self.audioEngine = engine
            print("[LiveSession] AVAudioEngine 已启动，输入格式: \(inputFormat)")
        } catch {
            print("[LiveSession] AVAudioEngine 启动失败: \(error)")
        }
    }

    private func convertAndEnqueue(
        _ buffer: AVAudioPCMBuffer,
        from inputFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) {
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard convError == nil, let int16Ptr = outBuf.int16ChannelData else { return }

        let byteCount = Int(outBuf.frameLength) * 2
        let pcmData = Data(bytes: int16Ptr[0], count: byteCount)

        audioCaptureBuffer.append(pcmData)

        // 每攒够 chunkSize 就发一次（≈100ms）
        while audioCaptureBuffer.count >= chunkSize {
            let chunk = Data(audioCaptureBuffer.prefix(chunkSize))
            audioCaptureBuffer.removeFirst(chunkSize)
            sendBinaryChunk(chunk)
        }
    }

    private func stopAudioCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioCaptureBuffer = Data()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("[LiveSession] 音频采集已停止")
    }

    // MARK: - WebSocket

    private func connectWebSocket(sessionId: String, token: String) {
        let config = AppConfig.shared
        let wsBase = config.useTestServer
            ? "ws://34.74.255.48"
            : "wss://api.yohomie.art"

        guard let url = URL(
            string: "\(wsBase)/api/v1/live/sessions/\(sessionId)/audio-stream?token=\(token)"
        ) else {
            print("[LiveSession] WebSocket URL 构建失败")
            DispatchQueue.main.async { self.sessionState = .error("WebSocket URL 构建失败") }
            return
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        wsURLSession = session
        let task = session.webSocketTask(with: url)
        wsTask = task
        task.resume()
        // receiveTask 在 didOpenWithProtocol 中启动，确保握手完成后再 receive
        print("[LiveSession] WebSocket 连接中: \(url)")
    }

    private func sendBinaryChunk(_ data: Data) {
        guard let task = wsTask, sessionState == .active else { return }
        task.send(.data(data)) { error in
            if let error = error {
                print("[LiveSession] 发送音频帧失败: \(error)")
            }
        }
    }

    private func receiveLoop() async {
        guard let task = wsTask else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                if case .string(let text) = message {
                    handleDownstreamJSON(text)
                }
            } catch {
                if Task.isCancelled { return }
                print("[LiveSession] WS 接收错误: \(error)")
                break
            }
        }
    }

    /// 处理后端下行 JSON 消息（transcript / error / ping）
    private func handleDownstreamJSON(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        DispatchQueue.main.async {
            switch type {
            case "transcript":
                let turnIndex   = json["turn_index"]    as? Int    ?? self.transcript.count
                let speakerLabel = json["speaker_label"] as? String ?? "Speaker_1"
                let speaker     = speakerLabel == "Speaker_1" ? "user" : "other"
                let turnText    = json["text"]           as? String ?? ""
                let tsMs        = json["timestamp_ms"]   as? Int    ?? 0

                let item = LiveTurnItem(
                    turnIndex: turnIndex,
                    speakerLabel: speakerLabel,
                    speaker: speaker,
                    text: turnText,
                    timestampMs: tsMs
                )
                self.transcript.append(item)
                self.onTranscript?(item)

            case "error":
                let msg = json["message"] as? String ?? "Gemini 连接失败"
                self.sessionState = .error(msg)
                self.onWSError?(msg)

            case "ping":
                break   // 心跳，忽略

            default:
                break
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension LiveSessionManager: URLSessionWebSocketDelegate {

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        print("[LiveSession] WebSocket 握手成功")
        DispatchQueue.main.async {
            self.sessionState = .active
            // 握手完成后才启动接收循环，避免 Code=57（Socket is not connected）
            self.receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
            // WS 连接成功后才开始采集音频
            self.startAudioCapture()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        print("[LiveSession] WebSocket 关闭 code=\(closeCode.rawValue) reason=\(reasonStr)")
        DispatchQueue.main.async {
            // 若不是主动 ending，标记为 error
            if self.sessionState == .active {
                self.sessionState = .error("连接断开（code \(closeCode.rawValue)）")
                self.stopAudioCapture()
            }
        }
    }
}
