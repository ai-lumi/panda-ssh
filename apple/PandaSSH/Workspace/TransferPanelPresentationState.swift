import Foundation

/// 传输面板自身的短生命周期呈现状态。任务数组仍只存在于 `TransferStore`，
/// 所以切换抽屉/inspector/sheet 或关闭面板不会取消、复制任务。
struct TransferPanelPresentationState: Equatable {
    private(set) var isPresented = false
    private(set) var presentation: WorkspaceLayoutPolicy.TransferPresentation = .drawer

    mutating func present(using presentation: WorkspaceLayoutPolicy.TransferPresentation) {
        self.presentation = presentation
        isPresented = true
    }

    mutating func updatePresentation(_ presentation: WorkspaceLayoutPolicy.TransferPresentation) {
        self.presentation = presentation
    }

    mutating func dismiss() {
        isPresented = false
    }

    mutating func toggle(using presentation: WorkspaceLayoutPolicy.TransferPresentation) {
        if isPresented {
            dismiss()
        } else {
            present(using: presentation)
        }
    }
}
