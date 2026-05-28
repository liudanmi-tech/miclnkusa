//
//  ProfileListView.swift
//  WorkSurvivalGuide
//
//  档案列表视图 - 按照Figma设计稿实现
//

import SwiftUI

struct ProfileListView: View {
    @ObservedObject private var viewModel = ProfileViewModel.shared
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @State private var showingCreateProfile = false
    @State private var profileCountBeforeSheet = 0
    @State private var selectedProfile: Profile?
    @State private var showSettingsSheet = false
    @State private var showSubscription = false
    @AppStorage("contentFilterEnabled") private var contentFilterEnabled = true
    @State private var showEmojiTypePicker = false
    @State private var selfEmojiType: String = "self"
    @State private var showAIInfo = false
    @State private var showDeleteAccountConfirm = false
    @State private var isDeletingAccount = false
    
    var body: some View {
        ZStack {
            // 背景色已由 ContentView 提供
            
            VStack(spacing: 0) {
                // Header区域
                ProfileHeaderView(
                    onAddTap: {
                        profileCountBeforeSheet = viewModel.profiles.count
                        showingCreateProfile = true
                    },
                    onSettingsTap: { showSettingsSheet = true }
                )
                
                // 主内容区域
                if viewModel.isLoading && viewModel.profiles.isEmpty {
                    Spacer()
                    ProgressView("加载中...")
                        .tint(AppColors.headerText)
                    Spacer()
                } else if viewModel.profiles.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 52))
                            .foregroundColor(AppColors.secondaryText.opacity(0.5))
                        Text("还没有档案")
                            .font(AppFonts.cardTitle)
                            .foregroundColor(AppColors.primaryText)
                        Text("先创建一个档案\n记录你的工作对象背景信息")
                            .font(AppFonts.time)
                            .foregroundColor(AppColors.secondaryText)
                            .multilineTextAlignment(.center)
                        Button("创建第一个档案") {
                            profileCountBeforeSheet = viewModel.profiles.count
                            showingCreateProfile = true
                        }
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .frame(height: 40)
                            .background(Capsule().fill(Color.blue))
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(viewModel.profiles) { profile in
                            ProfileCardView(profile: profile, onTap: {
                                print("📋 [ProfileListView] 点击档案: \(profile.id)")
                                selectedProfile = profile
                            })
                                .id("\(profile.id)-\(profile.updatedAt.timeIntervalSince1970)")
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task {
                                            try? await viewModel.deleteProfile(profile.id)
                                            await MainActor.run {
                                                if selectedProfile?.id == profile.id {
                                                    selectedProfile = nil
                                                }
                                            }
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                        }
                        // 底部留白，避免被 tab bar 遮挡
                        Color.clear
                            .frame(height: 80)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .onAppear {
            // 只在数据为空且不在加载中时才加载
            if viewModel.profiles.isEmpty && !viewModel.isLoading {
                viewModel.loadProfiles()
            }
        }
        .sheet(isPresented: $showingCreateProfile, onDismiss: {
            // 引导第1步：只要点击了档案入口并返回到列表页，就推进到第2步
            if TourManager.shared.currentStep == .profileAddButton {
                TourManager.shared.advance()
            }
        }) {
            ProfileEditView(profile: nil)
        }
        .sheet(item: $selectedProfile) { profile in
            ProfileEditView(profile: profile)
        }
        .sheet(isPresented: $showSettingsSheet) {
            VStack(spacing: 24) {
                Text("Settings")
                    .font(AppFonts.cardTitle)
                    .foregroundColor(AppColors.primaryText)
                    .padding(.top, 24)

                // Pro 订阅入口（暂时隐藏，后续版本开放）

                // Content Filter 开关
                HStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundColor(Color(hex: "#34D399"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Content Filter")
                            .font(AppFonts.cardTitle)
                            .foregroundColor(AppColors.primaryText)
                        Text("Block sensitive AI-generated content")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(AppColors.secondaryText)
                    }
                    Spacer()
                    Toggle("", isOn: $contentFilterEnabled)
                        .labelsHidden()
                        .tint(Color(hex: "#34D399"))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.05))
                .cornerRadius(10)
                .padding(.horizontal, 24)

                // Emoji Style
                Button(action: {
                    selfEmojiType = ProfileViewModel.shared.selfEmojiType
                    // 先关闭 Settings sheet，再打开 emoji picker（SwiftUI 不支持叠加两个 sheet）
                    showSettingsSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showEmojiTypePicker = true
                    }
                }) {
                    HStack(spacing: 10) {
                        Text(viewModel.selfEmojiType == "dog" ? "🐶" : viewModel.selfEmojiType == "cat" ? "🐱" : "🪞")
                            .font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Emoji Style")
                                .font(AppFonts.cardTitle)
                                .foregroundColor(AppColors.primaryText)
                            Text(viewModel.selfEmojiType == "dog" ? "Dog" : viewModel.selfEmojiType == "cat" ? "Cat" : "Self Portrait")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(AppColors.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(AppColors.secondaryText)
                            .font(.system(size: 14))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)

                // Privacy Policy
                Link(destination: URL(string: "https://yohomie.art/privacy.html")!) {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundColor(AppColors.secondaryText)
                        Text("Privacy Policy")
                            .font(AppFonts.cardTitle)
                            .foregroundColor(AppColors.primaryText)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .foregroundColor(AppColors.secondaryText)
                            .font(.system(size: 14))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(10)
                }
                .padding(.horizontal, 24)

                // Terms of Service
                Link(destination: URL(string: "https://yohomie.art/terms.html")!) {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.fill")
                            .foregroundColor(AppColors.secondaryText)
                        Text("Terms of Service")
                            .font(AppFonts.cardTitle)
                            .foregroundColor(AppColors.primaryText)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .foregroundColor(AppColors.secondaryText)
                            .font(.system(size: 14))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(10)
                }
                .padding(.horizontal, 24)

                // About AI
                Button(action: { showAIInfo = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundColor(Color(hex: "#A78BFA"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("About AI Content")
                                .font(AppFonts.cardTitle)
                                .foregroundColor(AppColors.primaryText)
                            Text("Powered by Google Gemini")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(AppColors.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "info.circle")
                            .foregroundColor(AppColors.secondaryText)
                            .font(.system(size: 14))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .alert("About AI Content", isPresented: $showAIInfo) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Chattoon uses Google Gemini AI to generate images and insights from your recordings. AI-generated content is for personal reflection only and is not a substitute for professional advice.")
                }

                // Delete Account
                Button(action: { showDeleteAccountConfirm = true }) {
                    HStack(spacing: 8) {
                        if isDeletingAccount {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "#EF4444")))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 14))
                        }
                        Text(isDeletingAccount ? "Deleting…" : "Delete Account")
                            .font(AppFonts.cardTitle)
                    }
                    .foregroundColor(Color(hex: "#EF4444"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(hex: "#EF4444").opacity(0.12))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(isDeletingAccount)
                .padding(.horizontal, 24)
                .alert("Delete Account", isPresented: $showDeleteAccountConfirm) {
                    Button("Cancel", role: .cancel) { }
                    Button("Delete Permanently", role: .destructive) {
                        Task {
                            isDeletingAccount = true
                            do {
                                try await NetworkManager.shared.deleteAccount()
                                await MainActor.run {
                                    showSettingsSheet = false
                                    AuthManager.shared.logout()
                                }
                            } catch {
                                await MainActor.run { isDeletingAccount = false }
                            }
                        }
                    }
                } message: {
                    Text("This will permanently delete your account, all recordings, profiles, and data. This action cannot be undone.")
                }

                Button("Sign Out") {
                    showSettingsSheet = false
                    AuthManager.shared.logout()
                }
                .font(AppFonts.cardTitle)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(hex: "#EF4444"))
                .cornerRadius(8)
                .padding(.horizontal, 24)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.background)
        }
        .sheet(isPresented: $showSubscription) {
            SubscriptionView()
        }
        .sheet(isPresented: $showEmojiTypePicker, onDismiss: {
            // 立即写入本地（UserDefaults），不依赖 profiles 是否已加载
            ProfileViewModel.shared.setSelfEmojiType(selfEmojiType)
            // 再同步到服务端 Self 档案
            guard let selfProfile = ProfileViewModel.shared.profiles
                .first(where: { $0.relationship.lowercased() == "self" }),
                selfProfile.emojiType != selfEmojiType else { return }
            var updated = selfProfile
            updated.emojiType = selfEmojiType
            Task {
                try? await ProfileViewModel.shared.updateProfile(updated)
                await MainActor.run {
                    ProfileViewModel.shared.loadProfiles(forceRefresh: true)
                }
            }
        }) {
            EmojiTypePickerSheet(selectedEmojiType: $selfEmojiType)
        }
    }
}

