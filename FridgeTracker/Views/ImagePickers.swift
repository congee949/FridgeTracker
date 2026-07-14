import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct PackagingPhotoPicker: UIViewControllerRepresentable {
    /// 选中图片回调 UIImage；选了图片但加载失败回调 nil（用户取消则不回调）。
    let onResult: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    init(onResult: @escaping (UIImage?) -> Void) {
        self.onResult = onResult
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult, dismiss: dismiss)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onResult: (UIImage?) -> Void
        let dismiss: DismissAction

        init(onResult: @escaping (UIImage?) -> Void, dismiss: DismissAction) {
            self.onResult = onResult
            self.dismiss = dismiss
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            dismiss()
            guard let provider = results.first?.itemProvider else { return }
            let imageType = UTType.image.identifier
            guard provider.hasItemConformingToTypeIdentifier(imageType) else {
                DispatchQueue.main.async { self.onResult(nil) }
                return
            }

            // NSItemProvider callbacks are Sendable in Swift 6. Move only immutable `Data`
            // between executors, then construct UIKit's non-Sendable UIImage on the main queue.
            provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
                DispatchQueue.main.async {
                    self.onResult(data.flatMap(UIImage.init(data:)))
                }
            }
        }
    }
}

struct CameraImagePicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.modalPresentationStyle = .fullScreen
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
