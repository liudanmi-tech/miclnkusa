//
//  SubscriptionView.swift
//  WorkSurvivalGuide
//
//  Pro 订阅 Paywall
//

import SwiftUI
import StoreKit
import TikTokBusinessSDK

struct SubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager: SubscriptionManager = .shared
    @State private var loadTimeout = false
    @State private var isRetrying = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // 关闭按钮
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 32) {
                        // 标题区
                        VStack(spacing: 12) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 44))
                                .foregroundColor(Color(hex: "#F59E0B"))

                            Text("Go Pro")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundColor(.white)

                            Text("Unlock the full Chattoon experience")
                                .font(.system(size: 16))
                                .foregroundColor(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 8)

                        // 产品卡片
                        productSection

                        // 恢复购买
                        Button("Restore Purchases") {
                            Task { await manager.restorePurchases() }
                        }
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.45))

                        // 法律说明
                        VStack(spacing: 8) {
                            Text("Subscription automatically renews unless cancelled at least 24 hours before the end of the current period. Manage in App Store Settings.")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.55))
                                .multilineTextAlignment(.center)

                            HStack(spacing: 16) {
                                Link("Privacy Policy", destination: URL(string: "https://yohomie.art/privacy.html")!)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.55))
                                Link("Terms of Use (EULA)", destination: URL(string: "https://yohomie.art/terms.html")!)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.55))
                            }
                        }
                        .padding(.bottom, 40)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                }
            }
        }
        .onAppear {
            TikTokTracker.track("ViewContent", ["content_id": "paywall", "content_type": "subscription"])
        }
        .onChange(of: manager.isPro) { newValue in
            if newValue { dismiss() }
        }
        .interactiveDismissDisabled()
        .task {
            let taskId = Int.random(in: 1000...9999)  // 区分并发 task 实例
            print("[SubscriptionView] 📦 task[\(taskId)] 开始，设备:\(UIDevice.current.model) iOS:\(UIDevice.current.systemVersion) cancelled=\(Task.isCancelled)")
            await manager.refreshFromBackend()
            // 预热已完成则直接展示，不重复加载
            guard manager.products.isEmpty else {
                print("[SubscriptionView] task[\(taskId)] ✅ products 已预热(\(manager.products.count)个)，直接展示")
                return
            }
            await manager.loadProducts()
            print("[SubscriptionView] task[\(taskId)] loadProducts 完成 cancelled=\(Task.isCancelled) products=\(manager.products.count)")
            // 最多自动重试 3 次，cancelled 时退出
            var retries = 0
            while manager.products.isEmpty && retries < 3 && !Task.isCancelled {
                print("[SubscriptionView] task[\(taskId)] 🔄 第\(retries + 1)次重试，等待2秒... cancelled=\(Task.isCancelled)")
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else {
                    print("[SubscriptionView] task[\(taskId)] 睡眠后发现已取消，退出重试")
                    return
                }
                await manager.loadProducts()
                retries += 1
            }
            if manager.products.isEmpty {
                print("[SubscriptionView] task[\(taskId)] ⚠️ 自动重试未成功，显示 Retry 按钮")
                loadTimeout = true
            } else {
                print("[SubscriptionView] task[\(taskId)] ✅ 产品加载成功，共\(manager.products.count)个")
            }
        }
    }

    // MARK: - Product section

    // 固定展示顺序：年 → 月 → 周
    private var sortedProducts: [Product] {
        let order = [SubscriptionManager.yearlyProductID,
                     SubscriptionManager.monthlyProductID,
                     SubscriptionManager.weeklyProductID]
        return manager.products.sorted {
            let i0 = order.firstIndex(of: $0.id) ?? 99
            let i1 = order.firstIndex(of: $1.id) ?? 99
            return i0 < i1
        }
    }

    // 年/月/周 显示平均每周价格
    // product.priceFormatStyle 自动跟随用户 storefront 货币（US→USD，CA→CAD）
    private func weeklyEquivalent(for product: Product) -> String? {
        switch product.id {
        case SubscriptionManager.yearlyProductID:
            let perWeek = product.price / 52
            return "≈ " + perWeek.formatted(product.priceFormatStyle) + " / week"
        case SubscriptionManager.monthlyProductID:
            // 1 month = 52/12 ≈ 4.33 weeks，比 /4 更精确
            let perWeek = (product.price * 12) / 52
            return "≈ " + perWeek.formatted(product.priceFormatStyle) + " / week"
        case SubscriptionManager.weeklyProductID:
            return product.displayPrice + " / week"
        default:
            return nil
        }
    }

    // 各档位服务说明
    private func services(for productId: String) -> String {
        switch productId {
        case SubscriptionManager.yearlyProductID:
            return "1100 convert to image · 30 profiles · AI chat"
        case SubscriptionManager.monthlyProductID:
            return "90 convert to image · 15 profiles · AI chat"
        case SubscriptionManager.weeklyProductID:
            return "20 convert to image · 7 profiles · AI chat"
        default:
            return ""
        }
    }

    @ViewBuilder
    private var productSection: some View {
        if manager.products.isEmpty {
            // 始终显示菊花 loading，不显示报错文字；仅在自动重试全部失败后追加 Retry 按钮
            VStack(spacing: 16) {
                ProgressView()
                    .tint(.white)
                    .frame(height: 80)
                if loadTimeout && !isRetrying {
                    Button("Retry") {
                        loadTimeout = false
                        isRetrying = true
                        Task {
                            await manager.loadProducts()
                            isRetrying = false
                            if manager.products.isEmpty { loadTimeout = true }
                        }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "#F59E0B"))
                    // 确保符合 Guideline 3.1.2(c)，链接始终可见
                    HStack(spacing: 16) {
                        Link("Privacy Policy", destination: URL(string: "https://yohomie.art/privacy.html")!)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                        Link("Terms of Use (EULA)", destination: URL(string: "https://yohomie.art/terms.html")!)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.top, 4)
                }
            }
            .frame(minHeight: 100)
        } else {
            VStack(spacing: 12) {
                ForEach(sortedProducts, id: \.id) { product in
                    ProductCard(
                        product: product,
                        isRecommended: product.id == SubscriptionManager.yearlyProductID,
                        weeklyEquivalent: weeklyEquivalent(for: product),
                        services: services(for: product.id),
                        onPurchase: { Task { await manager.purchase(product) } }
                    )
                }
            }
        }

        if let error = manager.purchaseError {
            Text(error)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "#FF5733"))
                .multilineTextAlignment(.center)
                .padding(.top, -12)
        }
    }
}

