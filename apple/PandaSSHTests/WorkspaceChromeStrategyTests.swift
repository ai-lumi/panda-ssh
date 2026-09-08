import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class WorkspaceChromeStrategyTests: XCTestCase {
    func test可用且未禁用时默认使用统一chrome() {
        XCTAssertEqual(
            WorkspaceChromeStrategy.resolve(isUnifiedChromeAvailable: true, isExplicitlyDisabled: false),
            .unified
        )
    }

    func test禁用或宿主不可用时回退旧页签栏() {
        XCTAssertEqual(
            WorkspaceChromeStrategy.resolve(isUnifiedChromeAvailable: true, isExplicitlyDisabled: true),
            .legacy
        )
        XCTAssertEqual(
            WorkspaceChromeStrategy.resolve(isUnifiedChromeAvailable: false, isExplicitlyDisabled: false),
            .legacy
        )
    }

    func test反复切换路径不会改变共享工作区壳或活动页签() {
        let first = UUID()
        let second = UUID()
        let shell = WorkspaceShell.resolve(tabIDs: [first, second], activeTabID: second)

        let unified = WorkspaceChromeRoute.resolve(
            shell: shell,
            isUnifiedChromeAvailable: true,
            isExplicitlyDisabled: false
        )
        let legacy = unified.switching(
            isUnifiedChromeAvailable: true,
            isExplicitlyDisabled: true
        )
        let restored = legacy.switching(
            isUnifiedChromeAvailable: true,
            isExplicitlyDisabled: false
        )

        XCTAssertEqual(unified.strategy, .unified)
        XCTAssertEqual(legacy.strategy, .legacy)
        XCTAssertEqual(restored.strategy, .unified)
        XCTAssertEqual(unified.shell, shell)
        XCTAssertEqual(legacy.shell, shell)
        XCTAssertEqual(restored.shell, shell)
    }
}
