//
//  OnboardingView.swift
//  WorkSurvivalGuide
//
//  首次登录时静默完成：自动选全部技能分类，同步服务端，立即进入主界面。
//  不展示任何 UI，消除注册漏斗跳失。
//

import SwiftUI

struct OnboardingView: View {
    @AppStorage("onboarding_completed")  private var onboardingCompleted = false
    @AppStorage("onboarding_identity")   private var savedIdentity = ""
    @AppStorage("onboarding_categories") private var savedCategories = ""
    @AppStorage("onboarding_subskills")  private var savedSubSkills = ""

    var body: some View {
        Color.clear
            .onAppear { autoComplete() }
    }

    private func autoComplete() {
        let allCategories = SkillCategoryPresets.categories(for: .both)
        savedIdentity   = UserIdentity.both.rawValue
        savedCategories = allCategories.map(\.id).joined(separator: ",")
        let allSubSkillIds = allCategories.flatMap { $0.subSkills.map(\.id) }
        savedSubSkills = allSubSkillIds.joined(separator: ",")
        Task { try? await NetworkManager.shared.updateSkillPreferences(selectedSkills: allSubSkillIds) }
        onboardingCompleted = true
    }
}
