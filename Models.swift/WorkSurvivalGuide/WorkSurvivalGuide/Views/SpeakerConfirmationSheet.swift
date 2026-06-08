//
//  SpeakerConfirmationSheet.swift
//  WorkSurvivalGuide
//
//  停止录音后 Step 2 — 说话人档案确认弹窗
//
//  规则（对应架构文档 Section 10.1）：
//    confidence ≥ 0.85  → 自动通过，不展示
//    0.60–0.85（情况 B）→ "说话人X 是 [name] 吗？"  [✓ 是] [修改] [跳过]
//    < 0.60 / 无档案（情况 C）→ "这位说话人是谁？"   [选择档案] [跳过]
//
//  调用方式：
//    .sheet(isPresented: $showSpeakerConfirm) {
//        SpeakerConfirmationSheet(
//            sessionId: sessionId,
//            speakerMappings: endResponse.speaker_mappings ?? [],
//            onCompleted: { showNextStep() }
//        )
//    }
//

import SwiftUI

// MARK: - Main Sheet

struct SpeakerConfirmationSheet: View {

    let sessionId: String
    let speakerMappings: [SpeakerMappingItem]
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var profileVM = ProfileViewModel.shared

    @State private var confirmedLabels: Set<String> = []
    @State private var pickerTarget: SpeakerMappingItem? = nil
    @State private var errorMessage: String?

    // 只展示需要确认的 speakers（confidence < 0.85 或没有 profile）
    private var pendingSpeakers: [SpeakerMappingItem] {
        speakerMappings.filter { item in
            guard let conf = item.confidence else { return true }
            return conf < 0.85
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if pendingSpeakers.isEmpty {
                    allAutoPassedView
                } else {
                    speakerListView
                }
            }
            .navigationTitle("确认说话人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        onCompleted()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            // 确保档案列表已加载
            if profileVM.profiles.isEmpty {
                profileVM.loadProfiles()
            }
        }
        .sheet(isPresented: Binding(
            get: { pickerTarget != nil },
            set: { if !$0 { pickerTarget = nil } }
        )) {
            if let target = pickerTarget {
                ProfilePickerSheet(
                    sessionId: sessionId,
                    speakerLabel: target.speakerLabel,
                    oldProfileId: target.profileId
                ) { _ in
                    confirmedLabels.insert(target.speakerLabel)
                    pickerTarget = nil
                }
            }
        }
    }

    // MARK: - 全部自动通过时的空状态

    private var allAutoPassedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(.green)
            Text("说话人已自动确认")
                .font(.title3)
                .fontWeight(.semibold)
            Text("所有说话人均已高置信度识别")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 需要确认的列表

    private var speakerListView: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("以下说话人需要确认")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)

                ForEach(pendingSpeakers, id: \.speakerLabel) { item in
                    SpeakerConfirmCard(
                        item: item,
                        isConfirmed: confirmedLabels.contains(item.speakerLabel),
                        onConfirm: {
                            // 情况 B：确认系统识别结果
                            guard let pid = item.profileId else { return }
                            Task {
                                do {
                                    try await NetworkManager.shared.confirmSpeaker(
                                        sessionId: sessionId,
                                        speakerLabel: item.speakerLabel,
                                        profileId: pid
                                    )
                                    await MainActor.run { confirmedLabels.insert(item.speakerLabel) }
                                } catch {
                                    await MainActor.run { errorMessage = error.localizedDescription }
                                }
                            }
                        },
                        onModify: {
                            pickerTarget = item
                        },
                        onSkip: {
                            confirmedLabels.insert(item.speakerLabel)
                        }
                    )
                }

                if let msg = errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                Spacer(minLength: 40)
            }
        }
    }
}

// MARK: - 单张确认卡片

private struct SpeakerConfirmCard: View {

    let item: SpeakerMappingItem
    let isConfirmed: Bool
    let onConfirm: () -> Void
    let onModify: () -> Void
    let onSkip: () -> Void

    private var displayLabel: String {
        let letters = ["A", "B", "C", "D", "E"]
        if let suffix = item.speakerLabel.components(separatedBy: "_").last,
           let n = Int(suffix), n >= 1, n - 1 < letters.count {
            return "说话人\(letters[n - 1])"
        }
        return item.speakerLabel
    }

    private var hasProfile: Bool {
        item.profileId != nil && !(item.profileName?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── 标题行 ──────────────────────────────────────────
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isConfirmed ? "checkmark.circle.fill" : "person.circle.fill")
                    .font(.title2)
                    .foregroundColor(isConfirmed ? .green : .blue)

                VStack(alignment: .leading, spacing: 3) {
                    if hasProfile, let name = item.profileName {
                        Text("\(displayLabel) 是 \(name) 吗？")
                            .font(.headline)
                    } else {
                        Text("这位说话人是谁？")
                            .font(.headline)
                    }
                    if let conf = item.confidence {
                        Text("识别置信度 \(Int(conf * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if isConfirmed {
                    Text("已确认")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            // ── 代表性发言 ──────────────────────────────────────
            if !item.sampleTexts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.sampleTexts.prefix(2), id: \.self) { text in
                        Text("「\(text)」")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            // ── 操作按钮（已确认后隐藏）────────────────────────
            if !isConfirmed {
                HStack(spacing: 8) {
                    if hasProfile, let name = item.profileName {
                        // 情况 B：有建议档案
                        Button {
                            onConfirm()
                        } label: {
                            Label("是\(name)", systemImage: "checkmark")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }

                        Button {
                            onModify()
                        } label: {
                            Label("修改", systemImage: "pencil")
                                .font(.subheadline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color(.systemGray5))
                                .foregroundColor(.primary)
                                .cornerRadius(8)
                        }
                    } else {
                        // 情况 C：无档案，需从列表选择
                        Button {
                            onModify()
                        } label: {
                            Label("选择档案", systemImage: "person.badge.plus")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }

                    Button("跳过") { onSkip() }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .padding(.horizontal)
        .opacity(isConfirmed ? 0.65 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isConfirmed)
    }
}

// MARK: - 档案选择器 Sheet

private struct ProfilePickerSheet: View {

    let sessionId: String
    let speakerLabel: String
    let oldProfileId: String?
    let onSelected: (Profile) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var profileVM = ProfileViewModel.shared
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            ZStack {
                List {
                    Section {
                        ForEach(profileVM.profiles) { profile in
                            Button {
                                selectProfile(profile)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.circle.fill")
                                        .font(.title3)
                                        .foregroundColor(.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name)
                                            .foregroundColor(.primary)
                                            .font(.body)
                                        if !profile.relationship.isEmpty {
                                            Text(profile.relationship)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    } header: {
                        Text("选择这位说话人对应的档案")
                    }

                    if let msg = errorMessage {
                        Section {
                            Text(msg)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                }

                if isLoading {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView()
                        .scaleEffect(1.5)
                }
            }
            .navigationTitle("选择档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func selectProfile(_ profile: Profile) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await NetworkManager.shared.updateSpeaker(
                    sessionId: sessionId,
                    speakerLabel: speakerLabel,
                    oldProfileId: oldProfileId,
                    newProfileId: profile.id
                )
                await MainActor.run {
                    isLoading = false
                    onSelected(profile)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
