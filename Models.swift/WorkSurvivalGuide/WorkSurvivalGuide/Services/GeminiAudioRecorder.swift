//
//  GeminiAudioRecorder.swift
//  WorkSurvivalGuide
//
//  AVAudioRecorder 封装，录制 .m4a 音频文件。
//  输出原始 Data 用于直接 multipart 上传（无 base64 编码）。
//

import AVFoundation

class GeminiAudioRecorder: NSObject, ObservableObject {

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

    // MARK: - Public

    var isRecording: Bool { recorder?.isRecording ?? false }

    /// 开始录音，每次生成唯一文件名，避免覆盖上一条语音消息
    func startRecording() {
        let filename = "chat_voice_\(UUID().uuidString).m4a"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        currentURL = url

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("⚠️ [GeminiAudioRecorder] AVAudioSession setup failed: \(error)")
            return
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.record()
            print("🎙️ [GeminiAudioRecorder] recording started → \(url.lastPathComponent)")
        } catch {
            print("⚠️ [GeminiAudioRecorder] AVAudioRecorder init failed: \(error)")
        }
    }

    /// 停止录音，返回 (原始 Data, 文件 URL)。
    /// 文件 URL 用于本地回放；Data 用于上传 Gemini。
    /// 录音过短（< 0.5s）或文件为空时返回 nil。
    func stopRecording() -> (data: Data, fileURL: URL)? {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = currentURL,
              let data = try? Data(contentsOf: url),
              data.count > 1024 else {
            print("⚠️ [GeminiAudioRecorder] audio too short or empty, discarding")
            return nil
        }
        print("✅ [GeminiAudioRecorder] recording stopped | size=\(data.count) bytes | \(url.lastPathComponent)")
        return (data, url)
    }

    /// 取消录音，删除临时文件
    func cancelRecording() {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let url = currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentURL = nil
        print("🚫 [GeminiAudioRecorder] recording cancelled")
    }
}
