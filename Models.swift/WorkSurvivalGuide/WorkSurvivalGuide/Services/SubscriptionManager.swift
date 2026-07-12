//
//  SubscriptionManager.swift
//  WorkSurvivalGuide
//
//  StoreKit 2 订阅管理
//  负责：加载产品、发起购买、监听事务、与后端验证、缓存状态
//

import StoreKit
import Foundation
import TikTokBusinessSDK

@MainActor
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    // App Store 产品 ID（与后端 PRODUCT_TIER_MAP 保持一致）
    static let weeklyProductID    = "com.miclnk.pro.weekly"
    static let monthlyProductID   = "com.miclnk.pro.monthly"
    static let yearlyProductID    = "com.miclnk.pro.yearly"
    static let allProductIDs: Set<String> = [weeklyProductID, monthlyProductID, yearlyProductID]

    @Published var products: [Product] = []
    @Published var isPro: Bool = false
    @Published var isLoading: Bool = false
    @Published var loadingProductId: String? = nil
    @Published var purchaseError: String? = nil
    @Published var monthlyLimit: Int = 20
    @Published var usedCount: Int = 0
    @Published var expiresAt: String? = nil  // ISO8601，从后端同步
    @Published var profileCount: Int = 0
    @Published var profileLimit: Int = 2
    @Published var currentProductId: String? = nil

    // Chat / Image 配额
    @Published var plan: String = "free"      // "free" / "weekly" / "monthly" / "yearly"
    @Published var chatCount: Int = 0
    @Published var chatLimit: Int = 5         // -1 = 无限
    @Published var imageCount: Int = 0
    @Published var imageLimit: Int = 5

    /// 是否还能发起新的 AI Chat 会话
    var canStartChat: Bool { chatLimit == -1 || chatCount < chatLimit }
    /// 是否还能生成对话图片
    var canGenerateImage: Bool { imageLimit > 0 && imageCount < imageLimit }

    private var transactionListenerTask: Task<Void, Error>?

    private init() {
        // 从 UserDefaults 恢复缓存状态（支持离线）
        if let tier = UserDefaults.standard.string(forKey: "sub_tier") {
            isPro = tier == "pro"
        }
        let cachedLimit = UserDefaults.standard.integer(forKey: "sub_monthly_limit")
        monthlyLimit = cachedLimit > 0 ? cachedLimit : 20

        // 后台监听 StoreKit 事务更新
        transactionListenerTask = listenForTransactions()

        Task {
            await refreshFromBackend() // loadProducts() 延迟到打开 Paywall 时调用，避免启动时触发 StoreKit 网络请求
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - 加载 App Store 产品列表（在打开 Paywall 时调用，避免启动时触发 StoreKit 网络请求）

    func loadProducts() async {
        // [诊断] 记录调用时刻 + Task 是否已被取消
        let t0 = Date()
        func ts() -> String { String(format: "+%.2fs", Date().timeIntervalSince(t0)) }
        let cancelledAtEntry = Task.isCancelled
        print("[SubscriptionManager] 🔍 loadProducts() 开始 cancelled=\(cancelledAtEntry) IDs:\(Self.allProductIDs)")

        // 若调用时 Task 已被取消（iOS 26 重建视图场景），直接退出，不当作错误
        guard !cancelledAtEntry else {
            print("[SubscriptionManager] ⚠️ loadProducts() 入口已取消，跳过")
            return
        }

        // iOS 26 fix: 显式调用 AppTransaction.shared（用 try await，不用 try?）
        // iOS 26 要求对 AppTransaction 做显式处理，否则 Product.products(for:) 会直接返回空
        if #available(iOS 16, *) {
            do {
                let appTxResult = try await AppTransaction.shared
                if case .verified(let appTx) = appTxResult {
                    print("[SubscriptionManager] \(ts()) ✅ AppTransaction 验证成功 env=\(appTx.environment.rawValue)")
                } else {
                    print("[SubscriptionManager] \(ts()) ⚠️ AppTransaction 未验证（沙盒/审核环境下属正常）")
                }
            } catch {
                print("[SubscriptionManager] \(ts()) ⚠️ AppTransaction 失败: \(type(of: error)) \(error) — 继续加载产品")
            }
        }

        do {
            // [诊断] 记录 Product.products(for:) 实际耗时，区分"立即空"与"10s超时"
            var productsCallElapsed: Double = 0
            var timedOut = false

            let storeProducts: [Product] = try await withThrowingTaskGroup(of: [Product]?.self) { group in
                let callStart = Date()
                group.addTask {
                    try await Product.products(for: Self.allProductIDs)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000) // 10s 超时
                    return nil  // nil = 超时哨兵
                }
                // 先捕获 CancellationError（来自外部取消），与产品加载失败区分
                do {
                    guard let first = try await group.next() else { return [] }
                    productsCallElapsed = Date().timeIntervalSince(callStart)
                    timedOut = (first == nil)
                    group.cancelAll()
                    return first ?? []
                } catch is CancellationError {
                    productsCallElapsed = Date().timeIntervalSince(callStart)
                    print("[SubscriptionManager] \(ts()) ⚠️ withThrowingTaskGroup 被外部取消 elapsed=\(String(format:"%.2f",productsCallElapsed))s")
                    throw CancellationError()  // 向上传播，让外层 catch 处理
                }
            }

            // [诊断] 打印耗时与是否超时
            if timedOut {
                print("[SubscriptionManager] \(ts()) ⏱ Product.products() 超时(10s)，返回空 — iOS 26 StoreKit 网络不通或 review 环境无法加载产品")
            } else {
                print("[SubscriptionManager] \(ts()) Product.products() 耗时 \(String(format:"%.2f",productsCallElapsed))s，返回 \(storeProducts.count) 个产品")
            }

            self.products = storeProducts
            if storeProducts.isEmpty {
                print("[SubscriptionManager] \(ts()) ⚠️ 产品列表为空 — 所有3个ID均缺失")
            } else {
                print("[SubscriptionManager] \(ts()) ✅ 产品加载成功: \(storeProducts.map(\.id))")
            }
        } catch is CancellationError {
            print("[SubscriptionManager] \(ts()) ⚠️ loadProducts() 被取消（视图关闭/重建），非错误，忽略")
            // 不更新 products，不设错误状态
        } catch let skError as StoreKitError {
            print("[SubscriptionManager] \(ts()) ❌ StoreKit错误 — \(skError) | \(skError.localizedDescription)")
        } catch {
            print("[SubscriptionManager] \(ts()) ❌ 产品加载失败 — type:\(type(of: error)) desc:\(error.localizedDescription) full:\(error)")
        }
    }

    // MARK: - 购买

    func purchase(_ product: Product) async {
        isLoading = true
        loadingProductId = product.id
        purchaseError = nil
        defer {
            isLoading = false
            loadingProductId = nil
        }

        print("[SubscriptionManager] 🛒 开始购买 productId=\(product.id)")

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                print("[SubscriptionManager] ✅ 购买成功 productId=\(transaction.productID) originalID=\(transaction.originalID) type=\(transaction.productType)")
                await sendToBackend(originalTransactionId: String(transaction.originalID), productId: transaction.productID, jwsRepresentation: verification.jwsRepresentation)
                await transaction.finish()
                TikTokBusiness.trackEvent("Subscribe", withProperties: [
                    "content_id": product.id,
                    "currency": "USD",
                    "value": NSDecimalNumber(decimal: product.price).doubleValue
                ])
                TikTokBusiness.trackEvent("Purchase", withProperties: [
                    "content_id": product.id,
                    "currency": "USD",
                    "value": NSDecimalNumber(decimal: product.price).doubleValue
                ])
            case .userCancelled:
                print("[SubscriptionManager] 用户取消购买 productId=\(product.id)")
            case .pending:
                print("[SubscriptionManager] 购买待处理（Ask to Buy）productId=\(product.id)")
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
            print("[SubscriptionManager] 购买失败: \(error)")
        }
    }

    // MARK: - 恢复购买

    func restorePurchases() async {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        // 先强制与 App Store 同步（沙盒测试必要）
        try? await AppStore.sync()

        var didRestore = false
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                await sendToBackend(originalTransactionId: String(transaction.originalID), productId: transaction.productID, jwsRepresentation: result.jwsRepresentation)
                await transaction.finish()
                didRestore = true
            }
        }
        if !didRestore {
            purchaseError = "No active subscriptions found."
        }
    }

    // MARK: - 从后端刷新订阅状态

    func refreshFromBackend() async {
        guard NetworkManager.shared.hasValidToken() else { return }
        do {
            let status = try await NetworkManager.shared.getSubscriptionStatus()
            isPro = status.tier == "pro"
            monthlyLimit = status.monthlyLimit
            usedCount = status.monthlyRecordingCount
            expiresAt = status.expiresAt
            profileCount = status.profileCount ?? 0
            profileLimit = status.profileLimit ?? 2
            // Chat / Image 配额
            plan = status.plan ?? "free"
            chatCount = status.chatCount ?? 0
            chatLimit = status.chatLimit ?? 5   // nil（yearly无限）映射为 -1
            imageCount = status.imageCount ?? 0
            imageLimit = status.imageLimit ?? 5
            // chatLimit nil = yearly 无限，用 -1 标记
            if status.chatLimit == nil { chatLimit = -1 }
            saveToCache(tier: status.tier, limit: status.monthlyLimit)
            if let pid = status.subscriptionProductId, !pid.isEmpty {
                currentProductId = pid  // 后端是权威来源，不再查 StoreKit 避免被沙盒缓存覆盖
            } else {
                await loadCurrentSubscription()  // 后端无记录时降级查本地
            }
        } catch {
            print("[SubscriptionManager] 刷新订阅状态失败: \(error)")
            await loadCurrentSubscription()  // 网络失败时降级查本地
        }
    }

    /// 用户曾是 Pro 但当前未激活 (tier=free + expiresAt 有值) → 已到期
    var isExpired: Bool {
        guard !isPro, let raw = expiresAt, !raw.isEmpty else { return false }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var d = fmt.date(from: raw)
        if d == nil {
            fmt.formatOptions = [.withInternetDateTime]
            d = fmt.date(from: raw)
        }
        return d != nil   // expiresAt 存在 + isPro=false ⇒ 已过期
    }

    var remainingRecordings: Int { max(0, monthlyLimit - usedCount) }

    /// 将 ISO8601 到期时间格式化为 "Expires Jun 30, 2026"，无数据时返回 nil
    var formattedExpiresAt: String? {
        guard let raw = expiresAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: raw)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: raw)
        }
        guard let d = date else { return nil }
        let display = DateFormatter()
        display.dateFormat = "MMM d, yyyy"
        return "Renews \(display.string(from: d))"
    }

    // MARK: - 读取当前激活的订阅产品 ID（StoreKit currentEntitlements）

    func loadCurrentSubscription() async {
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result),
               Self.allProductIDs.contains(transaction.productID) {
                currentProductId = transaction.productID
                return
            }
        }
        currentProductId = nil
    }

    // MARK: - Private

    private nonisolated func listenForTransactions() -> Task<Void, Error> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if let transaction = try? self.checkVerified(result) {
                    print("[SubscriptionManager] 🔔 Transaction.updates 触发 productId=\(transaction.productID) originalID=\(transaction.originalID) revocationDate=\(String(describing: transaction.revocationDate)) environment=\(transaction.environment.rawValue)")
                    await self.sendToBackend(originalTransactionId: String(transaction.originalID), productId: transaction.productID, jwsRepresentation: result.jwsRepresentation)
                    await transaction.finish()
                }
            }
        }
    }

    private nonisolated func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let value): return value
        }
    }

    private func sendToBackend(originalTransactionId: String, productId: String = "", jwsRepresentation: String = "") async {
        print("[SubscriptionManager] 📤 发送后端验证 originalTxId=\(originalTransactionId) productId=\(productId) jwsLen=\(jwsRepresentation.count)")
        do {
            try await NetworkManager.shared.verifyAppleTransaction(
                originalTransactionId: originalTransactionId,
                productId: productId,
                jwsRepresentation: jwsRepresentation
            )
            await refreshFromBackend()
            print("[SubscriptionManager] ✅ 后端验证成功 isPro=\(isPro) plan=\(plan) currentProductId=\(currentProductId ?? "nil")")
        } catch {
            print("[SubscriptionManager] ❌ 后端验证失败: \(error)")
        }
    }

    private func saveToCache(tier: String, limit: Int) {
        UserDefaults.standard.set(tier, forKey: "sub_tier")
        UserDefaults.standard.set(limit, forKey: "sub_monthly_limit")
    }
}
