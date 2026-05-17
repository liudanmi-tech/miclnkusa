//
//  ProfileAudioPlayerService.swift
//  WorkSurvivalGuide
//
//  档案卡片音频播放服务
//  逻辑与 SessionAudioPlayerService 对齐：
//  · 首次点击 → 加载（isBuffering=true）→ 播放
//  · 再次点击 → 暂停；再点 → 从暂停位置继续
//  · 播完后 seek(to:.zero)，下次点击从头播
//  · 切换其他档案时自动停止当前播放

import AVFoundation
import Foundation

@MainActor
final class ProfileAudioPlayerService: ObservableObject {
    static let shared = ProfileAudioPlayerService()

    @Published private(set) var currentPlayingProfileId: String?
    @Published private(set) var isPlaying = false
    /// true = AVPlayer 正在缓冲，按钮显示 ProgressView
    @Published private(set) var isBuffering = false

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var itemStatusObserver: NSKeyValueObservation?
    /// 记录当前播放的 OSS audio_url，用于检测音频是否被替换
    private var currentAudioUrl: String?

    private init() {}

    // MARK: - Public

    func togglePlayback(for profile: Profile) {
        // 仅判断档案是否有音频，不直接使用 OSS URL（私有 bucket 403）
        guard profile.audioUrl != nil else { return }

        // 通过后端代理 URL 播放，服务器用 OSS 凭证取文件再返回
        // getBaseURL() 已含 /api/v1，故不再重复加
        let base = NetworkManager.shared.getBaseURL()
        let proxyUrl = "\(base)/profiles/\(profile.id)/audio"

        let audioChanged = currentAudioUrl != profile.audioUrl

        if currentPlayingProfileId == profile.id && !audioChanged {
            // 同一档案且音频未变：暂停/继续
            if isPlaying {
                player?.pause()
                isPlaying = false
            } else {
                if let p = player {
                    p.play()
                    isPlaying = true
                } else {
                    startPlayer(urlString: proxyUrl, profileId: profile.id, audioUrl: profile.audioUrl ?? currentAudioUrl)
                }
            }
        } else {
            // 不同档案，或音频已被替换：重新加载
            stop()
            startPlayer(urlString: proxyUrl, profileId: profile.id, audioUrl: profile.audioUrl)
        }
    }

    func stop() {
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        isBuffering = false
        currentPlayingProfileId = nil
        currentAudioUrl = nil
    }

    // MARK: - Private

    private func startPlayer(urlString: String, profileId: String, audioUrl: String?) {
        guard let url = URL(string: urlString) else { return }

        // 附加 JWT token（与 SessionAudioPlayerService 相同）
        let token = KeychainManager.shared.getToken() ?? ""
        var options: [String: Any] = [:]
        if !token.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(token)"]
        }

        print("🎵 [ProfileAudio] 开始播放 URL: \(urlString)")

        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)

        player = newPlayer
        currentPlayingProfileId = profileId
        currentAudioUrl = audioUrl
        isPlaying = true
        isBuffering = true

        // 监听 AVPlayerItem.status → 捕获加载错误
        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] playerItem, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch playerItem.status {
                case .failed:
                    let err = playerItem.error?.localizedDescription ?? "unknown"
                    print("❌ [ProfileAudio] 播放失败: \(err)")
                    print("❌ [ProfileAudio] URL was: \(urlString)")
                    self.isBuffering = false
                    self.isPlaying = false
                case .readyToPlay:
                    print("✅ [ProfileAudio] readyToPlay")
                default:
                    break
                }
            }
        }

        // 监听缓冲状态
        statusObserver = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch p.timeControlStatus {
                case .waitingToPlayAtSpecifiedRate:
                    self.isBuffering = true
                    if let reason = p.reasonForWaitingToPlay {
                        print("⏳ [ProfileAudio] waiting reason: \(reason.rawValue)")
                    }
                case .playing:                      self.isBuffering = false
                case .paused:                       self.isBuffering = false
                @unknown default:                   self.isBuffering = false
                }
            }
        }

        // 配置 AVAudioSession 为播放模式
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        newPlayer.play()

        // 播完后归零，保留 player 实例以便下次从头播
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.isBuffering = false
                self?.player?.seek(to: .zero)   // 归零，不清空 player
            }
        }
    }
}
