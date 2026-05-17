//
//  ProfileMemoryView.swift
//  WorkSurvivalGuide
//
//  档案记忆 Sheet — 展示 AI 累积的人际记忆（关系、事件、目标）
//

import SwiftUI

struct ProfileMemoryView: View {
    let profile: Profile
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var memories: ProfileMemoriesResponse?
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            ZStack {
                AppColors.background.ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(AppColors.headerText)
                        Text("加载记忆...")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundColor(AppColors.secondaryText)
                    }
                } else if let errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundColor(.orange)
                        Text(errorMessage)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(AppColors.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("重试") {
                            Task { await loadMemories() }
                        }
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(AppColors.headerText)
                    }
                } else if let mem = memories, mem.total == 0 {
                    VStack(spacing: 16) {
                        Image(systemName: "brain")
                            .font(.system(size: 44))
                            .foregroundColor(AppColors.secondaryText.opacity(0.5))
                        Text("暂无关于\(profile.name)的记忆")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(AppColors.secondaryText)
                        Text("与 AI 对话或分析音频后，记忆会在这里积累。")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(AppColors.secondaryText.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else if let mem = memories {
                    ScrollView {
                        VStack(spacing: 16) {
                            if !mem.relationship.isEmpty {
                                MemorySectionView(
                                    title: "关系概况",
                                    icon: "brain",
                                    iconColor: Color.purple,
                                    items: mem.relationship
                                )
                            }
                            if !mem.events.isEmpty {
                                MemorySectionView(
                                    title: "事件记录",
                                    icon: "calendar",
                                    iconColor: Color.blue,
                                    items: mem.events
                                )
                            }
                            if !mem.goals.isEmpty {
                                MemorySectionView(
                                    title: "目标追踪",
                                    icon: "target",
                                    iconColor: Color.green,
                                    items: mem.goals
                                )
                            }
                            if !mem.skills.isEmpty {
                                MemorySectionView(
                                    title: "应用技能",
                                    icon: "bolt.fill",
                                    iconColor: Color(red: 0.6, green: 0.4, blue: 1.0),
                                    items: mem.skills
                                )
                            }
                            if !mem.other.isEmpty {
                                MemorySectionView(
                                    title: "其他记忆",
                                    icon: "sparkles",
                                    iconColor: Color.orange,
                                    items: mem.other
                                )
                            }
                            Color.clear.frame(height: 24)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }
                }
            }
            .navigationTitle("\(profile.name) 的记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(AppColors.headerText)
                }
            }
        }
        .onAppear {
            Task { await loadMemories() }
        }
    }

    private func loadMemories() async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await NetworkManager.shared.fetchProfileMemories(profileId: profile.id)
            await MainActor.run {
                memories = result
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

// MARK: - Section

private struct MemorySectionView: View {
    let title: String
    let icon: String
    let iconColor: Color
    let items: [ProfileMemoryItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(AppColors.headerText)
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(iconColor)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(iconColor.opacity(0.1))
            .cornerRadius(12)

            // Memory cards
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                MemoryCardView(item: item)
            }
        }
    }
}

// MARK: - Card

private struct MemoryCardView: View {
    let item: ProfileMemoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.content)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(AppColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if let date = item.date, !date.isEmpty {
                    Label(formattedDate(date), systemImage: "calendar")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(AppColors.secondaryText)
                }

                if let status = item.status, !status.isEmpty {
                    statusPill(status)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func formattedDate(_ iso: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: iso) {
            let out = DateFormatter()
            out.dateFormat = "M月d日"
            return out.string(from: date)
        }
        return iso
    }

    @ViewBuilder
    private func statusPill(_ status: String) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case "in_progress": return ("进行中", Color.orange)
            case "completed":   return ("已完成", Color.green)
            case "abandoned":   return ("已放弃", Color.gray)
            default:            return (status, Color.gray)
            }
        }()

        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color)
            .clipShape(Capsule())
    }
}
