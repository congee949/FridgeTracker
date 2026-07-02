import SwiftUI

struct PackagingOCRConfirmationView: View {
    let result: PackagingOCRResult?
    @Binding var name: String
    @Binding var expiryDate: Date
    /// 参数为「是否应用识别到的保质期」：日期异常且用户未确认时只填名称，不写日期。
    let onApply: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var applyExpiryDate = true

    /// 只有真识别到日期才谈「异常识别结果」；未识别时展示的是表单回填值，不该弹误读警告。
    private var dateWasRecognized: Bool {
        result?.expiryDate != nil
    }

    private var dateWarning: String? {
        PackagingDateSanity.warning(for: expiryDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("识别结果") {
                    TextField("食材名称", text: $name)
                    DatePicker("保质期", selection: $expiryDate, displayedComponents: .date)

                    if !dateWasRecognized {
                        Text("未识别到有效期，以上日期为表单当前值，可在此手动修改。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let dateWarning {
                        Label(dateWarning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Toggle("仍然应用这个保质期", isOn: $applyExpiryDate)
                    }
                }

                if let result, !result.nameCandidates.isEmpty {
                    Section("名称候选") {
                        ForEach(result.nameCandidates, id: \.self) { candidate in
                            Button(candidate) {
                                name = candidate
                            }
                        }
                    }
                }

                Section("原始文字") {
                    Text(result?.rawText.isEmpty == false ? result?.rawText ?? "" : "未识别到文字，可返回手动输入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("确认包装识别")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("填入表单") {
                        onApply(PackagingDateSanity.shouldApplyDate(
                            recognized: dateWasRecognized,
                            warning: dateWarning,
                            userConfirmed: applyExpiryDate
                        ))
                    }
                }
            }
            .onAppear {
                // 异常日期默认不应用，避免批号/生产日期被顺手写进保质期
                applyExpiryDate = dateWarning == nil
            }
        }
    }
}
