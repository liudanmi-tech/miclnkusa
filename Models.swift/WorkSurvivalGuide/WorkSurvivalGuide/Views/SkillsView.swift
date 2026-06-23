//
//  SkillsView.swift
//  WorkSurvivalGuide
//
//  技能库：顶部星域卡片，下方展示用户 onboarding 选择的场景及其子技能（横向卡片）
//

import SwiftUI

// MARK: - OnboardingCategory helpers (UI only)

private extension OnboardingCategory {
    var accentColor: Color {
        switch id {
        case "work_life":       return Color(hex: "#45B7D1")
        case "campus_life":     return Color(hex: "#A78BFA")
        case "relationships":   return Color(hex: "#F472B6")
        case "family":          return Color(hex: "#FB923C")
        case "personal_growth": return Color(hex: "#34D399")
        case "life_skills":     return Color(hex: "#FBBF24")
        default:                return Color(hex: "#5E7C8B")
        }
    }
}

// MARK: - OnboardingSubSkill icon helper

private extension OnboardingSubSkill {
    var icon: String {
        switch id {
        case "salary_negotiation":  return "💰"
        case "difficult_boss":      return "⚡"
        case "work_boundaries":     return "🛑"
        case "performance_reviews": return "📊"
        case "feedback":            return "💬"
        case "job_interviews":      return "🎯"
        case "coworker_conflicts":  return "🤝"
        case "remote_work":         return "💻"
        case "roommate_conflicts":  return "🏠"
        case "professor_email":     return "📧"
        case "group_projects":      return "👥"
        case "making_friends":      return "😊"
        case "asking_extensions":   return "⏰"
        case "academic_burnout":    return "🔥"
        case "internship_interview":return "💼"
        case "networking":          return "🌐"
        case "partner_communication":return "💕"
        case "talking_stage":       return "💭"
        case "ghosting_rejection":  return "👻"
        case "situationship":       return "❓"
        case "dtr_conversation":    return "💍"
        case "breakups":            return "💔"
        case "friendship_conflicts":return "🫂"
        case "coming_out":          return "🌈"
        case "parent_boundaries":   return "🛡"
        case "immigrant_family":    return "🌏"
        case "family_money":        return "💵"
        case "coparenting":         return "👶"
        case "parent_teen":         return "🎓"
        case "coming_out_family":   return "🌈"
        case "assertiveness":       return "💪"
        case "imposter_syndrome":   return "🎭"
        case "social_anxiety":      return "😰"
        case "burnout_recovery":    return "🌱"
        case "anger_management":    return "🧘"
        case "friend_crisis":       return "🆘"
        case "dealing_criticism":   return "🪞"
        case "boundary_setting":    return "🔒"
        case "healthcare_advocacy": return "🏥"
        case "customer_service":    return "📞"
        case "money_conversations": return "💸"
        case "neighbor_conflicts":  return "🏘"
        case "landlord_comm":       return "🔑"
        default:                    return "✨"
        }
    }
}

struct SkillsView: View {
    @ObservedObject private var viewModel = SkillsViewModel.shared

    // Source of truth: sub-skill IDs (set by onboarding + SkillAddSheet)
    @AppStorage("onboarding_subskills") private var savedSubSkills = ""
    // Fallback: category IDs written by onboarding (used to seed subskills if empty)
    @AppStorage("onboarding_categories") private var savedCategories = ""

    @State private var selectedSkill: OnboardingSubSkill? = nil
    @State private var showAddSheet = false
    @State private var customSkills: [CustomSkill] = []
    @State private var selectedCustomSkill: CustomSkill? = nil