// Header视图
struct ProfileHeaderView: View {
    let onAddTap: () -> Void
    var onSettingsTap: (() -> Void)? = nil
    
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // 左侧：标题
            Text("Profile")
                .font(.system(size: 24, weight: .black, design: .rounded)) // Nunito 900, 24px
                .foregroundColor(AppColors.headerText) // #5E4B35
                .tracking(0.6) // letterSpacing 2.5% of 24px = 0.6pt
            
            Spacer()
            
            // 右侧：设置按钮 + 添加按钮
            HStack(spacing: 8) {
                if let onSettingsTap = onSettingsTap {
                    Button(action: onSettingsTap) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.2))
                                .frame(width: 39.98, height: 39.98)
                            
                            Image(systemName: "gearshape")
                                .font(.system(size: 19.99, weight: .bold))
                                .foregroundColor(AppColors.headerText)
                        }
                    }
                }
                
                Button(action: onAddTap) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 39.98, height: 39.98)

                        Image(systemName: "plus")
                            .font(.system(size: 19.99, weight: .bold))
                            .foregroundColor(AppColors.headerText)
                    }
                }
                .tourHighlight(.profileAddButton)
            }
        }
        .padding(.horizontal, 23.990530014038086) // 根据Figma: padding horizontal 23.99px
        .padding(.vertical, 0)
        .frame(height: 87.97) // 根据Figma: height 87.97px
        .background(Color.black)
    }
}