// MARK: - Product Card

private struct ProductCard: View {
    let product: Product
    let isRecommended: Bool
    let weeklyEquivalent: String?
    let services: String
    let onPurchase: () -> Void
    @ObservedObject private var manager: SubscriptionManager = .shared

    private var periodLabel: String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        switch period.unit {
        case .day:   return period.value == 1 ? "/ day"   : "/ \(period.value) days"
        case .week:  return period.value == 1 ? "/ week"  : "/ \(period.value) weeks"
        case .month: return period.value == 1 ? "/ month" : "/ \(period.value) months"
        case .year:  return period.value == 1 ? "/ year"  : "/ \(period.value) years"
        @unknown default: return ""
        }
    }

    var body: some View {
        Button(action: {
            TikTokTracker.track("InitiateCheckout", [
                "content_id": product.id,
                "currency": "USD",
                "value": NSDecimalNumber(decimal: product.price).doubleValue
            ])
            onPurchase()
        }) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(product.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)

                        if isRecommended {
                            Text("BEST VALUE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color(hex: "#F59E0B"))
                                .clipShape(Capsule())
                        }
                    }

                    Text(product.displayPrice + (periodLabel.isEmpty ? "" : " \(periodLabel)"))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(Color(hex: "#F59E0B"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    if let weekly = weeklyEquivalent {
                        Text(weekly)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }

                    if !services.isEmpty {
                        Text(services)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.top, 2)
                    }
                }

                Spacer()

                if manager.loadingProductId == product.id {
                    ProgressView().tint(.white).scaleEffect(0.9)
                } else {
                    Text("Subscribe")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color(hex: "#F59E0B"))
                        .clipShape(Capsule())
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isRecommended ? Color(hex: "#F59E0B") : Color.white.opacity(0.2),
                        lineWidth: isRecommended ? 1.5 : 1
                    )
            )
        }
        .disabled(manager.isLoading)
    }
}
