//
//  AppConfig.swift
//  WorkSurvivalGuide
//
//  应用配置（环境切换）
//

import Foundation

enum AppEnvironment {
    case development  // 开发环境（使用 Mock 数据）
    case production   // 生产环境（使用真实 API）
}

class AppConfig {
    static let shared = AppConfig()
    
    // 当前环境（可以通过 UserDefaults 或编译配置切换）
    var currentEnvironment: AppEnvironment {
        // 方法 1: 通过 UserDefaults 切换（运行时切换）
        if let useMock = UserDefaults.standard.object(forKey: "use_mock_data") as? Bool {
            return useMock ? .development : .production
        }
        
        // 方法 2: 通过编译配置切换（编译时切换）
        // 默认使用真实 API（生产环境）
        #if DEBUG
        // DEBUG 模式下，默认使用真实 API，可以通过 UserDefaults 切换
        return .production
        #else
        return .production
        #endif
    }
    
    // 是否使用 Mock 数据
    var useMockData: Bool {
        return currentEnvironment == .development
    }
    
    // 方案二：北京只读 API 双域路由（中国用户提速）
    // 为 true 时：读接口走北京，写接口走新加坡
    var useBeijingRead: Bool {
        if let v = UserDefaults.standard.object(forKey: "use_beijing_read") as? Bool {
            return v
        }
        #if DEBUG
        return true
        #else
        return true
        #endif
    }
    
    /// 是否连接测试服（34.74.255.48）
    /// ⚠️ 只改 DEBUG 块里的 return 值：false = 生产，true = 测试服
    /// Release 包永远 false，不受影响，App Store 提交安全
    var useTestServer: Bool {
#if DEBUG
return true  // ← 切测试服改 true，切生产改 false
        #else
        return true   // ⚠️ 内测包临时改为测试服，提审前必须改回 false
        #endif
    }

    /// API 读接口 baseURL
    var readBaseURL: String {
        useTestServer ? "http://34.74.255.48/api/v1" : "https://api.yohomie.art/api/v1"
    }

    /// API 写接口 baseURL
    var writeBaseURL: String {
        useTestServer ? "http://34.74.255.48/api/v1" : "https://api.yohomie.art/api/v1"
    }

    /// SSE 事件流专用 baseURL（HTTPS 避免 iOS URLSession HTTP 缓冲问题）
    var sseBaseURL: String {
        useTestServer ? "https://test-api.yohomie.art" : "https://api.yohomie.art"
    }

    private init() {}

    // 切换环境（用于测试）
    func setUseMockData(_ useMock: Bool) {
        UserDefaults.standard.set(useMock, forKey: "use_mock_data")
    }

    /// 切换北京只读（用于测试或地区切换）
    func setUseBeijingRead(_ use: Bool) {
        UserDefaults.standard.set(use, forKey: "use_beijing_read")
    }
}

