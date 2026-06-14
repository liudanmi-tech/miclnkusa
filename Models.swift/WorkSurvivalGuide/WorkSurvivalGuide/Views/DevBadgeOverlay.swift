//
//  DevBadgeOverlay.swift
//  WorkSurvivalGuide
//
//  DEV 环境角标 — 仅在 LIVE_MODE_ENABLED 编译条件下使用
//  Release 包不会编译此文件中的任何代码
//

#if LIVE_MODE_ENABLED
import SwiftUI

struct DevBadgeOverlay: View {
    var body: some View {
        VStack {
            HStack {
                Spacer()
                Text("DEV")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.85))
                    .cornerRadius(4)
                    .padding(.top, 56)
                    .padding(.trailing, 12)
            }
            Spacer()
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
#endif
