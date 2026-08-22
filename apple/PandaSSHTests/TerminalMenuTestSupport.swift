import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

// MARK: - SpyShellConnection

/// 测试用 Spy：记录每次 `ShellConnection.write` 的字节流，不依赖真实 SSH。
///
/// 现有 `MockShellConnection`（`apple/PandaSSH/Workspace/ShellConnection.swift`）写入即
/// 原样回显、不暴露单次写入断言；本 Spy 暴露 `lastWrite` / `writeCalls` 让菜单动作
/// （粘贴 / 清屏 / 重置等）写入字节流可被精确断言。
/// 跨平台共享：macOS 的 PRIMARY selection 测试与 iPad 的菜单分发测试都用它。
final class SpyShellConnection: ShellConnection {
    private(set) var writeCalls: [Data] = []
    private(set) var resizeCalls: [(cols: UInt64, rows: UInt64)] = []
    private(set) var closeCount: Int = 0
    private var buffer = Data()

    func write(_ data: Data) throws {
        writeCalls.append(data)
        buffer.append(data)
    }

    func read(max: UInt64) throws -> Data {
        let n = min(Int(max), buffer.count)
        let chunk = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(chunk)
    }

    func resize(cols: UInt64, rows: UInt64) throws {
        resizeCalls.append((cols, rows))
    }

    func close() throws {
        closeCount += 1
    }

    /// 最近一次写入的字节流快照（方便菜单动作的「写入内容」校验）。
    var lastWrite: Data? { writeCalls.last }
}

// MARK: - SpyTerminalCoordinator

/// 测试用 Spy：记录 `TerminalMenuActionPerformer.perform` 的调用序列，
/// 不调用真实 `tv.copy` / `tv.paste` / `connection.write`。
///
/// 替代真实 `TerminalCoordinator` 注入到 `PandaIOSTerminalView.menuActionPerformer`，
/// 让 iPad 端菜单分发链路可单测，无需真实 SwiftTerm `TerminalView` 内部状态。
/// 跨平台共享：macOS 的菜单执行测试（§5）也可用。
final class SpyTerminalCoordinator: TerminalMenuActionPerformer {
    private(set) var performCalls: [(item: TerminalMenuItem, hitLink: String?)] = []

    func perform(_ item: TerminalMenuItem, hitLink: String?) {
        performCalls.append((item, hitLink))
    }
}

#if os(macOS)
// MARK: - MacTerminalViewTestHarness

/// macOS 终端视图测试工厂：构造 in-process `PandaTerminalView` 实例，
/// 注入测试上下文与 spy coordinator。
///
/// frame 默认 `CGRect(0, 0, 320, 240)`：保证 `isPointInBounds` 在可见区域内可命中，
/// 边界条件测试（右下角 `(320, 240)` 与负坐标）通过注入边界点验证分支。
enum MacTerminalViewTestHarness {
    /// 默认视图尺寸（与 §4.1 边界点 `(320, 240)` 一致）。
    static let defaultFrame = CGRect(x: 0, y: 0, width: 320, height: 240)

    /// 构造一个 `PandaTerminalView` 实例并注入测试上下文与 spy coordinator。
    /// - Parameters:
    ///   - phase: 终端会话阶段（默认 `.shell`）。
    ///   - selectedText: 当前选中文本（空字符串视同无选中，默认空）。
    ///   - hasClipboardText: 系统剪贴板是否有文本（默认 `true`）。
    ///   - hitLink: 右键命中的链接（默认 `nil`）。
    ///   - coordinator: 注入的 spy coordinator（默认新建一个）。
    /// - Returns: `(view, coordinator)`，coordinator 是注入到 view 的同一个实例，
    ///   便于测试后续断言 `performCalls`。
    static func make(
        phase: TerminalSessionStore.Phase = .shell,
        selectedText: String = "",
        hasClipboardText: Bool = true,
        hitLink: String? = nil,
        coordinator: SpyTerminalCoordinator = SpyTerminalCoordinator()
    ) -> (view: PandaTerminalView, coordinator: SpyTerminalCoordinator) {
        let view = PandaTerminalView(frame: defaultFrame, font: nil)
        view.menuActionPerformer = coordinator
        view.menuContextOverride = TerminalMenuContext(
            phase: phase,
            selectedText: selectedText,
            hasClipboardText: hasClipboardText,
            hitLink: hitLink
        )
        return (view, coordinator)
    }

    /// 默认菜单条目顺序（不含链接条目），方便测试断言 `lastMenuItems` 顺序一致性。
    static let defaultItemOrder: [TerminalMenuItem] = TerminalContextMenuBuilder.defaultOrder
}
#endif

#if os(iOS)
// MARK: - IOSTerminalViewTestHarness

/// iPad 终端视图测试工厂：构造 in-process `PandaIOSTerminalView` 实例，
/// 注入测试上下文与 spy coordinator。
///
/// frame 默认 `CGRect(0, 0, 320, 240)`：保证 `calculateMouseHit` 在可见区域内可命中，
/// 边界条件测试（A.5 / A.6 / B.4 / B.5 / B.6）通过注入边界点验证 `isPointInBounds` 分支。
@MainActor
enum IOSTerminalViewTestHarness {
    /// 默认视图尺寸（与测试文档 §A.5 / §B.5 边界点 `(320, 240)` 一致）。
    static let defaultFrame = CGRect(x: 0, y: 0, width: 320, height: 240)

    /// 构造一个 `PandaIOSTerminalView` 实例并注入测试上下文与 spy coordinator。
    /// - Parameters:
    ///   - phase: 终端会话阶段（默认 `.shell`）。
    ///   - selectedText: 当前选中文本（空字符串视同无选中，默认空）。
    ///   - hasClipboardText: 系统剪贴板是否有文本（默认 `true`）。
    ///   - hitLink: 右键命中的链接（默认 `nil`）。
    ///   - coordinator: 注入的 spy coordinator（默认新建一个）。
    /// - Returns: `(view, coordinator)`，coordinator 是注入到 view 的同一个实例，
    ///   便于测试后续断言 `performCalls`。
    static func make(
        phase: TerminalSessionStore.Phase = .shell,
        selectedText: String = "",
        hasClipboardText: Bool = true,
        hitLink: String? = nil,
        coordinator: SpyTerminalCoordinator = SpyTerminalCoordinator()
    ) -> (view: PandaIOSTerminalView, coordinator: SpyTerminalCoordinator) {
        let view = PandaIOSTerminalView(frame: defaultFrame, font: nil)
        view.menuActionPerformer = coordinator
        view.menuContextOverride = TerminalMenuContext(
            phase: phase,
            selectedText: selectedText,
            hasClipboardText: hasClipboardText,
            hitLink: hitLink
        )
        return (view, coordinator)
    }

    /// 默认菜单条目顺序（不含链接条目），方便测试断言 `lastMenuItems` 顺序一致性。
    static let defaultItemOrder: [TerminalMenuItem] = TerminalContextMenuBuilder.defaultOrder
}
#endif
