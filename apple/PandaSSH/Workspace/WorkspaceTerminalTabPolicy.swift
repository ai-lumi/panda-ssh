// =============================================================================
// WorkspaceTerminalTabPolicy.swift
// =============================================================================
// 文件功能说明：
// 定义终端标签页和 SFTP 标签页的「保留与可见性」策略。
//
// 核心设计思想：当用户打开多个终端或 SFTP 连接时，所有已打开的标签页都必须
// 保留在 SwiftUI 视图树中（不被销毁），这样切换标签时不会断开 SSH shell 连接。
// 但同一时刻只有一个标签页是「可见的」（接收用户输入），其余标签页在后台
// 保持存活但不可见。只有用户主动关闭标签页时，才真正释放连接资源。
// =============================================================================

import Foundation
// 导入 Foundation 框架

/// 终端标签页的保留与可见性规则。
/// 所有已打开终端都必须留在工作区视图树中，避免切换标签时析构其 SSH shell；
/// 只有当前活动终端可见且接收交互。
struct WorkspaceTerminalTabPolicy {
    // 这个结构体负责从所有标签页中筛选出终端类型的标签页，
    // 并确定哪个终端标签页当前可见

    let retainedTabs: [WorkspaceTab]
    // 被保留的终端标签页列表（只包含 kind == .terminal 的标签页）。
    // 这些标签页都留在视图树中，SSH 连接不会断开

    let visibleTabID: UUID?
    // 当前可见（活动）的终端标签页 ID。
    // 为 nil 表示没有终端标签页处于可见状态

    init(tabs: [WorkspaceTab], activeTabID: UUID?) {
        // 初始化方法：从所有标签页中筛选终端标签页，并确定可见标签页
        // 参数 tabs：工作区中所有的标签页（包括终端、SFTP 等类型）
        // 参数 activeTabID：当前用户选中的标签页 ID（可能是终端也可能是 SFTP）

        retainedTabs = tabs.filter { $0.kind == .terminal }
        // 过滤出所有类型为 .terminal 的标签页，
        // $0 是闭包的简写参数，代表数组中的每一个 WorkspaceTab 元素

        visibleTabID = retainedTabs.contains(where: { $0.id == activeTabID }) ? activeTabID : nil
        // 判断当前活动标签页是否在终端标签页列表中：
        // - 如果 activeTabID 对应的标签页确实是终端类型 → 设为可见
        // - 否则（活动标签页是 SFTP 类型或为 nil）→ 没有终端可见，设为 nil
    }

    var retainedTabIDs: [UUID] {
        // 计算属性：返回所有被保留的终端标签页的 ID 列表
        retainedTabs.map(\.id)
        // 使用 keyPath 语法 \.id，等价于 map { $0.id }，
        // 提取每个标签页的 id 属性组成新数组
    }

    func isVisible(_ tabID: UUID) -> Bool {
        // 查询方法：判断指定 ID 的终端标签页是否当前可见
        visibleTabID == tabID
        // 直接比较：如果传入的 tabID 等于可见标签页 ID，返回 true
    }
}

/// SFTP 标签也必须常驻视图树，标签切换只改变可见性；只有实际关闭标签才释放句柄。
struct WorkspaceSftpTabPolicy {
    // 与 WorkspaceTerminalTabPolicy 逻辑完全对称，
    // 只不过筛选的是 .sftp 类型的标签页。
    // SFTP 连接（文件传输会话）同样需要在后台保持存活

    let retainedTabs: [WorkspaceTab]
    // 被保留的 SFTP 标签页列表

    let visibleTabID: UUID?
    // 当前可见的 SFTP 标签页 ID

    init(tabs: [WorkspaceTab], activeTabID: UUID?) {
        // 初始化：从所有标签页中筛选 SFTP 标签页
        retainedTabs = tabs.filter { $0.kind == .sftp }
        // 只保留类型为 .sftp 的标签页

        visibleTabID = retainedTabs.contains(where: { $0.id == activeTabID }) ? activeTabID : nil
        // 如果活动标签页是 SFTP 类型则可见，否则没有 SFTP 标签页可见
    }

    var retainedTabIDs: [UUID] { retainedTabs.map(\.id) }
    // 计算属性：返回所有被保留的 SFTP 标签页 ID 列表

    func isVisible(_ tabID: UUID) -> Bool { visibleTabID == tabID }
    // 查询方法：判断指定 ID 的 SFTP 标签页是否当前可见
}
