//
//  ProfileEditView.swift
//  WorkSurvivalGuide
//
//  档案编辑视图 - 创建/编辑档案
//

import SwiftUI
import PhotosUI
import UIKit
import AVFoundation

// MARK: - UITextField Wrapper
struct UITextFieldWrapper: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommit: (() -> Void)?
    
    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.placeholder = placeholder
        textField.font = UIFont.systemFont(ofSize: 16)
        textField.delegate = context.coordinator
        textField.borderStyle = .roundedRect
        textField.isUserInteractionEnabled = true
        textField.isEnabled = true
        textField.allowsEditingTextAttributes = true
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textFieldDidChange(_:)), for: .editingChanged)
        
        // 确保可以响应触摸
        textField.isMultipleTouchEnabled = false
        textField.isExclusiveTouch = true
        
        return textField
    }
    
    func updateUIView(_ uiView: UITextField, context: Context) {
        // 只在文本真正不同且不是用户正在编辑时更新
        if uiView.text != text && !uiView.isFirstResponder {
            uiView.text = text
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: UITextFieldWrapper
        
        init(_ parent: UITextFieldWrapper) {
            self.parent = parent
        }
        
        @objc func textFieldDidChange(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }
        
        func textFieldDidChangeSelection(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }
        
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onCommit?()
            return true
        }
    }
}

// MARK: - UITextView Wrapper
struct UITextViewWrapper: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = UIFont.systemFont(ofSize: 16)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.layer.borderColor = UIColor.gray.withAlphaComponent(0.3).cgColor
        textView.layer.borderWidth = 1
        textView.layer.cornerRadius = 8
        textView.isEditable = true
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.isUserInteractionEnabled = true
        textView.allowsEditingTextAttributes = true
        
        // 确保可以粘贴
        textView.pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        // 只在文本真正不同且不是用户正在编辑时更新
        if uiView.text != text && !uiView.isFirstResponder {
            uiView.text = text
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UITextViewDelegate {
        var parent: UITextViewWrapper
        
        init(_ parent: UITextViewWrapper) {
            self.parent = parent
        }
        
        func textViewDidChange(_ textView: UITextView) {
            DispatchQueue.main.async {
                self.parent.text = textView.text
            }
        }
        
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            return true
        }
    }
}

struct ProfileEditView: View {
    let profile: Profile?
    @Environment(\.dismiss) var dismiss
    