    private var selectedSubSkillIds: Set<String> {
        Set(savedSubSkills.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// Categories that have at least one selected sub-skill, paired with their selected sub-skills only
    private var categoriesWithSelections: [(category: OnboardingCategory, subSkills: [OnboardingSubSkill])] {
        SkillCategoryPresets.all.compactMap { cat in
            let selected = cat.subSkills.filter { selectedSubSkillIds.contains($0.id) }
            return selected.isEmpty ? nil : (cat, selected)
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                SkillsHeaderView(viewModel: viewModel, onAddTap: { showAddSheet = true })

                WeeklyStatsCarouselView()
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                if categoriesWithSelections.isEmpty && customSkills.isEmpty {
                    Spacer()
                    VStack(spacing: 14) {
                        Image(systemName: "list.star")
                            .font(.system(size: 44))
                            .foregroundColor(.white.opacity(0.3))
                        Text("No focus areas selected")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.4))
                        Text("Tap + to add skills to your library.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(.white.opacity(0.3))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    Spacer()
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(categoriesWithSelections, id: \.category.id) { item in
                                OnboardingCategorySection(
                                    category: item.category,
                                    displaySubSkills: item.subSkills,
                                    onSelectSkill: { selectedSkill = $0 }
                                )
                            }

                            if !customSkills.isEmpty {
                                CustomSkillsSection(
                                    skills: customSkills,
                                    onSelectSkill: { selectedCustomSkill = $0 },
                                    onDelete: { id in deleteCustomSkill(id: id) }
                                )
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 120)
                    }
                }
            }
        }
        .onAppear {
            if viewModel.categories.isEmpty && !viewModel.isLoading {
                viewModel.loadCatalog()          // 首次：全量加载
            } else {
                viewModel.checkVersionAndRefreshIfNeeded()  // 已有数据：静默版本检测
            }
            // 首次进入 Skills 页触发 Add Skill 提示
            TourManager.shared.tryShowSkillTip()
            // Seed subskills from categories if this is a user who onboarded before the sub-skill update
            if savedSubSkills.isEmpty && !savedCategories.isEmpty {
                let catIds = Set(savedCategories.split(separator: ",").map(String.init))
                let allSubIds = SkillCategoryPresets.all
                    .filter { catIds.contains($0.id) }
                    .flatMap { $0.subSkills.map(\.id) }
                savedSubSkills = allSubIds.joined(separator: ",")
            }
            // Default: if user skipped onboarding entirely, seed with relationships + family + personal growth
            if savedSubSkills.isEmpty && savedCategories.isEmpty {
                let defaultIds: Set<String> = ["relationships", "family", "personal_growth"]
                let allSubIds = SkillCategoryPresets.all
                    .filter { defaultIds.contains($0.id) }
                    .flatMap { $0.subSkills.map(\.id) }
                savedCategories = defaultIds.joined(separator: ",")
                savedSubSkills  = allSubIds.joined(separator: ",")
            }
            loadCustomSkills()
        }
        .onReceive(NotificationCenter.default.publisher(for: .customSkillsDidChange)) { _ in
            loadCustomSkills()
        }
        .onChange(of: savedSubSkills) { newValue in
            guard !newValue.isEmpty else { return }
            let skillIds = newValue.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            Task {
                try? await NetworkManager.shared.updateSkillPreferences(selectedSkills: skillIds)
            }
        }
        .sheet(item: $selectedSkill) { skill in
            OnboardingSubSkillDetailSheet(skill: skill)
        }
        .sheet(item: $selectedCustomSkill) { skill in
            CustomSkillDetailSheet(skill: skill)
        }
        .sheet(isPresented: $showAddSheet, onDismiss: loadCustomSkills) {
            SkillAddSheet()
        }
    }

    private func loadCustomSkills() {
        Task {
            let skills = (try? await NetworkManager.shared.listCustomSkills()) ?? []
            await MainActor.run { customSkills = skills }
        }
    }

    private func deleteCustomSkill(id: String) {
        Task {
            try? await NetworkManager.shared.deleteCustomSkill(skillId: id)
            await MainActor.run {
                customSkills.removeAll { $0.id == id }
            }
        }
    }
}

// MARK: - Onboarding Category Section

