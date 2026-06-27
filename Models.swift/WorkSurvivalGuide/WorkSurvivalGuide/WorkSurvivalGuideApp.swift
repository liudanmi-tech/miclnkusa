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

@main
struct WorkSurvivalGuideApp: App {
    init() {
        // ── [ATT-DEBUG] 初始化时刻的 ATT 状态 ──
        let attStatusAtInit = ATTrackingManager.trackingAuthorizationStatus
        print("[ATT-DEBUG] 🚀 App.init() — ATT status = \(attStatusAtInit.rawValue) (0=notDetermined 1=restricted 2=denied 3=authorized)")

        // TikTok Business SDK initialization
        let tikTokConfig = TikTokConfig(
            accessToken: "TTcCUI8nZ5aMr3uLCVKXRVDluc5nX4Rc",
            appId: "6766467422",
            tiktokAppId: "7653662064061202452"
        )
        if let cfg = tikTokConfig {
            print("[ATT-DEBUG] ✅ TikTokConfig 创建成功，开始初始化 SDK")
            #if DEBUG
            cfg.debugModeEnabled = true
            #endif
            TikTokBusiness.initializeSdk(cfg)
            print("[ATT-DEBUG] ✅ TikTokBusiness.initializeSdk() 已调用")
        } else {
            print("[ATT-DEBUG] ❌ TikTokConfig 返回 nil — SDK 未初始化，ATT 不会触发！")
        }

        // Kochava MMP initialization
        // ATT 弹窗已由 TikTok SDK 负责，Kochava 不重复发起（enabledBool 保持默认 false）
        // 等待 60 秒，让用户有足够时间响应 TikTok 触发的 ATT 弹窗后再读取授权状态
        Measurement.shared.appTrackingTransparency.authorizationStatusWaitTimeInterval = 60.0
        Measurement.shared.start(appGUIDString: "kochattoon-1ndn6cc95")
        print("[ATT-DEBUG] ✅ Kochava Measurement.start() 已调用")

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

    var body: some View {
        ZStack {
            ContentView()
            if showSplash {
                SplashScreenView(onFinish: { showSplash = false })
            } else if !hasAcceptedTerms {
                TermsAgreementView(onAccept: { hasAcceptedTerms = true })
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
            // [ATT-DEBUG] SplashScreenView 出现时 UIWindow 已就绪，此时检查并手动触发 ATT
            let attStatusOnAppear = ATTrackingManager.trackingAuthorizationStatus
            print("[ATT-DEBUG] 🪟 SplashScreenView.onAppear — ATT status = \(attStatusOnAppear.rawValue)")
            if attStatusOnAppear == .notDetermined {
                print("[ATT-DEBUG] ▶️ 手动调用 requestTrackingAuthorization（诊断用）")
                ATTrackingManager.requestTrackingAuthorization { status in
                    print("[ATT-DEBUG] 🔔 ATT 弹窗回调 result = \(status.rawValue) (0=notDetermined 1=restricted 2=denied 3=authorized)")
                }
            } else {
                print("[ATT-DEBUG] ⏭ ATT 已有结果(\(attStatusOnAppear.rawValue))，跳过弹窗")
            }

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
