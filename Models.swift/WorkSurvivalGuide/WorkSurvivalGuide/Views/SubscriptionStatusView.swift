//
//  SubscriptionStatusView.swift
//  WorkSurvivalGuide
//
//  订阅状态页 — 显示当前套餐、用量进度、管理操作
//

import StoreKit
import SwiftUI

struct SubscriptionStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager: SubscriptionManager = .shared
    @State private var showPaywall = false

    // 套餐显示名
    private var planDisplayName: String {
        switch manager.currentProductId {
        case SubscriptionManager.weeklyProductID:  return "Pro Weekly"
        case SubscriptionManager.monthlyProductID: return "Pro Monthly"
        case SubscriptionManager.yearlyProductID:  return "Pro Yearly"
        default: return manager.isPro ? "Pro" : "Free"
        }
    }

    // 到期/续费标签
    private var renewalLabel: String {
        if manager.isExpired {
            if let s = manager.formattedExpiresAt { return s.replacingOccurrences(of: "Renews", with: "Expired") }
            return "Expired"
        }
        return manager.formattedExpiresAt ?? "Active"
    }

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
                    VStack(spacing: 28) {

                        // ── 套餐状态卡 ───────────────────────────────
                        planCard

                        // ── 用量进度 ─────────────────────────────────
                        usageSection

                        // ── 操作按钮 ─────────────────────────────────
                        actionSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 48)
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            SubscriptionView()
        }
        .task {
            await manager.refreshFromBackend()
        }
    }

    // MARK: - Plan card

    private var planCard: some View {
        VStack(spacing: 10) {
            Image(systemName: manager.isPro ? "crown.fill" : "person.circle")
                .font(.system(size: 40))
                .foregroundColor(manager.isPro ? Color(hex: "#F59E0B") : .white.opacity(0.5))

            Text(planDisplayName)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)

            // 状态徽章
            Text(manager.isExpired ? "Expired" : (manager.isPro ? "Active" : "Free Plan"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(manager.isExpired ? .white : (manager.isPro ? Color(hex: "#34D399") : .white.opacity(0.6)))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    (manager.isExpired
                     ? Color(hex: "#EF4444")
                     : (manager.isPro ? Color(hex: "#34D399") : Color.white.opacity(0.12)))
                    .opacity(manager.isExpired ? 0.18 : 0.18)
                )
                .clipShape(Capsule())

            if !manager.isPro && !manager.isExpired {
                Text("Upgrade for more AI chats & image conversions")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            } else {
                Text(renewalLabel)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Usage section

    private var usageSection: some View {
        VStack(spacing: 16) {
            usageRow(
                icon: "bubble.left.and.bubble.right.fill",
                label: "AI Chat",
                used: manager.chatCount,
                limit: manager.chatLimit   // -1 = unlimited (yearly)
            )
            usageRow(
                icon: "photo.fill",
                label: "Convert to Image",
                used: manager.imageCount,
                limit: manager.imageLimit
            )
            usageRow(
                icon: "person.2.fill",
                label: "Profiles",
                used: manager.profileCount,
                limit: manager.profileLimit
            )
        }
        .padding(16)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// limit == -1 表示无限（Yearly AI Chat）
    private func usageRow(icon: String, label: String, used: Int, limit: Int) -> some View {
        let isUnlimited = limit == -1
        let ratio: CGFloat = isUnlimited ? 0.12 : (limit > 0 ? min(CGFloat(used) / CGFloat(limit), 1.0) : 0)
        let barColor: Color = isUnlimited
            ? Color(hex: "#34D399")
            : (ratio >= 1.0 ? Color(hex: "#EF4444") : Color(hex: "#F59E0B"))
        let countText: String = isUnlimited ? "\(used) / ∞" : "\(used) / \(limit)"

        return VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(barColor)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                Text(countText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 6)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * ratio, height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Action section

    private var actionSection: some View {
        VStack(spacing: 12) {
            if manager.isExpired || !manager.isPro {
                // 过期 or 免费 → 订阅/升级
                actionButton(
                    title: manager.isExpired ? "Re-subscribe" : "Go Pro",
                    icon: "crown.fill",
                    color: Color(hex: "#F59E0B"),
                    foreground: .black
                ) {
                    showPaywall = true
                }
            } else {
                // Manage Subscription（打开 App Store 管理页）
                actionButton(
                    title: "Manage Subscription",
                    icon: "arrow.up.right",
                    color: Color.white.opacity(0.1),
                    foreground: .white
                ) {
                    Task {
                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                            try? await AppStore.showManageSubscriptions(in: scene)
                        }
                    }
                }
            }

            // Restore Purchases（始终显示）
            Button("Restore Purchases") {
                Task { await manager.restorePurchases() }
            }
            .font(.system(size: 14))
            .foregroundColor(.white.opacity(0.45))

            if let err = manager.purchaseError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#EF4444"))
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                Link("Privacy Policy", destination: URL(string: "https://yohomie.art/privacy.html")!)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                Link("Terms of Use", destination: URL(string: "https://yohomie.art/terms.html")!)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(.top, 4)
        }
    }

    private func actionButton(
        title: String,
        icon: String,
        color: Color,
        foreground: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(manager.isLoading)
    }
}
