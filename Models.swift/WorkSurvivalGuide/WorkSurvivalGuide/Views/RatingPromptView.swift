//
//  RatingPromptView.swift
//  WorkSurvivalGuide
//
//  首次 AI Chat 退出后弹出，引导用户在 App Store 评分
//

import SwiftUI
import StoreKit

struct RatingPromptView: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                Spacer()

                VStack(alignment: .center, spacing: 0) {

                    // 拖拽条
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 36, height: 4)
                        .padding(.top, 14)
                        .padding(.bottom, 24)

                    // 表情
                    Text("✨")
                        .font(.system(size: 44))
                        .padding(.bottom, 12)

                    // 标题
                    Text("How's Chattoon so far?")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Text("You just had your first AI conversation")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 32)

                    // Love it 按钮
                    Button {
                        onDismiss()
                        requestReview()
                    } label: {
                        HStack(spacing: 8) {
                            Text("😍")
                                .font(.system(size: 20))
                            Text("Love it!")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundColor(.black)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: "#34D399"))
                        .cornerRadius(14)
                    }
                    .padding(.horizontal, 16)

                    // Not yet 按钮
                    Button {
                        onDismiss()
                    } label: {
                        Text("Not yet")
                            .font(.system(size: 15, design: .rounded))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.vertical, 16)
                    }
                    .padding(.bottom, 24)
                }
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(hex: "#111111"))
                        .ignoresSafeArea(edges: .bottom)
                )
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func requestReview() {
        // 优先使用系统原生评分弹窗
        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            SKStoreReviewController.requestReview(in: scene)
        } else {
            // 降级：直接打开 App Store 评分页
            let url = URL(string: "https://itunes.apple.com/app/id6766467422?action=write-review")!
            UIApplication.shared.open(url)
        }
    }
}
