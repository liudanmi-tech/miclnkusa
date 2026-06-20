//
//  ProfileViewModel.swift
//  WorkSurvivalGuide
//
//  档案列表 ViewModel
//

import Foundation
import Combine

class ProfileViewModel: ObservableObject {
    static let shared = ProfileViewModel()

    @Published var profiles: [Profile] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// 用户选择的 emoji 风格，UserDefaults 持久化，立即可用无需等待 profiles 加载
    @Published var selfEmojiType: String = UserDefaults.standard.string(forKey: "selectedEmojiStyle") ?? "self"

    private let networkManager = NetworkManager.shared
    private var hasLoaded = false
    private var loadingTask: Task<Void, Never>?

    private init() {}

    /// 立即将 emoji 类型写入内存 + UserDefaults（用于 picker 选择后同步）
    func setSelfEmojiType(_ type: String) {
        selfEmojiType = type
        UserDefaults.standard.set(type, forKey: "selectedEmojiStyle")
    }

    /// 从已加载的 profiles 同步 selfEmojiType（server 优先）
    private func syncEmojiTypeFromProfiles(_ profiles: [Profile]) {
        guard let selfProfile = profiles.first(where: { $0.relationship.lowercased() == "self" }) else { return }
        if selfProfile.emojiType != selfEmojiType {
            selfEmojiType = selfProfile.emojiType
            UserDefaults.standard.set(selfProfile.emojiType, forKey: "selectedEmojiStyle")
        }
    }
    
    // 加载档案列表
    func loadProfiles(forceRefresh: Bool = false) {
        // 如果已经有数据且不在加载中，且不是强制刷新，则跳过
        if !forceRefresh && !profiles.isEmpty && !isLoading && hasLoaded {
            print("✅ [ProfileViewModel] 数据已存在，跳过加载")
            return
        }
        
        // 如果正在加载中，取消之前的任务
        if isLoading {
            print("⚠️ [ProfileViewModel] 正在加载中，跳过重复请求")
            loadingTask?.cancel()
        }
        
        isLoading = true
        errorMessage = nil
        
        loadingTask = Task {
            do {
                let response = try await networkManager.getProfilesList()
                
                guard !Task.isCancelled else {
                    print("⚠️ [ProfileViewModel] 加载任务已取消")
                    return
                }
                
                await MainActor.run {
                    self.profiles = response.profiles
                    self.isLoading = false
                    self.hasLoaded = true
                    self.syncEmojiTypeFromProfiles(response.profiles)
                    print("✅ [ProfileViewModel] 成功加载 \(response.profiles.count) 个档案")
                }
            } catch {
                guard !Task.isCancelled else {
                    print("⚠️ [ProfileViewModel] 加载任务已取消")
                    return
                }
                
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    print("❌ [ProfileViewModel] 加载档案失败: \(error)")
                }
            }
        }
    }
    
    // 创建档案
    func createProfile(_ profile: Profile) async throws {
        let createdProfile = try await networkManager.createProfile(profile)
        await MainActor.run {
            self.profiles.append(createdProfile)
        }
    }
    
    // 更新档案
    func updateProfile(_ profile: Profile) async throws {
        let updatedProfile = try await networkManager.updateProfile(profile)
        await MainActor.run {
            if let index = self.profiles.firstIndex(where: { $0.id == updatedProfile.id }) {
                self.profiles[index] = updatedProfile
            }
        }
    }
    
    // 删除档案
    func deleteProfile(_ profileId: String) async throws {
        try await networkManager.deleteProfile(profileId)
        await MainActor.run {
            self.profiles.removeAll { $0.id == profileId }
        }
    }

    func reset() {
        loadingTask?.cancel()
        profiles = []
        hasLoaded = false
        isLoading = false
        errorMessage = nil
    }
}

// MARK: - Self Emoji URL Cache
// Shared cache for user's 5 self-portrait emotion avatars (slot → presigned URL).
// Call load() once; result is reused across MoodTrend, DetailPage, EmojiPicker.

@MainActor
class SelfEmojiURLCache: ObservableObject {
    static let shared = SelfEmojiURLCache()
    @Published var urls: [String: String] = [:]   // slot → presigned URL (non-nil only)
    private var loaded = false
    private var loading = false   // 防止并发重复请求

    private init() {}

    func load() async {
        guard !loaded && !loading else { return }
        loading = true
        if let fetched = try? await NetworkManager.shared.fetchEmotionAvatarUrls() {
            urls = fetched.compactMapValues { $0 }
        }
        loaded = true
        loading = false
    }

    func url(for slot: String) -> String? { urls[slot] }

    func reset() {
        urls = [:]
        loaded = false
        // loading 不清：进行中的请求自然完成后置 false
    }
}