private struct OnboardingCategorySection: View {
    let category: OnboardingCategory
    let displaySubSkills: [OnboardingSubSkill]   // only the selected sub-skills to display
    let onSelectSkill: (OnboardingSubSkill) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(category.emoji)
                    .font(.system(size: 18))
                Text(category.name)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Text("\(displaySubSkills.count) skill\(displaySubSkills.count == 1 ? "" : "s")")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(displaySubSkills) { skill in
                        OnboardingSubSkillCard(
                            skill: skill,
                            accentColor: category.accentColor
                        ) {
                            onSelectSkill(skill)
                        }
                        .frame(width: cardWidth)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var cardWidth: CGFloat {
        (UIScreen.main.bounds.width - 52) / 2
    }
}

// MARK: - Onboarding SubSkill Card

private struct OnboardingSubSkillCard: View {
    let skill: OnboardingSubSkill
    let accentColor: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // 顶部色块（对应 SkillCatalogCardView 的 coverGradient 区域）
                ZStack {
                    LinearGradient(
                        colors: [accentColor.opacity(0.85), accentColor.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(skill.icon)
                        .font(.system(size: 40))
                        .opacity(0.7)
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                // 名称 + 描述
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(skill.description)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                        .lineSpacing(2)
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(white: 0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Onboarding SubSkill Detail Sheet

struct OnboardingSubSkillDetailSheet: View {
    let skill: OnboardingSubSkill
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarding_subskills") private var savedSubSkills = ""
    @StateObject private var contentVM: SkillNoteResourceViewModel

    init(skill: OnboardingSubSkill) {
        self.skill = skill
        _contentVM = StateObject(wrappedValue: SkillNoteResourceViewModel(skillId: skill.id))
    }

    private func unsubscribe() {
        var ids = savedSubSkills.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        ids.removeAll { $0 == skill.id }
        savedSubSkills = ids.joined(separator: ",")
        dismiss()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {

                        VStack(alignment: .leading, spacing: 8) {
                            Text(skill.name)
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)
                            Text(skill.description)
                                .font(.system(size: 15))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .padding(.top, 8)

                        // NOTE 卡片
                        SkillEditableCard(
                            icon: "note.text",
                            iconColor: Color(hex: "#A29BFE"),
                            title: "Note",
                            isDefault: contentVM.noteIsDefault,
                            content: contentVM.noteContent,
                            isLoading: contentVM.isLoading,
                            isSaving: contentVM.isSaving,
                            onSave: { contentVM.saveNote($0) }
                        )

                        // RESOURCE 卡片
                        SkillEditableCard(
                            icon: "books.vertical.fill",
                            iconColor: Color(hex: "#00B894"),
                            title: "Resource",
                            isDefault: contentVM.resourceIsDefault,
                            content: contentVM.resourceContent,
                            isLoading: contentVM.isLoading,
                            isSaving: contentVM.isSaving,
                            onSave: { contentVM.saveResource($0) }
                        )

                        if let err = contentVM.errorMessage {
                            Text(err)
                                .font(.system(size: 13))
                                .foregroundColor(.red.opacity(0.8))
                        }

                        Spacer(minLength: 32)
                    }
                    .padding(.horizontal, 20)
                }
                .safeAreaInset(edge: .bottom) {
                    Button(action: unsubscribe) {
                        Text("Unsubscribe")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(white: 0.22))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .background(Color.black)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { contentVM.load() }
        }
    }

}

// MARK: - Header (unchanged)

struct SkillsHeaderView: View {
    @ObservedObject var viewModel: SkillsViewModel
    var onAddTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Skill Library")
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .tracking(0.6)

            Spacer()

            // Add skills button
            Button(action: {
                onAddTap?()
                if TourManager.shared.currentStep == .addSkillButton {
                    TourManager.shared.dismissExtraTip()
                }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Add Skill")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Color(hex: "#5E7C8B")))
            }
            .buttonStyle(.plain)
            .tourHighlight(.addSkillButton)
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
    }
}

// MARK: - Custom Skills Section

private struct CustomSkillsSection: View {
    let skills: [CustomSkill]
    let onSelectSkill: (CustomSkill) -> Void
    let onDelete: (String) -> Void

    private let accentColor = Color(hex: "#A78BFA")  // Purple for custom skills

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("✨")
                    .font(.system(size: 18))
                Text("Custom Skills")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Text("\(skills.count) skill\(skills.count == 1 ? "" : "s")")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(skills) { skill in
                        CustomSkillCard(
                            skill: skill,
                            accentColor: accentColor,
                            onTap: { onSelectSkill(skill) },
                            onDelete: { onDelete(skill.id) }
                        )
                        .frame(width: (UIScreen.main.bounds.width - 52) / 2)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

private struct CustomSkillCard: View {
    let skill: CustomSkill
    let accentColor: Color
    let onTap: () -> Void
    let onDelete: () -> Void
    @State private var showDeleteConfirm = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    LinearGradient(
                        colors: [accentColor.opacity(0.85), accentColor.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    VStack(spacing: 4) {
                        Text("✨")
                            .font(.system(size: 36))
                            .opacity(0.7)
                        Text("Custom")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .tracking(0.8)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(skill.description ?? "Custom skill guide")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                        .lineSpacing(2)
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(white: 0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(accentColor.opacity(0.25), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .confirmationDialog("Remove this skill?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Custom Skill Detail Sheet

struct CustomSkillDetailSheet: View {
    let skill: CustomSkill
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text("✨")
                                    .font(.system(size: 20))
                                Text("Custom Skill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color(hex: "#A78BFA"))
                                    .tracking(0.8)
                            }
                            Text(skill.name)
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)
                            if let desc = skill.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 15))
                                    .foregroundColor(.white.opacity(0.6))
                                    .lineSpacing(3)
                            }
                        }
                        .padding(.top, 8)

                        if let md = skill.markdown_content, !md.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("SKILL GUIDE")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.35))
                                    .tracking(1.2)
                                Text(md)
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.8))
                                    .lineSpacing(4)
                                    .padding(16)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(14)
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("PRACTICE")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.35))
                                .tracking(1.2)
                            Text("Record a real conversation where this skill is relevant. The AI will use this custom skill guide to analyze your conversation and give personalized feedback.")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.7))
                                .lineSpacing(3)
                        }
                        .padding(16)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(14)

