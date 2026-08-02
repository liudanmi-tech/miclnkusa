//
//  ForceUpdateView.swift
//  WorkSurvivalGuide
//
//  强制更新全屏遮罩：当服务端 ios_minimum_version 高于当前版本时展示，无法关闭。
//

import SwiftUI

struct ForceUpdateView: View {
    private let appStoreURL = URL(string: "itms-apps://itunes.apple.com/app/id6766467422")!

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // 图标
                ZStack {
                    Circle()
                        .fill(Color(hex: "#34D399").opacity(0.15))
                        .frame(width: 88, height: 88)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(Color(hex: "#34D399"))
                }
                .padding(.bottom, 28)

                // 标题
                Text("Update Required")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.bottom, 12)

                // 说明文字
                Text("A new version of Chattoon is available.\nPlease update to continue using the app.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 40)

                Spacer()

                // 更新按钮
                Button {
                    UIApplication.shared.open(appStoreURL)
                } label: {
                    Text("Update Now")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "#34D399"))
                        .cornerRadius(14)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 52)
            }
        }
        // 禁止任何手势关闭（back swipe 等）
        .interactiveDismissDisabled(true)
    }
}
