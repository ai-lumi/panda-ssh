import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 选择本地文件/目录以进行批量上传的结果。
struct PickedLocalFiles: Equatable {
    /// 用户选中的本地绝对路径列表。
    let paths: [String]
}

/// 本地批量文件选择器:macOS 用 NSOpenPanel,iPadOS 用 UIDocumentPicker。
protocol LocalFilePicker {
    /// 异步弹出选择器;用户取消时返回 nil。
    func pickFiles() async -> PickedLocalFiles?
}

/// 生产环境本地文件选择器实现。
final class SystemLocalFilePicker: LocalFilePicker {
    static let shared = SystemLocalFilePicker()

    #if os(macOS)
    func pickFiles() async -> PickedLocalFiles? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.title = "选择要上传的文件或目录"
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = true
                panel.canChooseFiles = true
                panel.allowedContentTypes = [UTType.item]
                panel.begin { result in
                    if result == .OK {
                        continuation.resume(returning: PickedLocalFiles(paths: panel.urls.map(\.path)))
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
    #else
    func pickFiles() async -> PickedLocalFiles? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let picker = LocalDocumentPickerViewController(continuation: continuation)
                guard let root = UIApplication.shared.firstKeyWindow?.rootViewController else {
                    continuation.resume(returning: nil)
                    return
                }
                root.present(picker, animated: true)
            }
        }
    }
    #endif
}

#if os(iOS)
/// 包装 UIDocumentPicker 并在安全作用域内读取选中的文件。
private final class LocalDocumentPickerViewController: UIDocumentPickerViewController, UIDocumentPickerDelegate {
    private let continuation: CheckedContinuation<PickedLocalFiles?, Never>

    init(continuation: CheckedContinuation<PickedLocalFiles?, Never>) {
        self.continuation = continuation
        super.init(forOpeningContentTypes: [UTType.item], asCopy: true)
        self.allowsMultipleSelection = true
        self.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        continuation.resume(returning: PickedLocalFiles(paths: urls.map(\.path)))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        continuation.resume(returning: nil)
    }
}

private extension UIApplication {
    var firstKeyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}
#endif

/// 内存 fake:返回固定路径,用于测试。
final class FakeLocalFilePicker: LocalFilePicker {
    var picked: PickedLocalFiles?

    init(picked: PickedLocalFiles? = nil) {
        self.picked = picked
    }

    func pickFiles() async -> PickedLocalFiles? {
        picked
    }
}
