import SwiftUI
import SwiftData
import Vision
import AVFoundation
import UIKit

struct AddFoodView: View {
    let storageZone: StorageZone
    var editItem: FoodItem? = nil
    var template: FoodTemplate? = nil
    /// Runs model-only mutations that must be committed atomically with this food item.
    var prepareSave: (() -> Void)? = nil
    var onSave: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FoodItem.createdAt, order: .reverse) private var existingItems: [FoodItem]
    @Query(sort: \FoodDispositionRecord.createdAt, order: .reverse) private var dispositionRecords: [FoodDispositionRecord]
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
    /// True once the user adjusts the expiry via the date picker or stepper, so typing a known
    /// name afterward no longer overwrites their chosen date (mirrors the quantity/notes guard).
    @State private var hasUserAdjustedExpiry: Bool = false
    @State private var hasUserAdjustedCategory = false
    @State private var hasUserAdjustedZone = false
    @State private var hasUserAdjustedCustomIcon = false
    @State private var hasUserAdjustedQuantity = false
    @State private var hasUserAdjustedNotes = false
    @State private var hasUserAdjustedPurchaseDate = false
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
    @State private var activeOCRRequest: VNRecognizeTextRequest?
    @State private var activeOCRRequestID: UUID?
    @State private var isRecognizingImage = false
    @State private var hasVisibleName = false
    @State private var isNameComposing = false
    @State private var isSubmitting = false
    @State private var activeSaveRequestID: UUID?
    @State private var saveErrorMessage: String?
    @StateObject private var nameInputController = IMETextFieldController()

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
                        .disabled(isSubmitting)
                        .accessibilityIdentifier("addFood.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { requestSave() }
                        .disabled(!hasVisibleName || isSubmitting)
                        .accessibilityIdentifier("addFood.saveButton")
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .sheet(isPresented: $showPhotoPicker) {
                PackagingPhotoPicker { image in
                    if let image {
                        recognizeImage(image)
                    } else {
                        ocrErrorMessage = "未能读取所选图片，可换一张或继续手动输入。"
                    }
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
                    onApply: applyOCRResult(applyExpiryDate:)
                )
            }
            .onAppear {
                rebuildHistoryTemplates()
                if let item = editItem {
                    setNameFromExternalSource(item.name, applyHistory: false)
                    category = item.category
                    zone = item.storageZone
                    customIcon = item.customIcon ?? ""
                    // Civil date keys are authoritative. Reconstruct DatePicker values in the
                    // current timezone so travelling cannot shift a date merely by opening Edit.
                    expiryDate = item.expiryLocalDate.date(in: .current) ?? item.expiryDate
                    quantity = item.quantity ?? ""
                    notes = item.notes ?? ""
                    if let pd = item.purchaseLocalDate?.date(in: .current) ?? item.purchaseDate {
                        purchaseDate = pd
                        hasPurchaseDate = true
                    }
                } else if let template {
                    applyTemplate(template)
                    quantity = template.quantity ?? ""
                    notes = template.notes ?? ""
                } else {
                    zone = storageZone
                }
            }
            .onChange(of: existingItems.count) { _, _ in
                rebuildHistoryTemplates()
            }
            .onChange(of: dispositionRecords.count) { _, _ in
                rebuildHistoryTemplates()
            }
            .onDisappear {
                // IME commit finishes on the next main-loop turn. If a parent removes this view in
                // that interval, invalidate the callback so a form that is no longer visible cannot
                // persist data or complete a replenishment item behind the user's back.
                activeSaveRequestID = nil
                isSubmitting = false
                activeOCRRequest?.cancel()
                activeOCRRequest = nil
                activeOCRRequestID = nil
                isRecognizingImage = false
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
            .alert("无法保存", isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "请检查填写内容后重试。")
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
            .disabled(isRecognizingImage)

            Button {
                showPhotoPicker = true
            } label: {
                Label("选包装图", systemImage: "photo")
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.medium))
            .disabled(isRecognizingImage)

            if isRecognizingImage {
                ProgressView("正在识别包装…")
                    .font(.caption)
            }

            if let ocrErrorMessage {
                Text(ocrErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            IMEAwareTextField(
                text: $name,
                hasVisibleNonWhitespaceText: $hasVisibleName,
                isComposing: $isNameComposing,
                placeholder: "食材名称",
                accessibilityIdentifier: "addFood.nameField",
                controller: nameInputController
            ) { newValue in
                saveErrorMessage = nil
                applyHistoryIfNeeded(for: newValue)
            }
            .frame(minHeight: 44)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FoodCategory.allCases, id: \.self) { cat in
                        Button {
                            category = cat
                            customIcon = ""
                            hasUserAdjustedCategory = true
                            hasUserAdjustedCustomIcon = true
                        } label: {
                            Text("\(cat.icon) \(cat.rawValue)")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(category == cat ? Color.accentColor : Color(.systemGray6))
                                .foregroundColor(category == cat ? Color(.systemBackground) : .primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("addFood.category.\(cat.rawValue)")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var iconSection: some View {
        Section("显示图标") {
            TextField("自定义 Emoji（可选）", text: Binding(
                get: { customIcon },
                set: { customIcon = $0; hasUserAdjustedCustomIcon = true }
            ))
            Text("留空时使用当前分类图标：\(category.icon)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var storageSection: some View {
        Section("存储区域") {
            Picker("存储区域", selection: Binding(
                get: { zone },
                set: { zone = $0; hasUserAdjustedZone = true }
            )) {
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
                hasUserAdjustedExpiry = true
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
            DatePicker("保质期", selection: Binding(
                get: { expiryDate },
                set: { expiryDate = $0; hasUserAdjustedExpiry = true }
            ), displayedComponents: .date)
            .accessibilityIdentifier("addFood.expiryDatePicker")

            Stepper(value: expiryDaysBinding, in: 0...3650) {
                Text(expiryDaysDescription)
            }
            .accessibilityIdentifier("addFood.expiryStepper")

            Toggle("记录购买日期", isOn: Binding(
                get: { hasPurchaseDate },
                set: { enabled in
                    hasUserAdjustedPurchaseDate = true
                    hasPurchaseDate = enabled
                    purchaseDate = enabled
                        ? (purchaseDate ?? Calendar.current.startOfDay(for: Date()))
                        : nil
                }
            ))
            if hasPurchaseDate {
                DatePicker("购买日期", selection: Binding(
                    get: { purchaseDate ?? Date() },
                    set: { purchaseDate = $0; hasUserAdjustedPurchaseDate = true }
                ), displayedComponents: .date)
            }
        }
    }

    private var otherSection: some View {
        Section("其他") {
            TextField("数量（可选）", text: Binding(
                get: { quantity },
                set: { quantity = $0; hasUserAdjustedQuantity = true }
            ))
                .accessibilityIdentifier("addFood.quantityField")
            if let quantityModeHint {
                Text(quantityModeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("备注（可选）", text: Binding(
                get: { notes },
                set: { notes = $0; hasUserAdjustedNotes = true }
            ))
                .accessibilityIdentifier("addFood.notesField")
        }
    }

    /// 数量有两种模式：能解析成「N」或「M/N + 单位」的按份数计数，其余按自由文本仅展示。
    /// 在输入时就把模式说清楚，避免消耗自由文本数量时「整项被移除」显得意外。
    private var quantityModeHint: String? {
        let trimmed = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = FoodQuantity.parse(trimmed) {
            return "按份数计数：\(parsed.displayText)，每次\(category.consumeVerb)掉/扔掉减 1 份"
        }
        return "自由文本数量：仅用于展示，\(category.consumeVerb)掉/扔掉时会一次移除整项"
    }

    private func rebuildHistoryTemplates() {
        cachedHistoryTemplates = FoodTemplate.fromHistory(existingItems, records: dispositionRecords)
    }

    private func isRecentTemplateSelected(_ template: FoodTemplate) -> Bool {
        selectedRecentTemplateName == template.normalizedName
    }

    private func applyTemplate(_ template: FoodTemplate) {
        let normalizedName = template.normalizedName
        selectedRecentTemplateName = normalizedName
        lastAutoAppliedName = normalizedName
        setNameFromExternalSource(template.name, applyHistory: false)
        category = template.category
        zone = template.storageZone
        customIcon = template.customIcon ?? ""
        hasUserAdjustedCategory = false
        hasUserAdjustedZone = false
        hasUserAdjustedCustomIcon = false
        hasUserAdjustedQuantity = false
        hasUserAdjustedNotes = false
        hasUserAdjustedPurchaseDate = false
        if template.purchaseDate != nil {
            // A template records that purchase dates are useful, never the previous lot's date.
            purchaseDate = Calendar.current.startOfDay(for: Date())
            hasPurchaseDate = true
        }
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

        if !hasUserAdjustedCategory { category = template.category }
        if !hasUserAdjustedZone { zone = template.storageZone }
        if !hasUserAdjustedCustomIcon { customIcon = template.customIcon ?? "" }
        // 只填充用户尚未填写的字段，避免输入名称触发的自动套用覆盖已录入内容
        if !hasUserAdjustedQuantity,
           quantity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            quantity = template.quantity ?? ""
        }
        if !hasUserAdjustedNotes,
           notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes = template.notes ?? ""
        }
        if !hasUserAdjustedPurchaseDate, !hasPurchaseDate, template.purchaseDate != nil {
            purchaseDate = Calendar.current.startOfDay(for: Date())
            hasPurchaseDate = true
        }
        // Don't clobber an expiry the user has deliberately set, matching the quantity/notes guard above.
        if !hasUserAdjustedExpiry {
            expiryDate = Calendar.current.date(byAdding: .day, value: template.defaultShelfLifeDays, to: Date()) ?? expiryDate
        }
        lastAutoAppliedName = trimmedName
        selectedRecentTemplateName = trimmedName
    }

    private func requestCameraThenScan() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            ocrErrorMessage = "当前设备不支持相机，可改用「选包装图」从相册识别。"
            return
        }
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
        activeOCRRequest?.cancel()
        ocrErrorMessage = nil
        isRecognizingImage = true
        let requestID = UUID()
        activeOCRRequestID = requestID

        let request = VNRecognizeTextRequest { visionRequest, error in
            let lines = (visionRequest.results as? [VNRecognizedTextObservation])?.compactMap {
                $0.topCandidates(1).first?.string
            } ?? []
            let parsed = PackagingTextParser.parse(lines: lines)
            DispatchQueue.main.async {
                guard activeOCRRequestID == requestID else { return }
                activeOCRRequest = nil
                activeOCRRequestID = nil
                isRecognizingImage = false
                if let error {
                    ocrErrorMessage = "包装识别失败：\(error.localizedDescription)"
                    return
                }
                guard !lines.isEmpty else {
                    ocrErrorMessage = "没有识别到清晰文字，可换一张图片或继续手动输入。"
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
        activeOCRRequest = request
        let sendableRequest = SendableVisionRequest(request)

        // Vision 不需要相机原始的 12MP/48MP 像素。先压到 2048px 长边，限制峰值内存和
        // 识别耗时；UIImage thumbnail 会把方向烘焙进像素，所以后续统一按 `.up` 处理。
        DispatchQueue.global(qos: .userInitiated).async {
            guard let preparedImage = Self.imagePreparedForOCR(image),
                  let cgImage = preparedImage.cgImage else {
                DispatchQueue.main.async {
                    guard activeOCRRequestID == requestID else { return }
                    activeOCRRequest = nil
                    activeOCRRequestID = nil
                    isRecognizingImage = false
                    ocrErrorMessage = "未能读取包装图片，可继续手动输入。"
                }
                return
            }
            do {
                try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([sendableRequest.value])
            } catch {
                DispatchQueue.main.async {
                    guard activeOCRRequestID == requestID else { return }
                    activeOCRRequest = nil
                    activeOCRRequestID = nil
                    isRecognizingImage = false
                    ocrErrorMessage = "包装识别失败，可继续手动输入。"
                }
            }
        }
    }

    nonisolated private static func imagePreparedForOCR(
        _ image: UIImage,
        maximumPixelDimension: CGFloat = 2_048
    ) -> UIImage? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let longestSide = max(pixelWidth, pixelHeight)
        guard longestSide > maximumPixelDimension else {
            // Drawing even a small image normalizes orientation and prevents a sideways Vision input.
            let renderer = UIGraphicsImageRenderer(size: image.size)
            return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        }

        let ratio = maximumPixelDimension / longestSide
        let targetSize = CGSize(
            width: max(1, (pixelWidth * ratio).rounded()),
            height: max(1, (pixelHeight * ratio).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func applyOCRResult(applyExpiryDate: Bool) {
        // 只有 OCR 真识别到日期、或用户在确认页手动改过日期时才写入并立 hasUserAdjustedExpiry 守卫
        //（守卫会挡住名称触发的历史模板保质期自动填充）。识别失败时确认页里的日期只是表单回填值
        //（ocrExpiryDate 以 expiryDate 播种，两者相等即未改动），写回是 no-op，误立守卫反而
        // 让「扫到名称没扫到日期」的常见场景丢失历史保质期。
        let dateIsMeaningful = ocrResult?.expiryDate != nil || ocrExpiryDate != expiryDate
        if applyExpiryDate && dateIsMeaningful {
            hasUserAdjustedExpiry = true
            expiryDate = ocrExpiryDate
        }
        let trimmedName = ocrNameCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            setNameFromExternalSource(trimmedName, applyHistory: true)
        }
        showOCRConfirmation = false
    }

    /// Explicit UI choices replace any in-progress marked text.  Keeping this path separate from
    /// normal typing prevents a stale Pinyin candidate from overwriting a template or OCR result.
    private func setNameFromExternalSource(_ newName: String, applyHistory: Bool) {
        name = newName
        hasVisibleName = !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        isNameComposing = false
        saveErrorMessage = nil
        nameInputController.replaceText(with: newName)
        if applyHistory {
            applyHistoryIfNeeded(for: newName)
        }
    }

    private func cancel() {
        guard !isSubmitting else { return }
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    /// Save must first make the IME's visible candidate authoritative.  The controller completes on
    /// the next main-loop turn, after UIKit has finalized marked text during resignFirstResponder.
    private func requestSave() {
        guard !isSubmitting else { return }
        let requestID = UUID()
        activeSaveRequestID = requestID
        isSubmitting = true
        nameInputController.commitAndResign(fallbackText: name) { finalText in
            guard activeSaveRequestID == requestID else { return }
            name = finalText
            hasVisibleName = !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            isNameComposing = false
            save()
        }
    }

    private func save() {
        defer {
            activeSaveRequestID = nil
            isSubmitting = false
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try FoodTextConstraints.validateFoodInput(
                name: name,
                quantity: quantity,
                notes: notes,
                customIcon: customIcon
            )
        } catch {
            saveErrorMessage = error.localizedDescription
            let validationError = error as? FoodInputValidationError
            hasVisibleName = validationError?.isEmptyValue == true
                ? false
                : !trimmedName.isEmpty
            if validationError?.field == "食材名称" {
                nameInputController.focus()
            }
            return
        }

        if hasPurchaseDate {
            guard let purchaseDate else {
                saveErrorMessage = "请重新选择购买日期。"
                return
            }
            let calendar = Calendar.current
            let purchaseDay = calendar.startOfDay(for: purchaseDate)
            let today = calendar.startOfDay(for: Date())
            let expiryDay = calendar.startOfDay(for: expiryDate)
            guard purchaseDay <= today else {
                saveErrorMessage = "购买日期不能晚于今天。"
                return
            }
            guard purchaseDay <= expiryDay else {
                saveErrorMessage = "购买日期不能晚于保质期。"
                return
            }
        }

        let normalizedCustomIcon = customIcon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuantity = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedItem: FoodItem

        if let item = editItem {
            // Update existing
            item.name = trimmedName
            item.updateCategory(category)
            item.storageZone = zone
            item.customIcon = normalizedCustomIcon
            item.quantity = normalizedQuantity.isEmpty ? nil : normalizedQuantity
            item.notes = normalizedNotes.isEmpty ? nil : normalizedNotes
            item.updateCivilDates(
                purchaseDate: hasPurchaseDate ? purchaseDate : nil,
                expiryDate: expiryDate
            )
            savedItem = item
        } else {
            // Every purchase is its own inventory lot; repeated names never merge implicitly.
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
            savedItem = item
        }

        // Parent-owned model mutations (for example completing a replenishment item) join this one
        // explicit commit.  UI dismissal belongs in onSave, which only runs after commit succeeds.
        prepareSave?()
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            saveErrorMessage = "数据没有保存，请重试。\n\(error.localizedDescription)"
            return
        }

        scheduleAfterEnsuringPermission(
            for: savedItem,
            allowsImmediateFallback: editItem == nil
        )
        WidgetDataStore.refresh(using: modelContext)
        if let onSave {
            onSave()
        } else {
            dismiss()
        }
    }

    /// 先确保通知权限（首次添加时弹系统授权框），授权后再重排该食材的提醒。
    /// 未授权状态下直接 add 通知请求会失败，所以顺序必须是先权限后调度。
    private func scheduleAfterEnsuringPermission(for item: FoodItem, allowsImmediateFallback: Bool) {
        let immediateFallbackItemID = allowsImmediateFallback ? item.uuid : nil
        Task { @MainActor in
            let notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
            if notificationsEnabled {
                _ = await NotificationManager.shared.requestPermission()
            }
            await NotificationManager.shared.reconcile(
                using: modelContext,
                immediateFallbackItemID: immediateFallbackItemID
            )
        }
    }

}

/// Vision requests support cancellation while `perform` is running, but the SDK type has not yet
/// adopted Sendable. This narrow wrapper documents the one cross-queue handoff instead of marking
/// the entire view or callback unsafe.
private final class SendableVisionRequest: @unchecked Sendable {
    let value: VNRecognizeTextRequest

    init(_ value: VNRecognizeTextRequest) {
        self.value = value
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
                .foregroundStyle(isSelected ? Color(.systemBackground) : .primary)
                .background {
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color(.systemGray6))
                }
        }
        .buttonStyle(.plain)
    }
}