    @StateObject private var viewModel = ProfileEditViewModel()
    @ObservedObject private var taskListVM = TaskListViewModel.shared
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var showingAudioSelection = false
    @FocusState private var focusedField: Field?
    @State private var nameText: String = ""
    @State private var notesText: String = ""
    @State private var isSaving = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var imageToCrop: UIImage?
    @State private var pendingCroppedImage: UIImage? // 裁剪完成但尚未上传，Save 时统一上传
    @State private var showSelfLimitToast = false
    @State private var showProLimitToast = false
    @State private var showSubscriptionView = false
    @State private var showEmojiTypePicker = false
    @State private var selectedEmojiType: String = "self"
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    
    enum Field {
        case name, notes
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // 照片选择
                    VStack(spacing: 16) {
                        HStack {
                            Text("Profile Photo")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(AppColors.headerText)
                            Text("*")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.red)
                            Spacer()
                        }
                        
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                if let image = selectedImage {
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 120, height: 120)
                                        .clipShape(Circle())
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white, lineWidth: 3)
                                        )
                                } else if let photoUrl = Profile.getAccessiblePhotoURL(photoUrl: viewModel.photoUrl, baseURL: NetworkManager.shared.getBaseURL(), cacheBuster: profile.map { "\(Int($0.updatedAt.timeIntervalSince1970))" }), let url = URL(string: photoUrl) {
                                    RemoteImageView(
                                        url: url,
                                        width: 120,
                                        height: 120
                                    )
                                    .id(photoUrl)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white, lineWidth: 3)
                                    )
                                    .onAppear {
                                        print("📷 [ProfileEditView] RemoteImageView onAppear, photoUrl: \(photoUrl)")
                                    }
                                } else {
                                    ZStack {
                                        Circle()
                                            .fill(Color.gray.opacity(0.2))
                                            .frame(width: 120, height: 120)
                                        
                                        Image(systemName: "camera.fill")
                                            .font(.system(size: 40))
                                            .foregroundColor(AppColors.secondaryText)
                                    }
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white, lineWidth: 3)
                                    )
                                }
                            }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    
                    // 名称输入
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 2) {
                            Text("Name")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(AppColors.headerText)
                            Text("*")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.red)
                        }

                        TextField("Enter name", text: $nameText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 16, design: .rounded))
                            .focused($focusedField, equals: .name)
                            .onChange(of: nameText) { newValue in
                                viewModel.name = newValue
                            }
                    }
                    .padding(.horizontal, 24)
                    
                    // 关系选择
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 2) {
                            Text("Relationship")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(AppColors.headerText)
                            Text("*")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.red)
                        }

                        Picker("Relationship", selection: $viewModel.relationship) {
                            ForEach(RelationshipType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 16, design: .rounded))
                    }
                    .padding(.horizontal, 24)
                    
                    // 备注输入
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Notes")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(AppColors.headerText)
                            Text("Optional")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundColor(AppColors.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.12))
                                .cornerRadius(4)
                        }

                        ZStack(alignment: .topLeading) {
                            // 背景
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                                .frame(minHeight: 100)
                            
                            // 占位符
                            if notesText.isEmpty {
                                Text("Enter notes")
                                    .font(.system(size: 16, design: .rounded))
                                    .foregroundColor(Color.gray.opacity(0.5))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                            
                            // TextEditor
                            TextEditor(text: $notesText)
                                .frame(minHeight: 100)
                                .font(.system(size: 16, design: .rounded))
                                .focused($focusedField, equals: .notes)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                                .onChange(of: notesText) { newValue in
                                    viewModel.notes = newValue
                                }
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    // Audio 入口已隐藏
                    // Voice ID 入口已隐藏

                    // Emoji 风格选择（始终可见）
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Emoji Style")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(AppColors.headerText)
                        Button(action: { showEmojiTypePicker = true }) {
                            HStack {
                                Text(emojiTypeDisplayLabel)
                                    .font(.system(size: 14, design: .rounded))
                                    .foregroundColor(AppColors.primaryText)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14))
                                    .foregroundColor(AppColors.secondaryText)
                            }
                            .padding()
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)

                    // 保存按钮
                    Button(action: {
                        print("💾 [ProfileEditView] 点击保存按钮")
                        // 防止重复点击
                        guard !isSaving else {
                            print("⚠️ [ProfileEditView] 正在保存中，忽略重复点击")
                            return
                        }
                        
                        // Self 人数校验：只允许一个 Self
                        if viewModel.relationship == RelationshipType.self_.rawValue {
                            let existingSelf = ProfileViewModel.shared.profiles.filter {
                                $0.relationship == RelationshipType.self_.rawValue &&
                                $0.id != (profile?.id ?? "")
                            }
                            if !existingSelf.isEmpty {
                                showSelfLimitToast = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                    showSelfLimitToast = false
                                }
                                return
                            }
                        }

                        // 正常保存
                        print("✅ [ProfileEditView] 开始执行保存操作")
                        performSave()
                    }) {
                        HStack {
                            if isSaving {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            }
                            Text(profile == nil ? (isSaving ? "Creating..." : "Create") : (isSaving ? "Saving..." : "Save"))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canSave ? Color.blue : Color.gray.opacity(0.4))

                        .cornerRadius(12)
                    }
                    .disabled(!canSave)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(profile == nil ? "Create Profile" : "Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Save failed", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        focusedField = nil
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .onChange(of: selectedPhoto) { newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            imageToCrop = image
                        }
                    } else {
                        await MainActor.run {
                            errorMessage = "无法加载图片"
                            showError = true
                        }
                    }
                }
            }
            .fullScreenCover(
                isPresented: Binding(
                    get: { imageToCrop != nil },
                    set: { if !$0 { imageToCrop = nil } }
                )
            ) {
                if let img = imageToCrop {
                    ImageCropView(
                        image: img,
                        onCrop: { cropped in
                            imageToCrop = nil
                            selectedImage = cropped          // 本地预览
                            pendingCroppedImage = cropped    // 等待 Save 时上传
                        },
                        onCancel: { imageToCrop = nil }
                    )
                }
            }
            .onAppear {
                print("📝 [ProfileEditView] onAppear, profile: \(profile?.id ?? "nil")")
                if let profile = profile {
                    print("📝 [ProfileEditView] 加载档案数据: \(profile.name)")
                    print("📝 [ProfileEditView] profile.photoUrl: \(profile.photoUrl ?? "nil")")
                    viewModel.loadFromProfile(profile)
                    nameText = viewModel.name
                    notesText = viewModel.notes
                    selectedEmojiType = profile.emojiType
                    print("📝 [ProfileEditView] 数据已加载: name=\(viewModel.name), relationship=\(viewModel.relationship)")
                    print("📝 [ProfileEditView] viewModel.photoUrl: \(viewModel.photoUrl ?? "nil")")
                    if let photoUrl = viewModel.photoUrl {
                        print("📝 [ProfileEditView] 尝试创建URL: \(photoUrl)")
                        if let url = URL(string: photoUrl) {
                            print("📝 [ProfileEditView] URL创建成功: \(url)")
                        } else {
                            print("❌ [ProfileEditView] URL创建失败，photoUrl格式不正确")
                        }
                    }
                } else {
                    print("📝 [ProfileEditView] 创建新档案模式")
                    // 创建新档案时，重置所有字段
                    viewModel.name = ""
                    viewModel.relationship = RelationshipType.self_.rawValue
                    viewModel.notes = ""
                    nameText = ""
                    notesText = ""
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    if showSelfLimitToast {
                        toastLabel(text: "Only one \"Self\" profile can be created.")
                    } else if showProLimitToast {
                        toastLabel(text: "You've reached the profile limit for your subscription.")
                    }
                }
                .padding(.top, 12)
                .animation(.easeInOut(duration: 0.3), value: showSelfLimitToast)
                .animation(.easeInOut(duration: 0.3), value: showProLimitToast)
            }
            .sheet(isPresented: $showSubscriptionView) {
                SubscriptionView()
            }
            .sheet(isPresented: $showEmojiTypePicker) {
                EmojiTypePickerSheet(selectedEmojiType: $selectedEmojiType)
            }
            .sheet(isPresented: $showingAudioSelection) {
                AudioSelectionView(
                    selectedSessionId: $viewModel.audioSessionId,
                    selectedSegmentId: $viewModel.audioSegmentId,
                    selectedStartTime: $viewModel.audioStartTime,
                    selectedEndTime: $viewModel.audioEndTime,
                    selectedAudioUrl: $viewModel.audioUrl,
                    profileId: profile?.id,
                    onSelectionComplete: { sessionId, segmentId, startTime, endTime, audioUrl in
                        viewModel.audioSessionId = sessionId
                        viewModel.audioSegmentId = segmentId
                        viewModel.audioStartTime = startTime
                        viewModel.audioEndTime = endTime
                        viewModel.audioUrl = audioUrl
                    }
                )
            }
        }
    }
    
    @ViewBuilder
    private func toastLabel(text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.82))
            .cornerRadius(10)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var emojiTypeDisplayLabel: String {
        switch selectedEmojiType {
        case "dog": return "🐶  Dog"
        case "cat": return "🐱  Cat"
        default:    return "🪞  Self Portrait"
        }
    }

    private var canSave: Bool {
        let hasPhoto = selectedImage != nil || viewModel.photoUrl != nil
        let hasName = !nameText.trimmingCharacters(in: .whitespaces).isEmpty
        return hasPhoto && hasName && !isSaving
    }

    private func performSave() {
        print("💾 [ProfileEditView] performSave 开始执行")
        print("   viewModel.photoUrl: \(viewModel.photoUrl ?? "nil")")
        
        // 确保同步最新的输入值
        viewModel.name = nameText
        viewModel.notes = notesText
        focusedField = nil
        
        print("💾 [ProfileEditView] 同步后的数据:")
        print("   name: \(viewModel.name)")
        print("   relationship: \(viewModel.relationship)")
        print("   notes: \(viewModel.notes)")
        print("   photoUrl: \(viewModel.photoUrl ?? "nil")")
        
        isSaving = true

        Task {
            do {
                // ── 如果有待上传图片，先上传再保存 ──────────────────────
                if let imageToUpload = pendingCroppedImage {
                    guard let data = imageToUpload.jpegData(compressionQuality: 0.85) else {
                        await MainActor.run {
                            isSaving = false
                            errorMessage = "Failed to process image. Please try a different photo."
                            showError = true
                        }
                        return
                    }
                    print("📤 [ProfileEditView] Save 阶段上传图片 profileId=\(profile?.id ?? "新建")")
                    let url = try await NetworkManager.shared.uploadProfilePhoto(imageData: data, profileId: profile?.id)
                    await MainActor.run {
                        viewModel.photoUrl = url
                        pendingCroppedImage = nil
                        print("✅ [ProfileEditView] 图片上传成功: \(url)")
                    }

                    // Self 档案换头像 → 立即清空 emoji 缓存，并在 30s 后重新拉取（等 Gemini 生成完成）
                    if viewModel.relationship == RelationshipType.self_.rawValue {
                        SelfEmojiURLCache.shared.reset()
                        Task {
                            try? await Task.sleep(nanoseconds: 30_000_000_000)
                            SelfEmojiURLCache.shared.reset()
                            await SelfEmojiURLCache.shared.load()
                        }
                    }
                }

                if let profile = profile {
                    // 更新档案
                    print("💾 [ProfileEditView] 开始更新档案: \(profile.id)")
                    var updatedProfile = profile
                    updatedProfile.name = viewModel.name
                    updatedProfile.relationship = viewModel.relationship
                    updatedProfile.notes = viewModel.notes
                    // 只有在photoUrl不为nil时才更新，避免覆盖原有头像
                    if let photoUrl = viewModel.photoUrl {
                        updatedProfile.photoUrl = photoUrl
                        print("💾 [ProfileEditView] 更新photoUrl: \(photoUrl)")
                    } else {
                        print("⚠️ [ProfileEditView] photoUrl为nil，保留原有头像")
                    }
                    updatedProfile.audioSessionId = viewModel.audioSessionId
                    updatedProfile.audioSegmentId = viewModel.audioSegmentId
                    updatedProfile.audioStartTime = viewModel.audioStartTime
                    updatedProfile.audioEndTime = viewModel.audioEndTime
                    updatedProfile.audioUrl = viewModel.audioUrl
                    updatedProfile.emojiType = selectedEmojiType

                    try await ProfileViewModel.shared.updateProfile(updatedProfile)
                    print("✅ [ProfileEditView] 档案更新成功")
                } else {
                    // 创建档案
                    print("💾 [ProfileEditView] 开始创建档案")
                    let newProfile = Profile(
                        id: UUID().uuidString,
                        name: viewModel.name,
                        relationship: viewModel.relationship,
                        photoUrl: viewModel.photoUrl,
                        notes: viewModel.notes,
                        audioSessionId: viewModel.audioSessionId,
                        audioSegmentId: viewModel.audioSegmentId,
                        audioStartTime: viewModel.audioStartTime,
                        audioEndTime: viewModel.audioEndTime,
                        audioUrl: viewModel.audioUrl,
                        emojiType: selectedEmojiType,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                    print("💾 [ProfileEditView] 创建档案数据:")
                    print("   id: \(newProfile.id)")
                    print("   name: \(newProfile.name)")
                    print("   photoUrl: \(newProfile.photoUrl ?? "nil")")
                    try await ProfileViewModel.shared.createProfile(newProfile)
                    TikTokTracker.track("ClickButton", [
                        "content_id": "create_profile",
                        "content_type": "feature",
                        "relationship_type": viewModel.relationship
                    ])
                    print("✅ [ProfileEditView] 档案创建成功")
                }
                
                await MainActor.run {
                    // 刷新档案列表
                    ProfileViewModel.shared.loadProfiles(forceRefresh: true)
                    isSaving = false
                    print("📝 [ProfileEditView] 准备关闭页面")
                    // 延迟一点关闭，确保状态更新完成
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        print("📝 [ProfileEditView] 执行dismiss()")
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    let nsErr = error as NSError
                    print("❌ [ProfileEditView] 保存失败: code=\(nsErr.code) desc=\(nsErr.localizedDescription)")
                    if nsErr.code == 403 {
                        let detail = nsErr.localizedDescription
                        if detail == "profile_free_limit_reached" {
                            // Free 用户超限 → 弹订阅墙
                            showSubscriptionView = true
                        } else {
                            // Pro 用户超限 → Toast 提示
                            showProLimitToast = true
                        }
                    } else {
                        errorMessage = nsErr.localizedDescription
                        showError = true
                    }
                }
            }
        }
    }
}

