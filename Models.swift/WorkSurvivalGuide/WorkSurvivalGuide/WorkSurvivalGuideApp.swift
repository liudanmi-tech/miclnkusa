//
//  WorkSurvivalGuideApp.swift
//  WorkSurvivalGuide
//
//  Created by liudan on 2026/1/8.
//

import SwiftUI
import TikTokBusinessSDK
import KochavaNetworking
import KochavaMeasurement
import KochavaTracking
import AppTrackingTransparency
import UserNotifications
import GoogleSignIn

// MARK: - Push 异步辅助函数（文件级，避免在类方法上下文触发 Swift 并发类型推导 bug）

fileprivate func pushUploadToken(_ token: String) async {
    try? await NetworkManager.shared.registerDeviceToken(token)
}

fileprivate func pushTrackOpen(_ id: Int) async {
    try? await NetworkManager.shared.trackNotificationOpened(id: id)
}

// MARK: - AppDelegate（Push 通知 + 冷启动路由）

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// 冷启动时（App 被杀后用户点通知）暂存动作，等 ContentView 加载后处理
    var pendingPushAction: String? = nil

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: "180700562709-ii6cnrfpafp3n34cirpg72gp4m4dh814.apps.googleusercontent.com"
        )
        return true
    }

    // Google Sign In OAuth 回调
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }

    // APNs 返回 device token → 上传服务端
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("✅ [Push] Got device token: \(token.prefix(20))...")
        // 暂存 token，供登录后上传
        UserDefaults.standard.set(token, forKey: "pending_apns_token")
        _Concurrency.Task { await pushUploadToken(token) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("⚠️ [Push] Failed to register: \(error)")
    }

    // 用户点击通知（App 在前台或后台）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let nid  = info["notification_log_id"] as? Int
        let action = info["action"] as? String ?? "open_chat"
        if let notifId = nid {
            _Concurrency.Task { await pushTrackOpen(notifId) }
        }
        DispatchQueue.main.async { [weak self] in
            self?.pendingPushAction = action
            NotificationCenter.default.post(name: NSNotification.Name("PushNotificationTapped"), object: nil)
        }
        completionHandler()
    }

    // App 在前台时收到通知 → 静默不弹 banner
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}

// MARK: - App Entry Point

@main
struct WorkSurvivalGuideApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // TikTok Business SDK initialization
        // ATT 弹窗由 SplashCoordinator 在 scenePhase=.active 时统一发起
        if let tikTokConfig = TikTokConfig(
            accessToken: "TTcCUI8nZ5aMr3uLCVKXRVDluc5nX4Rc",
            appId: "6766467422",
            tiktokAppId: "7653662064061202452"
        ) {
            #if DEBUG
            tikTokConfig.debugModeEnabled = true
            #endif
            TikTokBusiness.initializeSdk(tikTokConfig)
        }

        // Kochava MMP initialization
        // enabledBool = true：让 Kochava 读取 ATT 授权状态（不自己弹窗）
        // authorizationStatusWaitTimeInterval = 60s：等待 SplashCoordinator 弹完 ATT 弹窗后再读取结果
        // 流程：SplashCoordinator 在 scenePhase=.active 时触发系统 ATT 弹窗
        //       Kochava 等 60 秒，届时 ATT 已由用户决定，Kochava 读到 authorized 后带 IDFA 走正常端点
        Measurement.shared.appTrackingTransparency.enabledBool = true
        #if DEBUG
        Measurement.shared.appTrackingTransparency.authorizationStatusWaitTimeInterval = 5.0  // 调试用，正式改回 60
        #else
        Measurement.shared.appTrackingTransparency.authorizationStatusWaitTimeInterval = 60.0
        #endif
        Measurement.shared.start(appGUIDString: "kochattoon-1ndn6cc95")

        _Concurrency.Task { await ImageStyleRepository.shared.fetchIfNeeded() }
    }

    var body: some Scene {
        WindowGroup {
            SplashCoordinator()
        }
    }
}

/// ZStack 叠加：ContentView 立即在后台初始化，开屏图覆盖其上；
/// 首次启动 splash 结束后若未同意条款则弹出条款确认页
struct SplashCoordinator: View {
    @State private var showSplash = true
    @AppStorage("hasAcceptedTerms") private var hasAcceptedTerms = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var attRequested = false
    @State private var forceUpdateNeeded = false

