import SwiftUI
import SwiftData
import Vision
import AVFoundation
import UIKit

struct AddFoodView: View {
    let storageZone: StorageZone
    var editItem: FoodItem? = nil
    var template: FoodTemplate? = nil
    var onSave: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FoodItem.createdAt, order: .reverse) private var existingItems: [FoodItem]
    @ObservedObject private var historySuggestionStore = HistorySuggestionStore.shared

    @State private var name: String = ""
    @State private var category: FoodCategory = .other
    @State private var zone: StorageZone = .fridge
    @State private var customIcon: String = ""
    @State private var expiryDate: Date = Date().addingTimeInterval(7 * 24 * 3600)
    @State private var quantity: String = ""
    @State private var notes: String = ""
    @State private var purchaseDate: Date? = nil
    @State private var hasPurchaseDate: Bool = false
    @State private var lastAutoAppliedName: String?
    @State private var selectedRecentTemplateName: String?
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showOCRConfirmation = false
    @State private var ocrResult: PackagingOCRResult?
    @State private var ocrNameCandidate = ""
    @State private var ocrExpiryDate = Date()
    @State private var ocrErrorMessage: String?
    @State private var cachedHistoryTemplates: [FoodTemplate] = []
    @State private var showCameraDeniedAlert = false

    private var isEditing: Bool { editItem != nil }

    private var suggestedTemplates: [FoodTemplate] {
        var templates = historySuggestionStore.applyOverrides(to: cachedHistoryTemplates)
        let existingNames = Set(templates.map(\.normalizedName))
        templates.append(contentsOf: FoodTemplate.common.filter {
            !historySuggestionStore.isHidden($0.normalizedName) && !existingNames.contains($0.normalizedName)
        })
        return Array(templates.prefix(8))
    }

    var body: some View {
        NavigationStack {
            Form {
                recentTemplatesSection
                foodInfoSection
                iconSection
                storageSection
                dateSection
                otherSection
            }
            .navigationTitle(isEditing ? "编辑食材" : "添加食材")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PackagingPhotoPicker { image in
                    recognizeImage(image)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraImagePicker { image in
                    recognizeImage(image)
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showOCRConfirmation) {
                PackagingOCRConfirmationView(
                    result: ocrResult,
                    name: $ocrNameCandidate,
                    expiryDate: $ocrExpiryDate,
                    onApply: applyOCRResult
                )
            }
            .onAppear {
                rebuildHistoryTemplates()
                if let item = editItem {
                    name = item.name
                    category = item.category
                    zone = item.storageZone
                    customIcon = item.customIcon ?? ""
                    expiryDate = item.expiryDate
                    quantity = item.quantity ?? ""
                    notes = item.notes ?? ""
                    if let pd = item.purchaseDate {
                        purchaseDate = pd
                        hasPurchaseDate = true
                    }
                } else if let template {
                    applyTemplate(template)
                    quantity = template.quantity ?? ""
                    notes = template.notes ?? ""
                    purchaseDate = template.purchaseDate
                    hasPurchaseDate = template.purchaseDate != nil
                }
            }
            .onChange(of: existingItems.count) { _, _ in
                rebuildHistoryTemplates()
            }
            .alert("无法使用相机", isPresented: $showCameraDeniedAlert) {
                Button("好", role: .cancel) {}
                Button("前往设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            } message: {
                Text("请在系统设置中允许 FridgeTracker 使用相机后再试，或改用「选包装图」从相册识别。")
            }
        }
    }

    private var recentTemplatesSection: some View {
        Section("最近添加") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestedTemplates, id: \.normalizedName) { template in
                        RecentTemplateChip(
                            template: template,
                            isSelected: isRecentTemplateSelected(template)
                        ) {
                            applyTemplate(template)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Text("点选后自动填入名称、分类、图标和存储区域，只需确认新的保质期。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var foodInfoSection: some View {
        Section("食材信息") {
            Button {
                requestCameraThenScan()
            } label: {
                Label("拍包装识别", systemImage: "camera.viewfinder")
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.medium))

            Button {
                showPhotoPicker = true
            } label: {
                Label("选包装图", systemImage: "photo")
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.medium))

            if let ocrErrorMessage {
                Text(ocrErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("食材名称", text: $name)
                .onChange(of: name) { _, newValue in
                    applyHistoryIfNeeded(for: newValue)
                }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FoodCategory.allCases, id: \.self) { cat in
                        Button {
                            category = cat
                            customIcon = ""
                        } label: {
                            Text("\(cat.icon) \(cat.rawValue)")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(category == cat ? Color.accentColor : Color(.systemGray6))
                                .foregroundColor(category == cat ? .white : .primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var iconSection: some View {
        Section("显示图标") {
            TextField("自定义 Emoji（可选）", text: $customIcon)
            Text("留空时使用当前分类图标：\(category.icon)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var storageSection: some View {
        Section("存储区域") {
            Picker("存储区域", selection: $zone) {
                ForEach(StorageZone.allCases, id: \.self) { z in
                    Text("\(z.icon) \(z.rawValue)").tag(z)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // 「xx 天后过期」入口：默认从今天算，记录购买日期时从购买日算。
    private var baseDateForExpiryDays: Date {
        let base = (hasPurchaseDate ? purchaseDate : nil) ?? Date()
        return Calendar.current.startOfDay(for: base)
    }

    private var expiryDaysBinding: Binding<Int> {
        Binding(
            get: {
                let days = Calendar.current.dateComponents(
                    [.day],
                    from: baseDateForExpiryDays,
                    to: Calendar.current.startOfDay(for: expiryDate)
                ).day ?? 0
                return max(0, days)
            },
            set: { newValue in
                if let newDate = Calendar.current.date(byAdding: .day, value: max(0, newValue), to: baseDateForExpiryDays) {
                    expiryDate = newDate
                }
            }
        )
    }

    private var expiryDaysDescription: String {
        let days = expiryDaysBinding.wrappedValue
        return hasPurchaseDate ? "保质期 \(days) 天" : "还有 \(days) 天过期"
    }

    private var dateSection: some View {
        Section("日期") {
            DatePicker("保质期", selection: $expiryDate, displayedComponents: .date)

            Stepper(value: expiryDaysBinding, in: 0...3650) {
                Text(expiryDaysDescription)
            }

            Toggle("记录购买日期", isOn: $hasPurchaseDate)
            if hasPurchaseDate {
                DatePicker("购买日期", selection: Binding(
                    get: { purchaseDate ?? Date() },
                    set: { purchaseDate = $0 }
                ), displayedComponents: .date)
            }
        }
    }

    private var otherSection: some View {
        Section("其他") {
            TextField("数量（可选）", text: $quantity)
            TextField("备注（可选）", text: $notes)
        }
    }

    private func rebuildHistoryTemplates() {
        cachedHistoryTemplates = FoodTemplate.fromHistory(existingItems)
    }

    private func isRecentTemplateSelected(_ template: FoodTemplate) -> Bool {
        selectedRecentTemplateName == template.normalizedName
    }

    private func applyTemplate(_ template: FoodTemplate) {
        let normalizedName = template.normalizedName
        selectedRecentTemplateName = normalizedName
        lastAutoAppliedName = normalizedName
        name = template.name
        category = template.category
        zone = template.storageZone
        customIcon = template.customIcon ?? ""
        expiryDate = Calendar.current.date(byAdding: .day, value: template.defaultShelfLifeDays, to: Date()) ?? expiryDate
    }

    private func applyHistoryIfNeeded(for input: String) {
        guard !isEditing else { return }

        let trimmedName = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            lastAutoAppliedName = nil
            selectedRecentTemplateName = nil
            return
        }
        if lastAutoAppliedName == trimmedName {
            selectedRecentTemplateName = trimmedName
            return
        }
        guard let template = historySuggestionStore.template(for: trimmedName, from: cachedHistoryTemplates) else {
            lastAutoAppliedName = nil
            selectedRecentTemplateName = nil
            return
        }

        category = template.category
        zone = template.storageZone
        customIcon = template.customIcon ?? ""
        quantity = template.quantity ?? ""
        notes = template.notes ?? ""
        purchaseDate = template.purchaseDate
        hasPurchaseDate = template.purchaseDate != nil
        expiryDate = Calendar.current.date(byAdding: .day, value: template.defaultShelfLifeDays, to: Date()) ?? expiryDate
        lastAutoAppliedName = trimmedName
        selectedRecentTemplateName = trimmedName
    }

    private func requestCameraThenScan() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showCamera = true
                    } else {
                        showCameraDeniedAlert = true
                    }
                }
            }
        default:
            showCameraDeniedAlert = true
        }
    }

    private func recognizeImage(_ image: UIImage) {
        ocrErrorMessage = nil
        guard let cgImage = image.cgImage else {
            ocrErrorMessage = "未能读取包装图片，可继续手动输入。"
            return
        }

        let request = VNRecognizeTextRequest { request, error in
            let lines = (request.results as? [VNRecognizedTextObservation])?.compactMap {
                $0.topCandidates(1).first?.string
            } ?? []
            let parsed = PackagingTextParser.parse(lines: lines)
            DispatchQueue.main.async {
                if let error {
                    ocrErrorMessage = "包装识别失败：\(error.localizedDescription)"
                    return
                }
                ocrResult = parsed
                ocrNameCandidate = parsed.nameCandidates.first ?? ""
                ocrExpiryDate = parsed.expiryDate ?? expiryDate
                showOCRConfirmation = true
            }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
            } catch {
                DispatchQueue.main.async {
                    ocrErrorMessage = "包装识别失败，可继续手动输入。"
                }
            }
        }
    }

    private func applyOCRResult() {
        let trimmedName = ocrNameCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            name = trimmedName
        }
        expiryDate = ocrExpiryDate
        showOCRConfirmation = false
    }

    private func cancel() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let normalizedCustomIcon = customIcon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuantity = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if let item = editItem {
            // Update existing
            item.name = trimmedName
            item.category = category
            item.storageZone = zone
            item.customIcon = normalizedCustomIcon
            item.expiryDate = expiryDate
            item.quantity = normalizedQuantity.isEmpty ? nil : normalizedQuantity
            item.notes = normalizedNotes.isEmpty ? nil : normalizedNotes
            item.purchaseDate = hasPurchaseDate ? purchaseDate : nil

            NotificationManager.shared.cancelNotification(for: item)
            NotificationManager.shared.scheduleNotification(for: item)
        } else if let existingItem = mergeCandidate(
            name: trimmedName,
            category: category,
            zone: zone,
            customIcon: normalizedCustomIcon,
            expiryDate: expiryDate,
            quantity: normalizedQuantity
        ) {
            existingItem.mergeQuantity(from: normalizedQuantity)
            if existingItem.notes?.isEmpty ?? true, !normalizedNotes.isEmpty {
                existingItem.notes = normalizedNotes
            }

            NotificationManager.shared.cancelNotification(for: existingItem)
            NotificationManager.shared.scheduleNotification(for: existingItem)
        } else {
            // Create new
            let item = FoodItem(
                name: trimmedName,
                category: category,
                storageZone: zone,
                customIcon: normalizedCustomIcon,
                purchaseDate: hasPurchaseDate ? purchaseDate : nil,
                expiryDate: expiryDate,
                quantity: normalizedQuantity.isEmpty ? nil : normalizedQuantity,
                notes: normalizedNotes.isEmpty ? nil : normalizedNotes
            )
            modelContext.insert(item)
            NotificationManager.shared.scheduleNotification(for: item)
        }

        WidgetDataStore.refresh(using: modelContext)
        if let onSave {
            onSave()
        } else {
            dismiss()
        }
    }

    private func mergeCandidate(
        name: String,
        category: FoodCategory,
        zone: StorageZone,
        customIcon: String?,
        expiryDate: Date,
        quantity: String
    ) -> FoodItem? {
        guard FoodQuantity.parse(quantity) != nil else { return nil }

        return existingItems.first { item in
            item.name == name &&
                item.category == category &&
                item.storageZone == zone &&
                item.customIcon == customIcon &&
                Calendar.current.isDate(item.expiryDate, inSameDayAs: expiryDate) &&
                FoodQuantity.parse(item.quantity)?.unit == FoodQuantity.parse(quantity)?.unit
        }
    }
}

struct RecentTemplateChip: View {
    let template: FoodTemplate
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(template.icon) \(template.name)")
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? .white : .primary)
                .background {
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color(.systemGray6))
                }
        }
        .buttonStyle(.plain)
    }
}

