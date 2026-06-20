//
//  SkillNoteResourceViewModel.swift
//  WorkSurvivalGuide
//
//  管理技能详情页 Note / Resource 卡片的加载、编辑和保存。
//

import Foundation

@MainActor
final class SkillNoteResourceViewModel: ObservableObject {

    // MARK: - Published

    @Published var noteContent: String = ""
    @Published var resourceContent: String = ""
    @Published var noteIsDefault: Bool = true
    @Published var resourceIsDefault: Bool = true
    @Published var isLoading: Bool = false
    @Published var isSaving: Bool = false
    @Published var errorMessage: String? = nil

    // MARK: - Private

    let skillId: String
    private var loadTask: Task<Void, Never>?

    // MARK: - Init

    init(skillId: String) {
        self.skillId = skillId
    }

    // MARK: - Public

    func load() {
        guard !isLoading else { return }
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task {
            do {
                let content = try await NetworkManager.shared.getSkillUserContent(skillId: skillId)
                guard !Task.isCancelled else { return }
                noteContent      = content.noteContent
                resourceContent  = content.resourceContent
                noteIsDefault    = content.noteIsDefault
                resourceIsDefault = content.resourceIsDefault
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func saveNote(_ text: String) {
        Task {
            isSaving = true
            do {
                try await NetworkManager.shared.updateSkillUserContent(
                    skillId: skillId, noteContent: text
                )
                noteContent   = text
                noteIsDefault = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    func saveResource(_ text: String) {
        Task {
            isSaving = true
            do {
                try await NetworkManager.shared.updateSkillUserContent(
                    skillId: skillId, resourceContent: text
                )
                resourceContent   = text
                resourceIsDefault = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