    var body: some View {
        ZStack {
            ContentView()
            if showSplash {
                SplashScreenView(onFinish: {
                    showSplash = false
                    _Concurrency.Task {
                        let needsUpdate = await NetworkManager.shared.checkAppVersion()
                        await MainActor.run { forceUpdateNeeded = needsUpdate }
                    }
                })
            } else if forceUpdateNeeded {
                ForceUpdateView()
            } else if !hasAcceptedTerms {
                TermsAgreementView(onAccept: { hasAcceptedTerms = true })
            }
        }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .active else { return }
            // 清除 App 角标
            UIApplication.shared.applicationIconBadgeNumber = 0
            // ATT（只请求一次）
            guard !attRequested else { return }
            attRequested = true
            ATTrackingManager.requestTrackingAuthorization { _ in }
            // Push 权限（只请求一次，ATT 之后请求可提升通过率）
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                if granted {
                    DispatchQueue.main.async {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            }
        }
    }
}

struct SplashScreenView: View {
    let onFinish: () -> Void

    private var splashImage: UIImage? {
        if let img = UIImage(named: "LaunchImage") { return img }
        if let img = UIImage(named: "kaiping2") { return img }
        if let path = Bundle.main.path(forResource: "kaiping2", ofType: "png"),
           let img = UIImage(contentsOfFile: path) { return img }
        return nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let img = splashImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                onFinish()  // 直接消失，无动画
            }
        }
    }
}

// MARK: - Terms of Service Agreement（首次启动强制确认，不可跳过）
struct TermsAgreementView: View {
    let onAccept: () -> Void

    @State private var agreed = false
    @State private var pressed = false

    private let termsURL = URL(string: "https://yohomie.art/terms.html")!

    private let prohibitions: [(String, String)] = [
        ("nosign",          "No sexually explicit or adult content"),
        ("exclamationmark.shield", "No violent, threatening, or hateful content"),
        ("lock.shield",     "No infringement of privacy or intellectual property"),
        ("person.crop.circle.badge.xmark", "No recording without all-party consent"),
    ]

    var body: some View {
        ZStack {
            // 半透明遮罩（不可点穿）
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── 底部卡片 ─────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 0) {

                    // 拖拽条（装饰，不可拖动关闭）
                    HStack {
                        Spacer()
                        Capsule()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 36, height: 4)
                        Spacer()
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 20)

                    // 标题
                    Text("Before You Begin")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)

                    Text("Chattoon uses AI to analyze conversations and generate content. Please confirm you agree to the following:")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .lineSpacing(4)
                        .padding(.horizontal, 24)
                        .padding(.top, 10)
                        .padding(.bottom, 20)

                    // 禁止行为列表
                    VStack(spacing: 2) {
                        ForEach(prohibitions, id: \.1) { icon, text in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: icon)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Color(hex: "#F87171"))
                                    .frame(width: 20, alignment: .center)
                                    .padding(.top, 1)
                                Text(text)
                                    .font(.system(size: 14, design: .rounded))
                                    .foregroundColor(.white.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(8)
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 20)

                    // 查看完整条款链接
                    HStack {
                        Spacer()
                        Link(destination: termsURL) {
                            HStack(spacing: 4) {
                                Text("Read full Terms of Use")
                                    .font(.system(size: 13, design: .rounded))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(Color(hex: "#60A5FA"))
                        }
                        Spacer()
                    }
                    .padding(.bottom, 20)

                    // 勾选同意
                    Button {
                        agreed.toggle()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(agreed ? Color(hex: "#34D399") : Color.white.opacity(0.35), lineWidth: 1.5)
                                    .frame(width: 20, height: 20)
                                if agreed {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(Color(hex: "#34D399"))
                                }
                            }
                            Text("I have read and agree to the Chattoon AI Terms of Use, and will not use this app to generate prohibited content.")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundColor(.white.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(agreed ? 0.07 : 0.03))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    .animation(.easeInOut(duration: 0.15), value: agreed)

                    // I Agree 按钮
                    Button {
                        guard agreed else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { onAccept() }
                    } label: {
                        Text("I Agree — Continue")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundColor(agreed ? .black : .white.opacity(0.3))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                agreed
                                    ? Color(hex: "#34D399")
                                    : Color.white.opacity(0.08)
                            )
                            .cornerRadius(14)
                    }
                    .disabled(!agreed)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                    .animation(.easeInOut(duration: 0.2), value: agreed)
                }
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(hex: "#111111"))
                        .ignoresSafeArea(edges: .bottom)
                )
            }
        }
        .transition(.opacity)
    }
}