// 关系类型枚举
enum RelationshipType: String, CaseIterable {
    case self_ = "Self"
    case partner = "Partner"
    case friend = "Best Friend"
    case casualFriend = "Friend"
    case classmate = "Classmate"
    case colleague = "Colleague"
    case leader = "Manager"
    case subordinate = "Subordinate"
    case teacher = "Teacher"
    case neighbor = "Neighbor"
    case family = "Family"
    case pet = "Pet"
    case other = "Other"
}

// 档案编辑ViewModel
class ProfileEditViewModel: ObservableObject {
    @Published var name: String = ""
    @Published var relationship: String = RelationshipType.self_.rawValue
    @Published var notes: String = ""
    @Published var photoUrl: String?
    @Published var audioSessionId: String?
    @Published var audioSegmentId: String?
    @Published var audioStartTime: Double?
    @Published var audioEndTime: Double?
    @Published var audioUrl: String?
    
    var audioInfo: String? {
        guard let sessionId = audioSessionId,
              let startTime = audioStartTime,
              let endTime = audioEndTime else {
            return nil
        }
        let duration = endTime - startTime
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "对话 \(sessionId.prefix(8))... | \(String(format: "%d:%02d", minutes, seconds))"
    }
    
    func loadFromProfile(_ profile: Profile) {
        name = profile.name
        relationship = profile.relationship
        notes = profile.notes ?? ""
        photoUrl = profile.photoUrl
        audioSessionId = profile.audioSessionId
        audioSegmentId = profile.audioSegmentId
        audioStartTime = profile.audioStartTime
        audioEndTime = profile.audioEndTime
        audioUrl = profile.audioUrl
    }
}

