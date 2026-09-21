// =============================================================================
// WorkspaceEmptyStateRouter.swift
// =============================================================================
// 文件功能说明：
// 定义「工作区空态」的行为路由。当用户没有打开任何主机或页签时，
// 工作区会显示一个空态页面（Empty State），提示用户下一步可以做什么。
// 这个文件定义了空态页面上可选的操作（选主机 / 添加主机），以及这些操作
// 在不同条件下会被路由成什么具体命令（显示主机列表 / 聚焦搜索 / 添加主机）。
// 刻意不提供「直接打开终端」的选项，避免绕过主机详情和连接确认流程。
// =============================================================================

import Foundation
// 导入 Foundation 框架

enum WorkspaceEmptyStateAction: CaseIterable {
    // CaseIterable 协议让枚举的所有 case 可以通过 .allCases 遍历，
    // 方便在 UI 中生成按钮列表

    case chooseHost
    // 用户点击「选择主机」按钮时触发的操作

    case addHost
    // 用户点击「添加主机」按钮时触发的操作
}

/// 空态允许发出的界面命令。这里刻意不提供"打开终端"，避免空态绕过主机详情与
/// 连接前确认流程。
enum WorkspaceEmptyStateCommand: Hashable {
    // Hashable 协议让这个枚举可以作为字典的键或放入 Set 集合中

    case revealHostList
    // 命令：展开/显示主机列表侧栏（当侧栏当前被隐藏时，先让它显示出来）

    case focusHostList
    // 命令：聚焦到主机列表（侧栏已经可见，只需把焦点移过去让用户选择）

    case addHost
    // 命令：打开添加主机的界面（新建连接配置）
}

struct WorkspaceEmptyStateRouter {
    // 路由器结构体：根据用户操作和当前界面状态，决定应该执行哪个命令

    static func command(
        for action: WorkspaceEmptyStateAction,
        // 用户在空态页面上点击了哪个操作按钮
        hostCount: Int,
        // 当前已配置的主机数量
        isSidebarVisible: Bool
        // 侧栏（主机列表）当前是否可见
    ) -> WorkspaceEmptyStateCommand {
        // 返回值：应该执行的具体命令

        switch action {
        // 根据用户点击的操作类型进行分支处理

        case .addHost:
            return .addHost
            // 用户点击「添加主机」→ 直接返回添加主机的命令，无需额外判断

        case .chooseHost:
            // 用户点击「选择主机」→ 需要根据当前状态决定具体行为

            guard hostCount > 0 else { return .addHost }
            // 安全检查：如果主机数量为 0（没有任何已配置的主机），
            // 那么「选择主机」没有意义，退回到「添加主机」命令

            return isSidebarVisible ? .focusHostList : .revealHostList
            // 三元表达式：如果侧栏已经可见，只需聚焦到列表（.focusHostList）；
            // 如果侧栏不可见，需要先展开侧栏（.revealHostList）
        }
    }
}
