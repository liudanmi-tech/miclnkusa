//
//  TourManager.swift
//  WorkSurvivalGuide
//
//  Onboarding state manager (singleton)
//

import SwiftUI

// MARK: - TourStep

enum TourStep: Equatable {
    case profileAddButton   // 1/4
    case momentsTab         // 2/4
    case styleButton        // 3/4
    case recordingButton    // 4/4
    case addSkillButton     // extra

    var label: String? {
        switch self {
        case .profileAddButton: return "1 / 4"
        case .momentsTab:       return "2 / 4"
        case .styleButton:      return "3 / 4"
        case .recordingButton:  return "4 / 4"
        default:                return nil
        }
    }

    var tooltip: String {
        switch self {
        case .profileAddButton: return "Create your first profile"
        case .momentsTab:       return "Go to Moments to record today"
        case .styleButton:      return "Tap here to switch card styles"
        case .recordingButton:  return "Tell me what happened today"
        case .addSkillButton:   return "Tap to add skills to practice"
        }
    }

    var isMainTour: Bool {
        switch self {
        case .profileAddButton, .momentsTab, .styleButton, .recordingButton: return true
        default: return false
        }
    }
}

// MARK: - TourManager

final class TourManager: ObservableObject {
    static let shared = TourManager()

    @AppStorage("tour_main_completed") var mainTourCompleted = false
    @AppStorage("tour_skill_shown")    private var skillTipShown = false

    @Published var currentStep: TourStep? = nil
    @Published var highlightFrame: CGRect = .zero

    private init() {}

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
                self.currentStep = .styleButton
            case .styleButton:
                self.currentStep = .recordingButton
            case .recordingButton:
                self.currentStep = nil
                self.mainTourCompleted = true
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
            self.mainTourCompleted = true
            self.skillTipShown = true
        }
    }

    /// Dismiss a single extra tip (skill)
    func dismissExtraTip() {
        DispatchQueue.main.async {
            if self.currentStep == .addSkillButton { self.skillTipShown = true }
            self.currentStep = nil
            self.highlightFrame = .zero
        }
    }

    // MARK: Conditional Triggers

    /// Called from SkillsView.onAppear (first visit)
    func tryShowSkillTip() {
        guard !skillTipShown, mainTourCompleted else { return }
        DispatchQueue.main.async {
            self.highlightFrame = .zero
            self.currentStep = .addSkillButton
            self.skillTipShown = true
        }
    }
}
