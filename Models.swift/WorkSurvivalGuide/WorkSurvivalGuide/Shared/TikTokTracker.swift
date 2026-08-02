//
//  TikTokTracker.swift
//  WorkSurvivalGuide
//
//  统一 TikTok 埋点入口，自动注入 app_version 和 os_version。
//  用法：TikTokTracker.track("EventName", ["key": "value"])
//

import Foundation
import UIKit
import TikTokBusinessSDK

enum TikTokTracker {

    /// App 版本号，读自 CFBundleShortVersionString（例如 "2.1.0"）
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// 设备 iOS 版本号（例如 "18.3.1"）
    static var iOSVersion: String {
        UIDevice.current.systemVersion
    }

    /// 上报事件，自动合并 app_version / os_version 到 properties
    static func track(_ event: String, _ properties: [String: Any] = [:]) {
        var props = properties
        props["app_version"] = appVersion
        props["os_version"]  = iOSVersion
        TikTokBusiness.trackEvent(event, withProperties: props)
    }
}
