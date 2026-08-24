import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

final class WorkspaceEmptyStateRouterTests: XCTestCase {
    func test有主机且侧栏隐藏时选择主机先恢复侧栏() {
        XCTAssertEqual(
            WorkspaceEmptyStateRouter.command(
                for: .chooseHost,
                hostCount: 3,
                isSidebarVisible: false
            ),
            .revealHostList
        )
    }

    func test有主机且侧栏已显示时选择主机聚焦列表() {
        XCTAssertEqual(
            WorkspaceEmptyStateRouter.command(
                for: .chooseHost,
                hostCount: 1,
                isSidebarVisible: true
            ),
            .focusHostList
        )
    }

    func test添加主机始终打开添加表单() {
        for count in [0, 1, 100] {
            XCTAssertEqual(
                WorkspaceEmptyStateRouter.command(
                    for: .addHost,
                    hostCount: count,
                    isSidebarVisible: false
                ),
                .addHost
            )
        }
    }

    func test触发选择期间主机列表变空时安全回退到添加主机() {
        XCTAssertEqual(
            WorkspaceEmptyStateRouter.command(
                for: .chooseHost,
                hostCount: 0,
                isSidebarVisible: true
            ),
            .addHost
        )
    }

    func test负数主机计数按空列表处理() {
        XCTAssertEqual(
            WorkspaceEmptyStateRouter.command(
                for: .chooseHost,
                hostCount: -1,
                isSidebarVisible: false
            ),
            .addHost
        )
    }

    func test空态命令不包含打开终端路径() {
        let allCommands = WorkspaceEmptyStateAction.allCases.map {
            WorkspaceEmptyStateRouter.command(for: $0, hostCount: 1, isSidebarVisible: false)
        }

        XCTAssertEqual(Set(allCommands), [.revealHostList, .addHost])
    }
}
