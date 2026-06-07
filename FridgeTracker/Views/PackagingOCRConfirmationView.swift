import SwiftUI

struct PackagingOCRConfirmationView: View {
    let result: PackagingOCRResult?
    @Binding var name: String
    @Binding var expiryDate: Date
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("识别结果") {
                    TextField("食材名称", text: $name)
                    DatePicker("保质期", selection: $expiryDate, displayedComponents: .date)
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
                    Button("填入表单") { onApply() }
                }
            }
        }
    }
}