// MARK: - Voiceprint Enrollment

private enum VPEnrollState {
    case idle
    case recording
    case uploading
    case success
    case failed(String)
}

private class VoiceprintEnrollVM: ObservableObject {
    @Published var state: VPEnrollState = .idle
    @Published var elapsed: Double = 0

    let minDuration: Double = 3.0
    let maxDuration: Double = 10.0

    private var profileId: String = ""
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let pcmLock = NSLock()
    private var _pcmBuffer = Data()
    private var elapsedTimer: Timer?

    func startRecording(profileId: String) {
        self.profileId = profileId
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    self?.state = .failed("Microphone permission denied")
                    return
                }
                self?._startImpl()
            }
        }
    }

    private func _startImpl() {
        pcmLock.lock(); _pcmBuffer = Data(); pcmLock.unlock()
        elapsed = 0

        let session = AVAudioSession.sharedInstance()
        do {
            // Must match LiveSessionManager audio chain exactly so ECAPA-TDNN embeddings are compatible
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
            try session.setPreferredSampleRate(16000)
            if let hfpInput = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try session.setPreferredInput(hfpInput)
            }
        } catch {
            state = .failed("Audio session: \(error.localizedDescription)")
            return
        }

        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
        ), let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            state = .failed("Cannot create audio converter")
            return
        }
        self.converter = conv

        inputNode.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            self?._appendPCM(buffer, targetFormat: targetFormat)
        }

        do {
            try eng.start()
        } catch {
            state = .failed("Audio engine: \(error.localizedDescription)")
            return
        }
        self.engine = eng
        state = .recording

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.elapsed += 0.1
            if self.elapsed >= self.maxDuration {
                self.stopAndUpload()
            }
        }
    }

    private func _appendPCM(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let conv = self.converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard frameCount > 0,
              let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

        var consumed = false; var convErr: NSError?
        conv.convert(to: outBuf, error: &convErr) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        guard convErr == nil, outBuf.frameLength > 0, let ptr = outBuf.int16ChannelData else { return }
        let data = Data(bytes: ptr[0], count: Int(outBuf.frameLength) * 2)
        pcmLock.lock(); _pcmBuffer.append(data); pcmLock.unlock()
    }

    func stopAndUpload() {
        _stopCapture()
        state = .uploading
        pcmLock.lock(); let captured = _pcmBuffer; pcmLock.unlock()
        let pid = profileId
        Task {
            do {
                try await NetworkManager.shared.enrollVoiceprintFromPCM(profileId: pid, pcmData: captured)
                await MainActor.run { self.state = .success }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    private func _stopCapture() {
        elapsedTimer?.invalidate(); elapsedTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil; converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private struct VoiceprintEnrollSection: View {
    let profileId: String
    @StateObject private var vm = VoiceprintEnrollVM()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Voice ID")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(AppColors.headerText)
                Text("Optional")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColors.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(4)
            }
            stateView
        }
    }

    @ViewBuilder private var stateView: some View {
        switch vm.state {
        case .idle:
            Button(action: { vm.startRecording(profileId: profileId) }) {
                HStack {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 16))
                        .foregroundColor(AppColors.secondaryText)
                    Text("Record voice for speaker recognition")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(AppColors.secondaryText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.secondaryText)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }

        case .recording:
            HStack {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(String(format: "%.1fs / 10s", vm.elapsed))
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(AppColors.primaryText)
                Spacer()
                Button("Save") { vm.stopAndUpload() }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(vm.elapsed >= vm.minDuration ? Color.blue : Color.blue.opacity(0.35))
                    .cornerRadius(8)
                    .disabled(vm.elapsed < vm.minDuration)
            }
            .padding()
            .background(Color.red.opacity(0.07))
            .cornerRadius(8)

        case .uploading:
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Saving voice ID...")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(AppColors.secondaryText)
            }
            .padding()
            .background(Color.gray.opacity(0.08))
            .cornerRadius(8)

        case .success:
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Voice ID saved")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(.green)
                Spacer()
                Button("Re-record") { vm.state = .idle }
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColors.secondaryText)
            }
            .padding()
            .background(Color.green.opacity(0.07))
            .cornerRadius(8)

        case .failed(let msg):
            HStack {
                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                Text(msg)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.red)
                    .lineLimit(2)
                Spacer()
                Button("Retry") { vm.state = .idle }
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColors.secondaryText)
            }
            .padding()
            .background(Color.red.opacity(0.07))
            .cornerRadius(8)
        }
    }
}