// 档案卡片视图
struct ProfileCardView: View {
    let profile: Profile
    var onTap: (() -> Void)? = nil
    @ObservedObject private var audioPlayer = ProfileAudioPlayerService.shared
    @State private var showMemorySheet = false

    // 只有 audioUrl 是真实可播放的 http URL 时才显示播放键
    private var playableAudioUrl: String? {
        guard let url = profile.audioUrl, url.hasPrefix("http") else { return nil }
        return url
    }

    var body: some View {
        ZStack(alignment: .trailing) {

            // ── 层1（最底）：透明全卡片按钮 → 点击进编辑页 ──────────
            // 用透明 Color 做 hit area，避免 Button label 内容影响手势
            Button(action: { onTap?() }) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ── 层2（中间）：纯视觉内容，allowsHitTesting(false) 让点击穿透到层1/层3
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    avatarView(size: 64)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.name)
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .foregroundColor(AppColors.headerText)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.white)
                            Text(profile.relationship)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Capsule().fill(Color(white: 0.28)))
                    }

                    Spacer()

                    // 占位宽度：记忆按钮 36 + 间距 8 + 音频按钮 40 (可选) + padding 16
                    Color.clear.frame(width: 52, height: playableAudioUrl != nil ? 92 : 44)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                if let notes = profile.notes, !notes.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "note.text")
                            .font(.system(size: 15))
                            .foregroundColor(AppColors.headerText.opacity(0.6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Notes")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(AppColors.headerText.opacity(0.5))
                            Text(notes)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(AppColors.headerText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)   // 纯视觉层，所有点击穿透给层1或层3

            // ── 层3（最顶）：记忆按钮 + 播放键，ZStack 后声明 = hit-test 最优先 ──
            VStack(spacing: 8) {
                // 记忆按钮（始终显示）
                Button(action: { showMemorySheet = true }) {
                    ZStack {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(Color(.systemGray4), lineWidth: 0.5))
                        Image(systemName: "brain")
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.headerText.opacity(0.7))
                    }
                }
                .buttonStyle(.borderless)

                // 音频播放键（有音频时才显示）
                if playableAudioUrl != nil {
                    let isCurrent   = audioPlayer.currentPlayingProfileId == profile.id
                    let isBuffering = isCurrent && audioPlayer.isBuffering
                    let isPlaying   = isCurrent && audioPlayer.isPlaying

                    Button(action: { audioPlayer.togglePlayback(for: profile) }) {
                        ZStack {
                            Circle()
                                .fill(Color(.systemGray5))
                                .frame(width: 40, height: 40)
                                .overlay(Circle().stroke(Color(.systemGray4), lineWidth: 0.5))
                                .shadow(color: Color.black.opacity(0.08), radius: 1, x: 0, y: 1)

                            if isBuffering {
                                ProgressView()
                                    .progressViewStyle(
                                        CircularProgressViewStyle(tint: AppColors.headerText.opacity(0.7))
                                    )
                                    .scaleEffect(0.75)
                            } else {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 15))
                                    .foregroundColor(AppColors.headerText.opacity(0.75))
                                    .offset(x: isPlaying ? 0 : 1)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isBuffering)
                }
            }
            .padding(.trailing, 16)
        }
        .background(AppColors.cardBackground)
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
        .sheet(isPresented: $showMemorySheet) {
            ProfileMemoryView(profile: profile)
        }
    }

    @ViewBuilder
    private func avatarView(size: CGFloat) -> some View {
        if let photoUrl = profile.getAccessiblePhotoURL(baseURL: NetworkManager.shared.getBaseURL()),
           let url = URL(string: photoUrl) {
            RemoteImageView(url: url, width: size, height: size)
                .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 2)
        } else {
            Circle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundColor(AppColors.secondaryText)
                )
                .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 2)
        }
    }
    
}