                        Spacer(minLength: 32)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

// MARK: - Skill Editable Card (Note / Resource)

struct SkillEditableCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let isDefault: Bool
    let content: String
    let isLoading: Bool
    let isSaving: Bool
    let onSave: (String) -> Void

    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(iconColor)
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
                    .tracking(1.0)
                if isDefault {
                    Text("DEFAULT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(iconColor.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(iconColor.opacity(0.15)))
                }
                Spacer()
                Button(action: { showEditor = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil").font(.system(size: 12))
                        Text("Edit").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(iconColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(iconColor.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }

            Group {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white.opacity(0.5))
                        Text("Loading…").font(.system(size: 13)).foregroundColor(.white.opacity(0.4))
                    }
                    .frame(height: 40)
                } else {
                    Text(content.isEmpty ? "Tap Edit to add content." : content)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(content.isEmpty ? .white.opacity(0.3) : .white.opacity(0.82))
                        .lineSpacing(4)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                    )
            )
        }
        .sheet(isPresented: $showEditor) {
            SkillContentEditorSheet(
                title: title,
                iconColor: iconColor,
                initialText: content,
                isSaving: isSaving,
                onSave: { text in onSave(text); showEditor = false }
            )
        }
    }
}

struct SkillContentEditorSheet: View {
    let title: String
    let iconColor: Color
    let initialText: String
    let isSaving: Bool
    let onSave: (String) -> Void

    @State private var editText: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $editText)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .scrollContentBackground(.hidden)
                .background(Color.black)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }.foregroundColor(.white.opacity(0.6))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: { onSave(editText) }) {
                            if isSaving { ProgressView().tint(.white) }
                            else { Text("Save").font(.system(size: 15, weight: .semibold)).foregroundColor(iconColor) }
                        }
                        .disabled(isSaving)
                    }
                }
        }
        .preferredColorScheme(.dark)
        .onAppear { editText = initialText }
    }
}

#Preview {
    SkillsView()
}
