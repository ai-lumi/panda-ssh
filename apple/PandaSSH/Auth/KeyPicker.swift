import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 私钥选择结果。
struct PickedKey: Equatable {
    /// 可供后续 SSH 连接读取的本地路径。
    let path: String
    /// iPadOS 上从安全作用域拷贝时，原始 bookmark 数据；macOS 为 nil。
    let securityScopedBookmark: Data?
}

/// 私钥文件选择器协议：macOS 用 NSOpenPanel，iPadOS 用 UIDocumentPicker。
protocol KeyPicker {
    /// 异步弹出文件选择器；用户取消时返回 nil。
    func pickPrivateKey() async -> PickedKey?
}

/// 生产环境私钥选择器实现。
final class SystemKeyPicker: KeyPicker {
    static let shared = SystemKeyPicker()

    #if os(macOS)
    func pickPrivateKey() async -> PickedKey? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.title = "选择私钥文件"
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowedContentTypes = [UTType.data, UTType.plainText]
                panel.begin { result in
                    if result == .OK, let url = panel.url {
                        continuation.resume(returning: PickedKey(path: url.path, securityScopedBookmark: nil))
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
    #else
    /// iPadOS 上把安全作用域文件拷贝到 App Group 容器可访问位置，
    /// 避免 bookmark 跨会话失效。
    func pickPrivateKey() async -> PickedKey? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let picker = KeyDocumentPickerViewController(continuation: continuation)
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
/// 包装 UIDocumentPicker 并在安全作用域内读取/拷贝私钥到 App Group 容器。
private final class KeyDocumentPickerViewController: UIDocumentPickerViewController, UIDocumentPickerDelegate {
    private let continuation: CheckedContinuation<PickedKey?, Never>

    init(continuation: CheckedContinuation<PickedKey?, Never>) {
        self.continuation = continuation
        super.init(forOpeningContentTypes: [UTType.data, UTType.plainText], asCopy: true)
        self.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            continuation.resume(returning: nil)
            return
        }
        let picked = copyToAppGroupIfNeeded(url: url)
        continuation.resume(returning: picked)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        continuation.resume(returning: nil)
    }

    private func copyToAppGroupIfNeeded(url: URL) -> PickedKey? {
        guard url.startAccessingSecurityScopedResource() else {
            return PickedKey(path: url.path, securityScopedBookmark: nil)
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else {
            return PickedKey(path: url.path, securityScopedBookmark: nil)
        }
        let keysDir = container.appendingPathComponent("Keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: keysDir, withIntermediateDirectories: true)

        let dest = keysDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return PickedKey(path: dest.path, securityScopedBookmark: nil)
        } catch {
            return PickedKey(path: url.path, securityScopedBookmark: nil)
        }
    }
}

extension UIApplication {
    fileprivate var firstKeyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}
#endif

/// 内存 fake：返回固定路径，用于测试。
final class FakeKeyPicker: KeyPicker {
    var picked: PickedKey?

    init(picked: PickedKey? = nil) {
        self.picked = picked
    }

    func pickPrivateKey() async -> PickedKey? {
        picked
    }
}
