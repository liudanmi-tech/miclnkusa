//
//  TourManager.swift
//  WorkSurvivalGuide
//
//  新手引导状态管理（单例）
//

import SwiftUI

// MARK: - TourStep

enum TourStep: Equatable {
    case profileAddButton   // 1/4
    case momentsTab         // 2/4
    case recordingButton    // 3/4
    case skillInDetail      // 4/4
    case styleButton        // extra
    case addSkillButton     // extra

    var label: String? {
        switch self {
        case .profileAddButton: return "1 / 4"
        case .momentsTab:       return "2 / 4"
        case .recordingButton:  return "3 / 4"
        case .skillInDetail:    return "4 / 4"
        default:                return nil
        }
    }

    var tooltip: String {
        switch self {
        case .profileAddButton: return "点击这里，创建第一个档案"
        case .momentsTab:       return "前往 Moments，记录今天的对话"
        case .recordingButton:  return "说说你今日的心情"
        case .skillInDetail:    return "点击技能，与 AI 深度对话"
        case .styleButton:      return "点这里可以切换卡片风格"
        case .addSkillButton:   return "点击添加你想练习的技能"
        }
    }

    var isMainTour: Bool {
        switch self {
        case .profileAddButton, .momentsTab, .recordingButton, .skillInDetail: return true
        default: return false
        }
    }
}

// MARK: - TourManager

final class TourManager: ObservableObject {
    static let shared = TourManager()

    @AppStorage("tour_main_completed") var mainTourCompleted = false
    @AppStorage("tour_style_shown")    private var styleTipShown = false
    @AppStorage("tour_skill_shown")    private var skillTipShown = false

    @Published var currentStep: TourStep? = nil
    @Published var highlightFrame: CGRect = .zero

    /// true after step 3: waiting for a detail page with skills to show step 4
    var waitingForSkillStep = false
    /// true after entering detail: triggers style tip on next Moments appear
    var hasVisitedDetail = false
    /// true while TaskDetailView is on screen（防止 step 4 在非详情页触发）
    var isInDetailView = false

    private init() {
        #if DEBUG
        // 开发阶段每次启动重置，方便反复调试引导效果
        mainTourCompleted = false
        styleTipShown     = false
        skillTipShown     = false
        #endif
    }

    // MARK: Frame

    func setHighlightFrame(_ frame: CGRect) {
        DispatchQueue.main.async { self.highlightFrame = frame }
    }

    // MARK: Lifecycle

    func startMainTour() {
        guard !mainTourCompleted else { return }
        DispatchQueue.main.async {
            self.highlightFrame = .zero
            self.currentStep = .profileAddButton
        }
    }

    func advance() {
        DispatchQueue.main.async {
            self.highlightFrame = .zero
            switch self.currentStep {
            case .profileAddButton:
                self.currentStep = .momentsTab
            case .momentsTab:
                self.currentStep = .recordingButton
            case .recordingButton:
                // spotlight off; wait for detail page with skills
                self.currentStep = nil
                self.waitingForSkillStep = true
            case .skillInDetail:
                self.currentStep = nil
                self.mainTourCompleted = true
            case .styleButton:
                self.currentStep = nil
                self.styleTipShown = true
            case .addSkillButton:
                self.currentStep = nil
                self.skillTipShown = true
            case .none:
                break
            }
        }
    }

    /// Skip ALL remaining guides (main tour + extra tips)
    func skipMainTour() {
        DispatchQueue.main.async {
            self.currentStep = nil
            self.highlightFrame = .zero
            self.waitingForSkillStep = false
            self.mainTourCompleted = true
            self.styleTipShown = true
            self.skillTipShown = true
        }
    }

    /// Dismiss a single extra tip (style / skill)
    func dismissExtraTip() {
        DispatchQueue.main.async {
            if self.currentStep == .styleButton  { self.styleTipShown  = true }
            if self.currentStep == .addSkillButton { self.skillTipShown = true }
            self.currentStep = nil
            self.highlightFrame = .zero
        }
    }

    // MARK: Conditional Triggers

    /// Called from TaskDetailView when skills finish loading
    func onDetailViewAppeared(hasSkills: Bool) {
        guard waitingForSkillStep, hasSkills, isInDetailView else { return }
        waitingForSkillStep = false
        DispatchQueue.main.async { self.currentStep = .skillInDetail }
    }

    /// Called from TaskListView.onAppear after returning from detail
    func tryShowStyleTip() {
        guard !styleTipShown, currentStep == nil else { return }
        DispatchQueue.main.async {
            self.highlightFrame = .zero
            self.currentStep = .styleButton
        }
    }

    /// Called from SkillsView.onAppear (first visit)
    func tryShowSkillTip() {
        guard !skillTipShown, currentStep == nil else { return }
        DispatchQueue.main.async {
            self.highlightFrame = .zero
            self.currentStep = .addSkillButton
            self.skillTipShown = true
        }
    }
}
