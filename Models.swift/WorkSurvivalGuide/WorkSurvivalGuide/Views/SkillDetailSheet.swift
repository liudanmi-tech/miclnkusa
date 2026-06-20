//
//  SkillDetailSheet.swift
//  WorkSurvivalGuide
//

import SwiftUI

struct SkillDetailSheet: View {
    let skill: SkillCatalogItem
    let isSelected: Bool
    let onToggle: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var contentVM: SkillNoteResourceViewModel

    init(skill: SkillCatalogItem, isSelected: Bool, onToggle: @escaping () -> Void) {
        self.skill = skill
        self.isSelected = isSelected
        self.onToggle = onToggle
        _contentVM = StateObject(wrappedValue: SkillNoteResourceViewModel(skillId: skill.skillId))
    }

    private var baseColor: Color {
        Color(hex: skill.coverColor ?? "#636e72")
    }

    private var gradientCover: some View {
        LinearGradient(
            colors: [baseColor.opacity(0.85), baseColor.opacity(0.3)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var coverProxyURL: URL? {
        guard let raw = skill.coverImage, !raw.isEmpty else { return nil }
        let filename = raw.hasPrefix("http")
            ? (URL(string: raw)?.lastPathComponent ?? raw)
            : raw.components(separatedBy: "/").last ?? raw
        let base = NetworkManager.shared.getBaseURL()
        return URL(string: "\(base)/skills/covers/\(filename)")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // ── Hero 封面 ──
                    ZStack(alignment: .bottomLeading) {
                        if let proxyURL = coverProxyURL {
                            ZStack {
                                gradientCover
                                SkillCoverImage(url: proxyURL, maxDisplayDimension: 420)
                            }
                            .frame(height: 210)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } else {
                            gradientCover
                                .frame(height: 210)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        if let tagline = skill.proContent?.tagline {
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.55)],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                            Text("「\(tagline)」")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.92))
                                .padding(.horizontal, 16)
                                .padding(.bottom, 14)
                                .shadow(radius: 3)
                        }
                    }
                    .frame(height: 210)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    // ── 技能名称 + 简介 ──
                    VStack(alignment: .leading, spacing: 8) {
                        Text(skill.name)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        if let desc = skill.description, !desc.isEmpty {
                            Text(desc)
                                .font(.system(size: 15, weight: .regular, design: .rounded))
                                .foregroundColor(.white.opacity(0.75))
                                .lineSpacing(5)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                    // ── Note 卡片 ──
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
                    .padding(.top, 24)

                    // ── Resource 卡片 ──
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
                    .padding(.top, 24)

                    if let err = contentVM.errorMessage {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundColor(.red.opacity(0.8))
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }

                    Spacer(minLength: 40)
                }
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) {
                Button(action: { onToggle(); dismiss() }) {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle.fill")
                            .font(.system(size: 18))
                        Text(isSelected ? "Deselect" : "Select Skill")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isSelected ? Color(white: 0.3) : baseColor)
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            .onAppear { contentVM.load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
