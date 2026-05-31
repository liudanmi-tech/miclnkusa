//
//  SubscriptionView.swift
//  WorkSurvivalGuide
//
//  Pro 订阅 Paywall
//

import SwiftUI
import StoreKit

struct SubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager: SubscriptionManager = .shared

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
                        Text("Subscription automatically renews unless cancelled at least 24 hours before the end of the current period. Manage in App Store Settings.")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.3))
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 40)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                }
            }
        }
        .onChange(of: manager.isPro) { newValue in
            if newValue { dismiss() }
        }
        .task {
            await manager.loadProducts()
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

    // 年/周 显示平均每周价格
    private func weeklyEquivalent(for product: Product) -> String? {
        switch product.id {
        case SubscriptionManager.yearlyProductID:
            let perWeek = product.price / 52
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
            return "365 recordings · 15 profiles · AI skill chat"
        case SubscriptionManager.monthlyProductID:
            return "30 recordings · 15 profiles · AI skill chat"
        case SubscriptionManager.weeklyProductID:
            return "7 recordings · 5 profiles · AI skill chat"
        default:
            return ""
        }
    }

    @ViewBuilder
    private var productSection: some View {
        if manager.products.isEmpty {
            ProgressView()
                .tint(.white)
                .frame(height: 80)
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

    var body: some View {
        Button(action: onPurchase) {
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

                    Text(product.displayPrice)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(Color(hex: "#F59E0B"))

                    if let weekly = weeklyEquivalent {
                        Text(weekly)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    }

                    if !services.isEmpty {
                        Text(services)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.45))
                            .padding(.top, 2)
                    }
                }

                Spacer()

                if manager.isLoading {
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
