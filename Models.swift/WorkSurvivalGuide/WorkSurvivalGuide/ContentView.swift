//
//  ContentView.swift
//  WorkSurvivalGuide
//
//  主视图 - 按照Figma设计稿实现
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var authManager = AuthManager.shared
    @State private var selectedTab: TabItem = .fragments
    @StateObject private var recordingViewModel = RecordingViewModel()
    @State private var showFilePicker = false
    @State private var showTextInput = false
    @State private var showSubscriptionStatus = false
    @AppStorage("onboarding_completed") private var onboardingCompleted = false
    @AppStorage("hasAcceptedTerms") private var hasAcceptedTerms = false
    @AppStorage("hasShownRatingPrompt") private var hasShownRatingPrompt = false
    @State private var showRatingPrompt = false

    var body: some View {
        Group {
            if authManager.isLoggedIn {
                NavigationStack {
                    ZStack {
                        // 背景色（底层）
                        AppColors.background
                            .ignoresSafeArea()
                        
                        // 信纸网格底纹（在背景色上方，但不覆盖底部导航栏）
                        PaperGridBackground()
                            .ignoresSafeArea()
                        
                        VStack(spacing: 0) {
                            // 主内容区域
                            ZStack {
                                // 根据选中的Tab显示不同内容
                                Group {
                                    switch selectedTab {
                                    case .fragments:
                                        TaskListView()
                                    case .skills:
                                        SkillsView()
                                    case .profile:
                                        ProfileListView()
                                    }
                                }
                                
                                // 录音按钮 + 本地上传按钮（只在碎片页面显示）
                                if selectedTab == .fragments {
                                    VStack {
                                        Spacer()
                                        HStack {
                                            Spacer()
                                            RecordingButtonView(
                                                viewModel: recordingViewModel,
                                                onUploadTap: { showFilePicker = true },
                                                onTextInputTap: { showTextInput = true }
                                            )
                                            .padding(.trailing, 0)
                                            .padding(.bottom, 100) // 位于底部导航栏上方
                                        }
                                    }
                                }
                                
                                // 进度已移至卡片内显示，不再使用悬浮层
                            }
                        }
                        
                        // 底部导航栏（最顶层，不被网格覆盖）
                        VStack {
                            Spacer()
                            BottomNavView(selectedTab: $selectedTab)
                        }

                        // 新手引导聚光灯层
                        TourOverlayView()
                            .zIndex(9998)

                        // DEV 环境标识（仅 Dev Scheme 可见，Release 包不编译）
                        #if LIVE_MODE_ENABLED
                        DevBadgeOverlay()
                            .zIndex(9999)
                        #endif

                        // Debug 悬浮面板（仅 DEBUG 构建）
                        #if DEBUG || INTERNALTEST
                        DebugPanelView()
                            .zIndex(9997)
                        #endif
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationBarHidden(true)
                }
                .fullScreenCover(isPresented: .constant(hasAcceptedTerms && !onboardingCompleted)) {
                    OnboardingView()
                }
                .onChange(of: onboardingCompleted) { completed in
                    if completed {
                        selectedTab = .profile
                        TourManager.shared.startMainTour()
                    }
                }
                .onChange(of: selectedTab) { tab in
                    if tab == .fragments && TourManager.shared.currentStep == .momentsTab {
                        TourManager.shared.advance()
                    }
                }
            } else {
                LoginView()
            }
        }
        .onAppear {
            authManager.checkLoginStatus()
            // AuthManager.init() 已在启动时同步设置 isLoggedIn，onChange 不会触发
            // 所以在 onAppear 里直接判断
            if authManager.isLoggedIn && !TourManager.shared.mainTourCompleted {
                selectedTab = .profile
                TourManager.shared.startMainTour()
            }
            // 登录后重新触发 APNs token 注册（确保 auth token 已就位时上传 device token）
            if authManager.isLoggedIn {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        .onChange(of: authManager.isLoggedIn) { isLoggedIn in
            // 处理从 LoginView 刚登录完成的情况
            if isLoggedIn && !TourManager.shared.mainTourCompleted {
                selectedTab = .profile
                // 仅当 onboarding 已完成时才启动 tour；否则由 onChange(of: onboardingCompleted) 启动
                // 避免 onboarding 未完成时 currentStep 被提前设为 .profileAddButton，
                // 导致 onboarding 完成后再次 startMainTour() 时 onChange 不触发（值未变）→ 引导延迟 3-5 秒
                if onboardingCompleted {
                    TourManager.shared.startMainTour()
                }
            }
            // 登录后触发 APNs token 注册（此时 auth token 已写入 Keychain）
            if isLoggedIn {
                UIApplication.shared.registerForRemoteNotifications()
                // 如果 AppDelegate 已缓存了 token（解决时序问题），直接上传
                if let token = UserDefaults.standard.string(forKey: "pending_apns_token") {
                    print("✅ [Push] Uploading pending token after login: \(token.prefix(20))...")
                    Task { try? await NetworkManager.shared.registerDeviceToken(token) }
                    UserDefaults.standard.removeObject(forKey: "pending_apns_token")
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    recordingViewModel.uploadLocalFile(fileURL: url)
                }
            case .failure(let error):
                print("❌ [ContentView] 选择文件失败: \(error)")
            }
        }
        .sheet(isPresented: $showTextInput) {
            TextInputView()
        }
        .fullScreenCover(isPresented: Binding(
            get: { recordingViewModel.chatSessionId != nil },
            set: { if !$0 { recordingViewModel.chatSessionId = nil } }
        )) {
            if let sessionId = recordingViewModel.chatSessionId {
                ChatAIAssistantView(sessionId: sessionId)
            }
        }
        .sheet(isPresented: $recordingViewModel.showPaywall, onDismiss: {
            if SubscriptionManager.shared.isPro {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showSubscriptionStatus = true
                }
            }
        }) {
            SubscriptionView()
        }
        .sheet(isPresented: $showSubscriptionStatus) {
            SubscriptionStatusView()
        }
        .alert("Monthly Limit Reached", isPresented: $recordingViewModel.showProLimitAlert) {
            Button("OK", role: .cancel) { recordingViewModel.showProLimitAlert = false }
        } message: {
            Text("You've used all 30 recordings this month. Your quota resets on the 1st of next month. Thanks for being a Pro member!")
        }
        .alert("Upload Failed", isPresented: Binding(
            get: { recordingViewModel.uploadError != nil },
            set: { if !$0 { recordingViewModel.uploadError = nil } }
        )) {
            Button("OK", role: .cancel) {
                recordingViewModel.uploadError = nil
            }
        } message: {
            Text(recordingViewModel.uploadError ?? "")
        }
        // ── Push 通知点击路由（App 在前/后台时）──────────────────────────────
        .onReceive(NotificationCenter.default.publisher(for:
            NSNotification.Name("PushNotificationTapped"))) { _ in
            guard authManager.isLoggedIn else { return }
            recordingViewModel.createChatSession()
        }
        // ── 冷启动路由（App 被杀后点通知重新启动）────────────────────────────
        .onAppear {
            if let delegate = UIApplication.shared.delegate as? AppDelegate,
               delegate.pendingPushAction != nil,
               authManager.isLoggedIn {
                delegate.pendingPushAction = nil
                recordingViewModel.createChatSession()
            }
        }
        // ── 首次 AI Chat 退出后评价弹窗 ──────────────────────────────────────
        .onReceive(NotificationCenter.default.publisher(for:
            NSNotification.Name("ChatSessionClosed"))) { _ in
            guard !hasShownRatingPrompt else { return }
            hasShownRatingPrompt = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showRatingPrompt = true
                }
            }
        }
        .overlay {
            if showRatingPrompt {
                RatingPromptView {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showRatingPrompt = false
                    }
                }
                .zIndex(9000)
            }
        }
    }
}

// 状态视图（占位）
struct StatusView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("状态")
                .font(AppFonts.cardTitle)
                .foregroundColor(AppColors.primaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background)
    }
}

// 我的视图（占位）
struct MineView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("我的")
                .font(AppFonts.cardTitle)
                .foregroundColor(AppColors.primaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background)
    }
}

#Preview {
    ContentView()
}
