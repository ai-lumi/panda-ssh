// =============================================================================
// SftpSessionStore.swift
// =============================================================================
// 文件功能说明：
// SFTP 文件传输会话的核心状态管理文件。实现了双栏文件浏览器（类似 FileZilla）：
// - 左栏显示本地文件系统，右栏显示远程服务器文件系统
// - 支持文件上传（本地→远程）和下载（远程→本地）
// - 支持单选、多选、范围选择（Shift+点击）、追加选择（Cmd+点击）
// - 支持拖拽传输、批量传输、目录递归传输
// - 传输任务挂在共享的 TransferStore 上，支持进度显示和取消
// - 文件冲突时弹出确认框（覆盖/跳过）
//
// 核心组件：
// 1. FileEntry - 文件条目数据模型
// 2. FilePaneSource - 文件面板数据源协议（本地/远程/演示）
// 3. FilePaneNavigator - 单栏导航器（目录浏览、面包屑、前进后退）
// 4. SftpSessionStore - 主会话管理器（协调双栏、传输、选择、冲突处理）
//
// 设计要点：
// - 所有网络操作在后台线程执行（FFIBackground.run），不阻塞主线程
// - 传输完成后自动刷新受影响的面板（0.3s debounce 合并多次刷新）
// - 选择逻辑支持单选/多选/范围选择，兼容键盘修饰键
// - 目录传输使用单 SSH 连接复用，提高效率
// =============================================================================

import Foundation
// 导入 Foundation 框架，提供基础数据类型（URL、FileManager、Date 等）

import Combine
// 导入 Combine 框架，提供响应式编程支持（@Published、AnyCancellable 等）
// 用于监听传输任务状态变化、面板刷新通知等

// =============================================================================
// MARK: - 文件条目数据模型
// =============================================================================

/// 文件条目(对应原型 LOCAL_FS / remoteFS 的 {name, dir, size, mtime})。
/// 表示文件系统中的一个文件或目录，是文件列表的基本单元。

struct FileEntry: Equatable, Identifiable {
    // Equatable：让两个文件条目可以比较是否相等（用于列表刷新、去重等）
    // Identifiable：让文件条目可以作为 SwiftUI List 的行标识

    let name: String
    // 文件名或目录名（不含路径），如 "document.txt"、"Downloads"

    let isDirectory: Bool
    // 是否为目录。true 表示目录，false 表示文件
    // 目录和文件在 UI 上显示不同的图标，行为也不同（目录可以进入，文件可以打开/传输）

    /// 字节数;目录恒为 0(列表显示「—」)
    let size: UInt64
    // 文件大小（字节数）。使用 UInt64 支持大文件（>4GB）
    // 目录的大小恒为 0，UI 上显示为 "—"（破折号）

    /// 展示用修改时间(格式固定为 yyyy-MM-dd HH:mm)
    let modified: String
    // 文件最后修改时间的字符串表示，格式固定为 "年-月-日 时:分"
    // 例如："2026-08-05 14:30"
    // 使用字符串而非 Date 对象，简化 UI 显示逻辑

    var id: String { name }
    // Identifiable 协议要求的 id 属性。这里用文件名作为 ID
    // 注意：同一目录下文件名唯一，但不同目录可能有同名文件
}

// =============================================================================
// MARK: - 文件面板数据源
// =============================================================================

/// 单栏(本地或远程)目录内容提供者。
/// 这是一个协议（protocol），定义了文件面板数据源必须实现的方法。
/// 本地文件系统、远程 SFTP 服务器、演示数据都实现这个协议，
/// 让 FilePaneNavigator 可以统一处理不同的数据来源。
protocol FilePaneSource: AnyObject {
    // AnyObject：限制只有类（class）可以实现这个协议，结构体不行
    // 这是因为数据源需要持有状态（如 SFTP 连接句柄），需要引用语义

    var root: String { get }
    // 根目录路径。本地可能是 "/Users/username"，远程可能是 "/home/username"
    // 面包屑导航从这里开始显示

    var rootTitle: String { get }
    // 根目录的显示标题。如 "本地"、"远程 — server1"
    // 用于面包屑第一个节点的显示

    /// 列出指定路径下的文件条目;失败时抛出错误由视图展示连接失败。
    func list(path: String) async throws -> [FileEntry]
    // async：异步方法，因为读取目录可能耗时（网络请求、磁盘 IO）
    // throws：可能抛出错误（如网络断开、权限不足）
    // 返回指定路径下的所有文件和目录列表
}

/// 演示数据源:与原型一致的静态本地/远程假文件系统。
/// 用于 SwiftUI Preview 和单元测试，不需要真实的文件系统或网络连接。
/// 数据在初始化时通过字典注入，list() 方法直接从字典查找返回。
final class DemoFilePaneSource: FilePaneSource {
    // final：不允许被继承，保证行为一致
    // class：类（而非结构体），因为要实现 FilePaneSource 协议（要求 AnyObject）

    let root: String
    // 根目录路径，如 "/Users/demo" 或 "/home/demo"

    let rootTitle: String
    // 根目录显示标题，如 "本地" 或 "远程"

    private let fs: [String: [FileEntry]]
    // 模拟的文件系统：字典结构，key 是目录路径，value 是该目录下的文件列表
    // 例如：["/Users/demo": [FileEntry(name: "Documents", ...), ...]]

    init(root: String, fs: [String: [FileEntry]], rootTitle: String) {
        // 初始化方法：注入根路径、模拟文件系统数据、显示标题
        self.root = root
        self.fs = fs
        self.rootTitle = rootTitle
    }

    func list(path: String) async throws -> [FileEntry] {
        // 实现协议方法：列出指定路径下的文件
        fs[path] ?? []
        // 从字典中查找路径对应的文件列表
        // ?? []：如果路径不存在，返回空数组（而非 nil 或报错）
    }
}

/// 本地真实数据源:通过 FileManager 读取当前用户可访问目录。
/// 用于真实场景（非 Mock/Preview），读取本地文件系统。
/// 使用 Apple 的 FileManager API 获取目录内容、文件属性等。
final class LocalFilePaneSource: FilePaneSource {
    let root: String
    // 根目录路径，通常是用户主目录（如 /Users/username）

    let rootTitle = "本地"
    // 固定显示标题为 "本地"，用于面包屑导航

    private let fileManager = FileManager.default
    // Apple 提供的文件系统管理器单例，用于读取目录、获取文件属性等

    init(root: String) {
        self.root = root
    }

    func list(path: String) async throws -> [FileEntry] {
        // 实现协议方法：读取本地指定路径下的文件列表
        let url = URL(fileURLWithPath: path)
        // 将路径字符串转换为 URL 对象（FileManager API 需要 URL）

        let contents = try fileManager.contentsOfDirectory(
            at: url,
            // 要读取的目录 URL
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            // 预加载的文件属性：是否目录、文件大小、修改时间
            // 预加载可以提高性能，避免后续逐个查询
            options: .skipsHiddenFiles
            // 跳过隐藏文件（以 . 开头的文件，如 .bashrc、.git）
        )
        return try contents.map { item in
            // 遍历目录中的每个文件/目录，转换为 FileEntry
            let resourceValues = try item.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ])
            // 获取文件的详细属性信息

            let isDirectory = resourceValues.isDirectory ?? false
            // 是否为目录，默认 false（如果不是目录就是文件）

            let size = isDirectory ? 0 : UInt64(resourceValues.fileSize ?? 0)
            // 目录大小恒为 0；文件大小从属性中读取，转为 UInt64

            let modified = formatFileDate(resourceValues.contentModificationDate)
            // 格式化修改时间为 "yyyy-MM-dd HH:mm" 字符串

            return FileEntry(
                name: item.lastPathComponent,
                // 文件名（不含路径），如 "document.txt"
                isDirectory: isDirectory,
                size: size,
                modified: modified
            )
        }
        .sorted {
            // 对文件列表排序：目录在前，文件在后；同类按文件名排序
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            // 如果两个条目的目录/文件属性不同，目录排在前面
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            // 同类条目按文件名排序（localizedStandardCompare 支持中文等本地化排序规则）
        }
    }
}

/// 远程数据源只携带标签句柄，不保存密码也不隐式建连。
/// 用于真实 SFTP 连接场景，通过 FFI 调用 Rust 侧的 SFTP 会话。
/// 每次 list() 调用都会通过 FFI 读取远程目录，网络往返在后台执行。
final class RemoteFilePaneSource: FilePaneSource {
    let root: String
    // 远程根目录路径，通常是用户的 home 目录（如 /home/username）
    // 通过 SFTP 的 real-path 命令解析得到，不是硬编码的

    let rootTitle: String
    // 远程根目录显示标题，如 "远程 — server1"

    let sessionHandle: UInt64?
    // SFTP 会话句柄（由 Rust 侧返回），用于后续所有 SFTP 操作
    // nil 表示未连接或连接已断开

    init(
        root: String,
        rootTitle: String,
        sessionHandle: UInt64? = nil
    ) {
        self.root = root
        self.rootTitle = rootTitle
        self.sessionHandle = sessionHandle
    }

    func list(path: String) async throws -> [FileEntry] {
        // 实现协议方法：通过 SFTP 读取远程目录
        guard let sessionHandle else { throw PandaError.UnknownSftpHandle(0) }
        // 安全检查：必须有有效的 SFTP 句柄才能读取
        // 没有句柄说明未连接或连接已断开，抛出错误

        let records = try await FFIBackground.run {
            // FFIBackground.run：在后台线程池执行 FFI 调用，不阻塞主线程
            // 网络请求可能耗时（几百毫秒到几秒），必须在后台执行
            try PandaCoreBridge.shared.listSftpSession(handle: sessionHandle, path: path)
            // 调用 Rust 侧的 SFTP 目录列表方法
            // 返回远程目录下的文件和子目录列表
        }
        return records.map { record in
            // 将 Rust 返回的记录转换为 Swift 的 FileEntry
            FileEntry(
                name: record.name,
                // 文件名
                isDirectory: record.isDir,
                // 是否为目录
                size: record.isDir ? 0 : record.size,
                // 目录大小为 0，文件大小从记录中读取
                modified: formatFileDate(record.modified.map { Date(timeIntervalSince1970: Double($0)) })
                // 修改时间：Rust 返回的是 Unix 时间戳（秒），转换为 Date 后格式化
            )
        }
        .sorted {
            // 排序：目录在前，文件在后；同类按文件名排序
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// =============================================================================
// MARK: - 辅助函数
// =============================================================================

private func formatFileDate(_ date: Date?) -> String {
    // 私有辅助函数：将 Date 对象格式化为固定格式的字符串
    // 用于文件列表中的 "修改时间" 列显示
    guard let date else { return "—" }
    // 如果日期为 nil（未知），返回破折号 "—"
    let formatter = DateFormatter()
    // 创建日期格式化器
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    // 设置格式：年-月-日 时:分，如 "2026-08-05 14:30"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    // 使用 POSIX 语言环境，确保格式不受系统设置影响
    // 避免某些语言环境下日期格式变化（如月/日顺序）
    return formatter.string(from: date)
    // 将 Date 转换为字符串
}

// =============================================================================
// MARK: - 演示文件系统
// =============================================================================

/// 演示文件系统:本地为固定假数据(对应原型 LOCAL_FS),
/// 远程按用户名生成 home 目录(对应原型 remoteFS,两层以上)。
/// 用于 SwiftUI Preview 和单元测试，提供静态的模拟文件系统数据。
enum DemoFileSystem {
    // 使用 enum 作为命名空间，不需要实例化
    // 所有属性和方法都是 static 的

    static let localRoot: String = {
        // 本地根目录：用户主目录
        #if os(macOS)
        // macOS 平台：使用 homeDirectoryForCurrentUser
        FileManager.default.homeDirectoryForCurrentUser.path
        // 返回 /Users/username
        #else
        // iPadOS 平台：使用 documentDirectory
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        // 返回 App 的文档目录或主目录
        #endif
    }()
    // 闭包立即执行（IIFE），在类型加载时计算一次

    static let local: [String: [FileEntry]] = {
        // 本地模拟文件系统：字典结构，key 是路径，value 是文件列表
        let modified = { (month: Int, day: Int, hour: Int, minute: Int) in
            // 辅助闭包：生成格式化的时间字符串
            "2026-\(String(format: "%02d", month))-\(String(format: "%02d", day)) \(String(format: "%02d", hour)):\(String(format: "%02d", minute))"
            // 格式："2026-MM-DD HH:mm"，%02d 确保两位数字（如 08 而非 8）
        }
        return [
            // 返回字典：路径 → 文件列表
            localRoot: [
                // 用户主目录下的文件和目录
                FileEntry(name: "Documents", isDirectory: true, size: 0, modified: modified(7, 30, 14, 2)),
                FileEntry(name: "Downloads", isDirectory: true, size: 0, modified: modified(8, 4, 9, 41)),
                FileEntry(name: "deploy.tar.gz", isDirectory: false, size: 18_432_000, modified: modified(8, 3, 22, 15)),
                FileEntry(name: "notes.md", isDirectory: false, size: 4_096, modified: modified(8, 1, 11, 20)),
                FileEntry(name: "id_ed25519.pub", isDirectory: false, size: 102, modified: modified(5, 12, 16, 0)),
            ],
            localRoot + "/Documents": [
                // Documents 子目录
                FileEntry(name: "spec-drafts", isDirectory: true, size: 0, modified: modified(7, 28, 10, 0)),
                FileEntry(name: "roadmap.pdf", isDirectory: false, size: 2_355_200, modified: modified(7, 29, 18, 30)),
                FileEntry(name: "budget.xlsx", isDirectory: false, size: 51_200, modified: modified(6, 15, 9, 0)),
            ],
            localRoot + "/Downloads": [
                // Downloads 子目录
                FileEntry(name: "panda-ssh-v0.1.dmg", isDirectory: false, size: 8_920_000, modified: modified(8, 4, 9, 41)),
                FileEntry(name: "wallpaper.heic", isDirectory: false, size: 3_145_728, modified: modified(8, 2, 20, 5)),
            ],
            localRoot + "/Documents/spec-drafts": [
                // 更深层的子目录
                FileEntry(name: "sftp-spec.md", isDirectory: false, size: 12_288, modified: modified(7, 28, 10, 12)),
            ],
        ]
    }()

    static func remoteRoot(username: String) -> String { "/home/\(username)" }
    // 远程根目录：/home/username（Linux 标准 home 目录路径）

    static func remote(username: String) -> [String: [FileEntry]] {
        // 远程模拟文件系统：根据用户名生成
        let home = remoteRoot(username: username)
        // 获取 home 目录路径
        return [
            // 返回字典：路径 → 文件列表
            home: [
                // 远程 home 目录
                FileEntry(name: "app", isDirectory: true, size: 0, modified: "2026-08-01 03:12"),
                FileEntry(name: "logs", isDirectory: true, size: 0, modified: "2026-08-05 06:00"),
                FileEntry(name: ".bashrc", isDirectory: false, size: 3_526, modified: "2025-11-20 12:00"),
                FileEntry(name: "backup-2026-08-01.sql.gz", isDirectory: false, size: 52_428_800, modified: "2026-08-01 03:30"),
            ],
            "\(home)/app": [
                // app 子目录
                FileEntry(name: "current", isDirectory: true, size: 0, modified: "2026-08-01 03:12"),
                FileEntry(name: "releases", isDirectory: true, size: 0, modified: "2026-07-20 03:12"),
                FileEntry(name: ".env.example", isDirectory: false, size: 512, modified: "2026-06-01 09:00"),
            ],
            "\(home)/app/current": [
                // 更深层的子目录
                FileEntry(name: "server.js", isDirectory: false, size: 20_480, modified: "2026-08-01 03:12"),
                FileEntry(name: "package.json", isDirectory: false, size: 1_024, modified: "2026-07-31 22:00"),
            ],
            "\(home)/logs": [
                // logs 目录
                FileEntry(name: "app.log", isDirectory: false, size: 10_485_760, modified: "2026-08-05 06:00"),
                FileEntry(name: "access.log", isDirectory: false, size: 8_388_608, modified: "2026-08-05 05:58"),
            ],
        ]
    }
}

// =============================================================================
// MARK: - 面包屑导航
// =============================================================================

/// 面包屑一段:标题 + 对应绝对路径。
/// 面包屑导航显示当前所在路径，用户可以点击任意一段快速跳转。
/// 例如：本地 > Documents > spec-drafts
struct Crumb: Equatable {
    let title: String
    // 显示标题，如 "本地"、"Documents"、"spec-drafts"

    let path: String
    // 对应的绝对路径，如 "/Users/username/Documents/spec-drafts"
    // 点击时跳转到这个路径
}

/// 单栏导航展示状态：目录与列表作为同一快照提交，过期请求不影响当前展示。
/// 每个文件面板（本地/远程）都有一个 FilePaneNavigator 实例，负责：
/// - 维护当前目录路径和文件列表
/// - 处理目录跳转（进入子目录、返回上级、跳转到任意路径）
/// - 生成面包屑导航数据
/// - 管理加载状态和错误信息
///
/// 设计要点：
/// - 使用 requestGeneration 防止过期的网络请求覆盖当前显示
/// - 目录和文件列表作为原子快照一起更新，避免显示不一致
/// - @Published 属性变化会自动触发 SwiftUI 视图刷新
@MainActor
final class FilePaneNavigator: ObservableObject {
    // @MainActor：所有属性和方法只能在主线程访问，保证 UI 更新安全
    // ObservableObject：让 SwiftUI 视图可以观察这个对象的变化

    let source: any FilePaneSource
    // 数据源：可以是本地、远程或演示数据源
    // any 关键字表示存在类型（existential type），支持不同的数据源实现

    private struct DirectorySnapshot {
        // 私有结构体：目录快照（路径 + 文件列表）
        // 路径和文件列表一起更新，保证显示一致性
        let path: String
        let entries: [FileEntry]
    }

    @Published private var directory: DirectorySnapshot
    // @Published：属性变化时自动通知观察者（SwiftUI 视图）
    // private set：只能在这个类内部修改，外部只读

    @Published private(set) var lastError: Error? = nil
    // 最后一次错误（如网络断开、权限不足）
    // nil 表示没有错误或上次错误已清除

    @Published private(set) var isLoading = false
    // 是否正在加载目录内容（显示加载指示器）

    private var requestGeneration: UInt64 = 0
    // 请求代数：每次发起新请求时递增
    // 用于防止过期的网络请求覆盖当前显示
    // 例如：用户快速连续点击两个目录，第一个请求可能比第二个晚返回
    // 通过比较 generation，可以丢弃过期的第一个请求结果

    var path: String { directory.path }
    // 当前目录路径（只读计算属性）

    var entries: [FileEntry] { directory.entries }
    // 当前目录下的文件列表（只读计算属性）

    init(source: any FilePaneSource) {
        self.source = source
        let initialPath = (try? sftpDirectoryPath(input: source.root)) ?? source.root
        directory = DirectorySnapshot(path: initialPath, entries: [])
    }

    convenience init(root: String, fs: [String: [FileEntry]], rootTitle: String) {
        self.init(source: DemoFilePaneSource(root: root, fs: fs, rootTitle: rootTitle))
    }

    var root: String { (try? sftpDirectoryPath(input: source.root)) ?? source.root }
    // 根目录路径（经过路径规范化处理）
    // sftpDirectoryPath：规范化路径（如解析 ~ 为用户主目录）
    // 如果规范化失败，使用原始路径

    var rootTitle: String { source.rootTitle }
    // 根目录显示标题（如 "本地"、"远程 — server1"）

    func recordError(_ error: Error) {
        lastError = error
    }

    var canGoUp: Bool { path != root && path != "/" }
    // 是否可以返回上级目录
    // 条件：当前路径不是根目录 且 不是文件系统根目录 "/"
    // 根目录没有上级，不能返回

    /// home 内保持原面包屑，home 外从文件系统根展示当前位置。
    var breadcrumbs: [Crumb] {
        // 计算属性：生成面包屑导航数据
        // 例如：[/Users/username] → [Crumb(title: "本地", path: "/Users/username")]
        // 例如：[/Users/username/Documents] → [Crumb(title: "本地", path: "/Users/username"), Crumb(title: "Documents", path: "/Users/username/Documents")]

        if path == root { return [Crumb(title: rootTitle, path: root)] }
        // 如果当前就在根目录，只返回一个面包屑节点

        let withinRoot = root != "/" && path.hasPrefix(root + "/")
        // 判断当前路径是否在根目录内（而非根目录外的绝对路径）
        // 例如：root = /Users/username，path = /Users/username/Documents → withinRoot = true
        // 例如：root = /Users/username，path = /etc → withinRoot = false

        let base = withinRoot ? root : "/"
        // 面包屑起始基准路径：在根目录内用 root，否则用文件系统根 "/"

        var crumbs = [Crumb(title: withinRoot ? rootTitle : "/", path: base)]
        // 初始化面包屑数组，第一个节点是基准路径

        var acc = base
        // 累积路径：用于构建每一段的绝对路径
        // 例如：base = /Users/username，第一段 "Documents" → acc = /Users/username/Documents

        for segment in path.dropFirst(base.count).split(separator: "/") {
            // 遍历路径的每一段（跳过基准路径部分）
            // 例如：path = /Users/username/Documents/spec-drafts，base = /Users/username
            // dropFirst(base.count) 得到 "/Documents/spec-drafts"
            // split(separator: "/") 得到 ["Documents", "spec-drafts"]

            acc = sftpChildPath(directory: acc, name: String(segment))
            // 累积构建子路径
            // sftpChildPath：安全拼接路径，避免双斜杠等问题

            crumbs.append(Crumb(title: String(segment), path: acc))
            // 添加面包屑节点
        }
        return crumbs
    }

    @discardableResult
    func reload() async -> Bool {
        // 重新加载当前目录（刷新文件列表）
        // @discardableResult：返回值可以忽略（调用方可以不处理返回值）
        // 传输完成的自动刷新不得用旧目录取代正在加载的用户跳转。
        guard !isLoading else { return false }
        // 如果已经在加载中，不重复加载（防止并发请求）
        return await navigate(to: path)
        // 跳转到当前路径（实际上是重新读取当前目录）
    }

    @discardableResult
    func enter(_ name: String) async -> Bool {
        // 进入指定名称的子目录
        guard entries.contains(where: { $0.name == name && $0.isDirectory }) else { return false }
        // 安全检查：确保该条目存在且是目录（不能进入文件）
        return await navigate(to: sftpChildPath(directory: path, name: name))
        // 构建子目录路径并跳转
    }

    @discardableResult
    func goUp() async -> Bool {
        // 返回上级目录
        guard canGoUp else { return false }
        // 安全检查：确保可以返回上级（不在根目录）
        return await navigate(to: (path as NSString).deletingLastPathComponent)
        // 使用 NSString 的路径处理方法获取上级目录路径
        // 例如：/Users/username/Documents → /Users/username
    }

    /// 读取期间保留成功快照，只有最新且未取消的请求能够提交结果或错误。
    @discardableResult
    func navigate(to target: String) async -> Bool {
        // 跳转到指定路径（核心导航方法）
        // 所有导航操作（进入、返回、刷新、点击面包屑）最终都调用这个方法

        requestGeneration &+= 1
        // 递增请求代数（&+= 是溢出加法，防止整数溢出崩溃）
        // 每次发起新请求都会递增，用于标识请求的新旧

        let generation = requestGeneration
        // 保存当前代数，用于后续比较

        isLoading = true
        // 设置加载状态为 true（UI 显示加载指示器）

        defer {
            // defer：无论方法如何退出（正常返回或抛出错误），都会执行
            if generation == requestGeneration { isLoading = false }
            // 只有当前请求仍是最新的，才清除加载状态
            // 如果已有更新的请求，保持加载状态（让新请求负责清除）
        }

        do {
            let resolved = try sftpDirectoryPath(input: target)
            // 规范化目标路径（解析 ~、相对路径等）

            let loaded = try await source.list(path: resolved)
            // 调用数据源的 list 方法读取目录内容
            // await：异步等待结果（可能是网络请求或磁盘 IO）

            guard generation == requestGeneration, !Task.isCancelled else { return false }
            // 检查：1. 当前请求仍是最新的（没有更新的请求）
            //       2. 任务未被取消（用户可能快速切换到其他目录）
            // 任一条件不满足，丢弃结果

            lastError = nil
            // 清除上次错误

            directory = DirectorySnapshot(path: resolved, entries: loaded)
            // 更新目录快照（路径 + 文件列表一起更新，保证一致性）

            return true
        } catch {
            // 捕获错误（网络断开、权限不足等）
            guard generation == requestGeneration, !Task.isCancelled else { return false }
            // 同样检查请求是否仍是最新的

            lastError = error
            // 记录错误（UI 可以显示错误信息）

            return false
        }
    }
}

/// 待处理的文件覆盖确认。
struct PendingConflict: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let sourceSize: UInt64
    let sourceDate: Date?
    let targetSize: UInt64
    let targetDate: Date?
}

// =============================================================================
// MARK: - SFTP 会话管理器
// =============================================================================

/// SFTP 标签会话:本地/远程两个导航器 + 两侧选中项,并把上传/下载
/// 挂到共享的 TransferStore。
///
/// 这是 SFTP 文件传输功能的核心管理类，负责：
/// 1. 管理本地和远程两个文件面板（FilePaneNavigator）
/// 2. 处理文件选择（单选/多选/范围选择）
/// 3. 协调文件上传和下载（挂载到 TransferStore）
/// 4. 处理文件覆盖冲突（弹出确认框）
/// 5. 管理 SFTP 连接（建立/断开）
/// 6. 监听传输完成事件，自动刷新受影响的面板
///
/// 设计要点：
/// - 所有网络操作在后台执行，不阻塞主线程
/// - 传输完成后 0.3s debounce 合并多次刷新
/// - 选择逻辑支持键盘修饰键（Shift 范围选择、Cmd 追加选择）
/// - 目录传输使用单 SSH 连接复用，提高效率
@MainActor
final class SftpSessionStore: ObservableObject {
    // @MainActor：所有属性和方法只能在主线程访问
    // ObservableObject：让 SwiftUI 视图可以观察这个对象的变化

    let host: HostEntry
    // 当前连接的主机信息（地址、端口、用户名等）

    /// 核心会话标识：用于代次跟踪与资源释放。
    let sessionID: String

    let transfers: TransferStore
    // 共享的传输任务管理器（所有 SFTP 标签共用）
    // 上传/下载任务都挂在这个 store 上，UI 统一显示进度

    @Published private(set) var localPane: FilePaneNavigator {
        // 本地文件面板导航器
        // @Published：变化时通知 UI 刷新
        // private set：只能在这个类内部修改
        didSet { observePaneChanges() }
        // didSet：属性被设置后自动调用，重新订阅面板变化通知
    }

    @Published private(set) var remotePane: FilePaneNavigator {
        // 远程文件面板导航器
        didSet { observePaneChanges() }
    }

    // TODO: 以下选择逻辑（selectLocal/Remote、selectRange、anchor、toggleMultiSelect）
    // 应替换为 SwiftUI 原生 `List(selection:)` + `Set<String>` 绑定。
    // 当前 SftpTabView 包含复杂的拖拽框选、Shift/Command 修饰键处理、右键菜单等交互，
    // 与这些选择方法深度耦合，无法在未编译验证的情况下安全移除。
    // 待视图层重构为原生选择后再删除以下属性和方法。

    /// 本地栏选中集合;单选模式下大小为 0 或 1,多选模式下可包含多个条目。
    @Published var selectedLocalSet: Set<String> = []
    // 本地面板选中的文件名集合
    // Set<String>：使用集合而非数组，快速判断某个文件是否被选中
    // 单选模式下集合大小为 0 或 1，多选模式下可以有多个

    /// 远程栏选中集合;单选模式下大小为 0 或 1,多选模式下可包含多个条目。
    @Published var selectedRemoteSet: Set<String> = []
    // 远程面板选中的文件名集合

    /// 兼容旧代码的单选访问:返回集合中的唯一选中项。
    var selectedLocal: String? { selectedLocalSet.first }
    // 计算属性：返回本地选中集合的第一个元素（单选模式下的唯一选中项）
    // 如果集合为空，返回 nil

    var selectedRemote: String? { selectedRemoteSet.first }
    // 计算属性：返回远程选中集合的第一个元素

    /// 本地栏多选模式开关。
    @Published var isLocalMultiSelect: Bool = false
    // 本地面板是否处于多选模式
    // false：单选模式（点击一个文件会取消之前的选中）
    // true：多选模式（点击文件会追加/移除选中）

    /// 远程栏多选模式开关。
    @Published var isRemoteMultiSelect: Bool = false
    // 远程面板是否处于多选模式

    /// 本地栏范围选择锚点：最近一次无 Shift 点击的条目名。
    @Published var localAnchor: String?
    // 范围选择的起始点（锚点）
    // Shift+点击时，从 anchor 到当前点击项之间的所有文件都会被选中
    // 例如：anchor = "file1.txt"，Shift+点击 "file5.txt" → 选中 file1~file5

    /// 远程栏范围选择锚点：最近一次无 Shift 点击的条目名。
    @Published var remoteAnchor: String?
    // 远程面板的范围选择锚点

    /// 当前等待用户决策的覆盖确认;SwiftUI 通过 sheet/alert 展示。
    @Published var pendingConflict: PendingConflict?
    // 单文件传输的覆盖冲突
    // 非 nil 时 UI 弹出确认框（覆盖/跳过）

    /// 批量任务等待覆盖确认的冲突；非 nil 时由视图弹出确认框。
    @Published var batchPendingConflict: PendingConflict?
    // 批量传输的覆盖冲突（目录传输时可能遇到）

    /// 真实连接参数;mock 模式为 nil。
    private var connectionSecrets: (password: String?, passphrase: String?)?
    // 连接凭据（密码和私钥口令）
    // 用于后续传输任务（每个任务都需要凭据来建立 SFTP 连接）
    // mock 模式下为 nil（演示数据不需要真实连接）

    /// 真实 SFTP 标签独占的稳定 FFI 句柄；mock/注入测试为 nil。
    private var sftpHandle: UInt64?
    // SFTP 会话句柄（由 Rust 侧返回）
    // 用于所有 SFTP 操作（列出目录、上传、下载等）
    // nil 表示未连接或连接已断开

    private var connectionGeneration = 0
    // 连接代数：用于防止过期的连接请求覆盖当前连接
    // 类似 requestGeneration，但用于连接管理

    private var connectingTask: Task<(root: String, handle: UInt64?), Error>?
    // 正在进行的连接任务（异步任务）
    // 如果已有连接任务在进行，复用该任务而非创建新任务

    var sessionOpener: @Sendable (String, String?, String?, String, UInt32) throws -> SftpSessionRecord = {
        // 会话开启器：调用 Rust FFI 建立带代次校验的 SFTP 连接
        // @Sendable：可以在多线程环境安全传递
        // 参数：(hostID, password, passphrase, sessionID, generation)
        // 返回：SftpSessionRecord（包含 home 目录路径和句柄）
        try PandaCoreBridge.shared.trackedSftpSessionOpen(hostID: $0, password: $1, passphrase: $2, trustOnFirstUse: false, sessionID: $3, generation: $4)
    }

    var sessionCloser: @Sendable (UInt64) throws -> Void = {
        // 会话关闭器：调用 Rust FFI 关闭 SFTP 连接
        // 参数：SFTP 句柄
        try PandaCoreBridge.shared.closeSftpSession(handle: $0)
    }

    /// 页签操作请求重新连接；实际门控与建连仍由 `SftpTabView` 负责。
    var onReconnectRequested: (() -> Void)?
    // 重连请求回调：当用户点击"重新连接"按钮时调用
    // 实际的连接逻辑由 SftpTabView 视图层负责

    /// 冲突弹窗选择后需要继续的传输上下文。
    private var conflictContext: (
        direction: TransferDirection,
        name: String,
        size: UInt64,
        source: String,
        destination: String
    )?
    // 覆盖冲突的上下文信息（用户选择覆盖后继续传输）
    // direction：上传还是下载
    // name：文件名
    // size：文件大小
    // source：源路径
    // destination：目标路径

    /// 已自动刷新过的完成任务 id,避免重复刷新。
    private var refreshedTaskIDs: Set<UUID> = []
    // 已经触发过面板刷新的传输任务 ID 集合
    // 防止同一个任务完成事件多次触发刷新

    /// 测试注入点:覆盖本地目录扫描行为。
    var scanLocalHandler: (([String], String) throws -> [BatchItemRecord])?
    // 测试注入点：覆盖本地目录递归扫描行为
    // 单元测试可以注入自定义实现，验证扫描逻辑

    /// 测试注入点:覆盖远程目录扫描行为。
    var scanRemoteHandler: (([String], String) throws -> [BatchItemRecord])?
    // 测试注入点：覆盖远程目录递归扫描行为


    /// 测试注入点:直接设置连接凭据,避免走真实连接流程。
    func setConnectionSecrets(password: String?, passphrase: String?) {
        connectionSecrets = (password, passphrase)
    }

    /// 测试注入点:覆盖核心编排入口(聚合+入队)。
    var orchestrationHandler: (([String], [TaskItemRecord], TransferDirection, String, String, String?, String?) throws -> OrchestrationResultRecord)?

    /// 测试注入点:覆盖远程文件删除行为。参数为 (name, isDirectory),返回 nil 表示成功。
    var deleteRemoteHandler: ((String, Bool) -> String?)?
    // 测试注入点：覆盖远程文件删除行为
    // 参数：(文件名, 是否目录)
    // 返回：nil 表示成功，否则返回错误描述

    /// 测试注入点:覆盖 home 目录解析行为。参数为 (hostID, password, passphrase)。
    /// 默认为 nil 走真实 FFI;注入后验证后台调度与回退语义。
    var homeDirResolver: (@Sendable (String, String?, String?) throws -> String)?
    // 测试注入点：覆盖 home 目录解析行为
    // 用于测试非标准 home 路径的服务器

    /// 待刷新面板标记;完成事件通过 debounce 合并,避免目录传输产生大量文件时频繁刷新。
    private var pendingReload: (local: Bool, remote: Bool) = (false, false)
    // 待刷新的面板标记（本地/远程）
    // 传输完成后设置标记，通过 debounce 合并多次刷新

    private var reloadWorkItem: DispatchWorkItem?
    // debounce 工作项：0.3 秒后执行刷新

    private var cancellables = Set<AnyCancellable>()
    // Combine 订阅集合：用于管理响应式订阅的生命周期

    private var paneSubscriptions = Set<AnyCancellable>()
    // 面板变化订阅集合

    init(host: HostEntry, transfers: TransferStore) {
        // 初始化方法：创建 SFTP 会话管理器
        // 参数：host - 要连接的主机信息，transfers - 共享的传输管理器

        self.host = host
        self.sessionID = "sftp-\(host.id)-\(UUID().uuidString)"
        self.transfers = transfers

        localPane = FilePaneNavigator(source: LocalFilePaneSource(root: DemoFileSystem.localRoot))
        // 初始化本地面板：使用真实本地文件系统数据源
        // DemoFileSystem.localRoot：用户主目录（/Users/username）

        remotePane = FilePaneNavigator(
            source: DemoFilePaneSource(
                // 初始化远程面板：使用演示数据源（未连接时）
                root: DemoFileSystem.remoteRoot(username: host.username),
                // 远程根目录：/home/username
                fs: DemoFileSystem.remote(username: host.username),
                // 演示文件系统数据
                rootTitle: "远程"
            )
        )

        observePaneChanges()
        // 订阅面板变化通知（面板刷新时通知 UI）

        observeCompletedTransfers()
        // 订阅传输完成事件（自动刷新受影响的面板）
    }

    /// 外层视图观察会话；将子面板刷新通知转发，替换数据源时释放旧订阅。
    private func observePaneChanges() {
        // 订阅本地和远程面板的变化通知
        // 当面板刷新（目录切换、文件列表更新）时，通知 UI 刷新
        paneSubscriptions.removeAll()
        // 清除旧的订阅（防止重复订阅）

        for pane in [localPane, remotePane] {
            // 遍历两个面板
            pane.objectWillChange.sink { [weak self] _ in
                // objectWillChange：ObservableObject 协议提供的发布者
                // 当 @Published 属性变化时触发
                // [weak self]：弱引用 self，防止循环引用
                self?.objectWillChange.send()
                // 转发通知：面板变化时，SftpSessionStore 也通知 UI
            }.store(in: &paneSubscriptions)
            // 将订阅存储到集合中（管理生命周期）
        }
    }

    /// 监听传输任务完成,自动刷新受影响的面板。
    /// 通过 0.3s debounce 合并多个同时完成的文件任务,避免目录传输时反复刷新。
    private func observeCompletedTransfers() {
        // 监听传输任务完成事件，自动刷新受影响的面板
        // 例如：上传文件到远程 /home/user/docs 完成后，自动刷新远程面板
        transfers.$tasks
        // $tasks：TransferStore 的 @Published 属性发布者
        // 每当任务列表变化时触发
            .receive(on: DispatchQueue.main)
            // 确保在主线程处理（UI 更新需要主线程）
            .sink { [weak self] tasks in
                // 处理任务列表变化
                guard let self else { return }
                // 弱引用检查：如果 self 已释放，直接返回

                self.observeBatchConflicts(in: tasks)
                // 检查批量传输的覆盖冲突

                var needsLocal = false
                var needsRemote = false
                // 标记是否需要刷新本地/远程面板

                for task in tasks where task.status == .done && !self.refreshedTaskIDs.contains(task.id) {
                    // 遍历所有已完成且未触发过刷新的任务
                    self.refreshedTaskIDs.insert(task.id)
                    // 记录已刷新的任务 ID（防止重复刷新）

                    switch task.direction {
                    case .upload:
                        // 上传任务：本地 → 远程
                        if task.destination.hasPrefix(self.remotePane.path) { needsRemote = true }
                        // 如果上传目标路径在远程面板当前目录下，需要刷新远程面板
                    case .download:
                        // 下载任务：远程 → 本地
                        if task.destination.hasPrefix(self.localPane.path) { needsLocal = true }
                        // 如果下载目标路径在本地面板当前目录下，需要刷新本地面板
                    }
                }

                if needsLocal { self.pendingReload.local = true }
                if needsRemote { self.pendingReload.remote = true }
                // 设置待刷新标记

                // 清理已不在任务列表中的旧 ID，避免无限增长
                let liveIDs = Set(tasks.map(\.id))
                self.refreshedTaskIDs = self.refreshedTaskIDs.intersection(liveIDs)
                // 只保留仍在任务列表中的 ID

                self.schedulePendingReload()
                // 调度 debounce 刷新
            }
            .store(in: &cancellables)
        // 存储订阅（管理生命周期）
    }

    /// 批量任务进入 WaitingForConflict 时，把冲突信息暴露给视图弹确认框。
    /// 冲突信息由 Rust 侧在决策后清空，此处仅在变化时更新。
    private func observeBatchConflicts(in tasks: [TransferTask]) {
        let conflict = tasks.first(where: { $0.isBatch && $0.pendingConflict != nil })?.pendingConflict
        if conflict != batchPendingConflict {
            batchPendingConflict = conflict
        }
    }

    /// 回传批量冲突决策到 Rust，并清除本地等待状态。
    func resolveBatchConflict(overwrite: Bool) {
        guard let conflict = batchPendingConflict else { return }
        batchPendingConflict = nil
        // 定位发起该冲突的批量任务 id：通过冲突的源/目标路径匹配当前任务列表。
        guard let task = transfers.tasks.first(where: { $0.isBatch && $0.pendingConflict == conflict }) else { return }
        _ = try? PandaCoreBridge.shared.resolveBatchConflict(
            taskID: task.id.uuidString,
            overwrite: overwrite
        )
    }

    /// 0.3s debounce：多次完成事件合并为一次面板刷新。
    private func schedulePendingReload() {
        guard pendingReload.local || pendingReload.remote else { return }
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if self.pendingReload.local {
                    self.pendingReload.local = false
                    _ = await self.localPane.reload()
                }
                if self.pendingReload.remote {
                    self.pendingReload.remote = false
                    _ = await self.remotePane.reload()
                }
            }
        }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// 用真实后端初始化远程面板；调用前需先通过连接门控取得密码/口令。
    /// 通过 `sftp_home_dir` 解析服务器实际 home 目录,避免硬编码 `/home/<username>`
    /// 在非标准 home 路径的服务器上失效。
    /// 返回连接初始化错误；调用方必须据此区分超时、认证失败和缺凭据。
    func connect(password: String?, passphrase: String?) async -> Error? {
        if sftpHandle != nil { return nil }
        let generation = connectionGeneration
        connectionSecrets = (password, passphrase)
        let task: Task<(root: String, handle: UInt64?), Error>
        if let pending = connectingTask {
            task = pending
        } else {
            task = Task { try await self.openSession(password: password, passphrase: passphrase) }
            connectingTask = task
        }
        let connection: (root: String, handle: UInt64?)
        do {
            connection = try await task.value
        } catch {
            let stale = PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: UInt32(generation))
            guard !stale else { return PandaError.Cancelled }
            connectingTask = nil
            connectionSecrets = nil
            Logger.shared.error("SFTP 连接失败 host=\(host.address):\(host.port)", module: LogModule.sftp)
            return error
        }
        let stale = PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: UInt32(generation))
        if stale {
            if let handle = connection.handle { closeHandle(handle) }
            return PandaError.Cancelled
        }
        connectingTask = nil
        if sftpHandle != nil { return nil }
        remotePane = FilePaneNavigator(
            source: RemoteFilePaneSource(
                root: connection.root,
                rootTitle: "远程 — \(host.name)",
                sessionHandle: connection.handle
            )
        )
        sftpHandle = connection.handle
        Logger.shared.info("SFTP 已连接 host=\(host.address):\(host.port)", module: LogModule.sftp)
        return nil
    }

    private func openSession(password: String?, passphrase: String?) async throws -> (root: String, handle: UInt64?) {
        let hostID = host.id
        let resolver = homeDirResolver
        let opener = sessionOpener
        let sid = sessionID
        let gen = UInt32(connectionGeneration)
        // 完整握手（SSH + SFTP + home 解析）在后台线程执行，不阻塞主线程；
        // 多标签连接并行握手（tokio 多线程 runtime 并发 block_on）。
        return try await FFIBackground.run { () -> (String, UInt64?) in
            if let resolver {
                return (try resolver(hostID, password, passphrase), nil)
            }
            let session = try opener(hostID, password, passphrase, sid, gen)
            return (session.homeDir, session.handle)
        }
    }

    /// 切回演示模式(便于测试与 Preview)。
    func useDemoSource() {
        localPane = FilePaneNavigator(
            source: DemoFilePaneSource(
                root: DemoFileSystem.localRoot,
                fs: DemoFileSystem.local,
                rootTitle: "本地"
            )
        )
        remotePane = FilePaneNavigator(
            source: DemoFilePaneSource(
                root: DemoFileSystem.remoteRoot(username: host.username),
                fs: DemoFileSystem.remote(username: host.username),
                rootTitle: "远程"
            )
        )
        selectedLocalSet.removeAll()
        selectedRemoteSet.removeAll()
        localAnchor = nil
        remoteAnchor = nil
    }

    /// 仅转发页签操作，不在内容区自行建立连接或保存凭据。
    func requestReconnect() {
        onReconnectRequested?()
    }

    var localPath: String { localPane.path }
    var remotePath: String { remotePane.path }

    // MARK: - 本地栏操作

    /// 单选模式下替换为单个选中项;多选模式下追加/移除该项。
    /// 无修饰键或 ⌘ 键点击后，被点击条目成为范围选择锚点。
    func selectLocal(_ name: String, append: Bool = false) {
        if append {
            if selectedLocalSet.contains(name) {
                selectedLocalSet.remove(name)
            } else {
                selectedLocalSet.insert(name)
            }
        } else {
            selectedLocalSet = [name]
        }
        localAnchor = name
    }
    func enterLocal(_ name: String) async {
        if await localPane.enter(name) {
            selectedLocalSet.removeAll()
            localAnchor = nil
        }
    }
    func goUpLocal() async {
        if await localPane.goUp() {
            selectedLocalSet.removeAll()
            localAnchor = nil
        }
    }
    /// 跳转到任意绝对路径;成功时清空选中并返回 true,失败返回 false(item 7)。
    @discardableResult
    func navigateLocal(to path: String) async -> Bool {
        let ok = await localPane.navigate(to: path)
        if ok {
            selectedLocalSet.removeAll()
            localAnchor = nil
        }
        return ok
    }

    /// 选中从 anchor 到 target 的闭区间范围，替换当前选中集合并开启多选模式。
    /// 若 anchor 不在当前条目列表中，则回退为单选 target 并将其设为 anchor。
    func selectLocalRange(from anchor: String, to target: String) {
        applyLocalRange(from: anchor, to: target, append: false)
    }

    /// 将 anchor 到 target 的闭区间范围追加到当前选中集合，保持多选模式开启。
    func appendLocalRange(from anchor: String, to target: String) {
        applyLocalRange(from: anchor, to: target, append: true)
    }

    private func applyLocalRange(from anchor: String, to target: String, append: Bool) {
        let entries = localPane.entries
        guard !entries.isEmpty else { return }
        guard let anchorIndex = entries.firstIndex(where: { $0.name == anchor }),
              let targetIndex = entries.firstIndex(where: { $0.name == target }) else {
            selectedLocalSet = [target]
            localAnchor = target
            isLocalMultiSelect = true
            return
        }
        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        let names = Set(entries[range].map(\.name))
        if append {
            selectedLocalSet.formUnion(names)
        } else {
            selectedLocalSet = names
        }
        isLocalMultiSelect = true
    }

    /// 双击本地条目:目录 → 进入;文件 → 选中并加入上传队列(item 6)。
    @discardableResult
    func doubleClickLocal(entry: FileEntry) async -> TransferTask? {
        if entry.isDirectory {
            await enterLocal(entry.name)
            return nil
        }
        selectLocal(entry.name)
        return await uploadSelected()
    }

    /// 右键菜单「上传」action:若条目已在选中集合 → 上传整个集合;
    /// 否则先置为唯一选中再上传(item 5)。
    @discardableResult
    func contextUpload(entry: FileEntry) async -> TransferTask? {
        if !selectedLocalSet.contains(entry.name) {
            selectLocal(entry.name, append: false)
        }
        return await uploadSelected()
    }

    // MARK: - 远程栏操作

    /// 单选模式下替换为单个选中项;多选模式下追加/移除该项。
    /// 无修饰键或 ⌘ 键点击后，被点击条目成为范围选择锚点。
    func selectRemote(_ name: String, append: Bool = false) {
        if append {
            if selectedRemoteSet.contains(name) {
                selectedRemoteSet.remove(name)
            } else {
                selectedRemoteSet.insert(name)
            }
        } else {
            selectedRemoteSet = [name]
        }
        remoteAnchor = name
    }
    func enterRemote(_ name: String) async {
        if await remotePane.enter(name) {
            selectedRemoteSet.removeAll()
            remoteAnchor = nil
        }
    }
    func goUpRemote() async {
        if await remotePane.goUp() {
            selectedRemoteSet.removeAll()
            remoteAnchor = nil
        }
    }
    /// 跳转到任意绝对路径;成功时清空选中并返回 true,失败返回 false(item 7)。
    @discardableResult
    func navigateRemote(to path: String) async -> Bool {
        let ok = await remotePane.navigate(to: path)
        if ok {
            selectedRemoteSet.removeAll()
            remoteAnchor = nil
        }
        return ok
    }

    /// 选中从 anchor 到 target 的闭区间范围，替换当前选中集合并开启多选模式。
    /// 若 anchor 不在当前条目列表中，则回退为单选 target 并将其设为 anchor。
    func selectRemoteRange(from anchor: String, to target: String) {
        applyRemoteRange(from: anchor, to: target, append: false)
    }

    /// 将 anchor 到 target 的闭区间范围追加到当前选中集合，保持多选模式开启。
    func appendRemoteRange(from anchor: String, to target: String) {
        applyRemoteRange(from: anchor, to: target, append: true)
    }

    private func applyRemoteRange(from anchor: String, to target: String, append: Bool) {
        let entries = remotePane.entries
        guard !entries.isEmpty else { return }
        guard let anchorIndex = entries.firstIndex(where: { $0.name == anchor }),
              let targetIndex = entries.firstIndex(where: { $0.name == target }) else {
            selectedRemoteSet = [target]
            remoteAnchor = target
            isRemoteMultiSelect = true
            return
        }
        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        let names = Set(entries[range].map(\.name))
        if append {
            selectedRemoteSet.formUnion(names)
        } else {
            selectedRemoteSet = names
        }
        isRemoteMultiSelect = true
    }

    /// 双击远程条目:目录 → 进入;文件 → 选中并加入下载队列(item 6)。
    @discardableResult
    func doubleClickRemote(entry: FileEntry) async -> TransferTask? {
        if entry.isDirectory {
            await enterRemote(entry.name)
            return nil
        }
        selectRemote(entry.name)
        return await downloadSelected()
    }

    /// 右键菜单「下载」action:若条目已在选中集合 → 下载整个集合;
    /// 否则先置为唯一选中再下载(item 5)。
    @discardableResult
    func contextDownload(entry: FileEntry) async -> TransferTask? {
        if !selectedRemoteSet.contains(entry.name) {
            selectRemote(entry.name, append: false)
        }
        return await downloadSelected()
    }

    func toggleLocalMultiSelect() {
        isLocalMultiSelect.toggle()
        selectedLocalSet.removeAll()
        localAnchor = nil
    }

    func toggleRemoteMultiSelect() {
        isRemoteMultiSelect.toggle()
        selectedRemoteSet.removeAll()
        remoteAnchor = nil
    }

    // MARK: - 传输挂载

    /// 把本地选中项加入上传队列。
    /// 单选文件时保留覆盖确认;多选或单选目录时按目录边界生成任务组。
    @discardableResult
    func uploadSelected() async -> TransferTask? {
        let selected = selectedLocalSet
        guard !selected.isEmpty else { return nil }
        if selected.count > 1 {
            let paths = selected.map { joinPath(localPane.path, $0) }
            return await upload(localPaths: Array(paths)).first
        }
        guard let name = selected.first,
              let entry = localPane.entries.first(where: { $0.name == name }) else { return nil }
        if entry.isDirectory {
            return await upload(localPaths: [joinPath(localPane.path, name)]).first
        }
        return await uploadSingleFile(name: name, size: entry.size)
    }

    /// 把远程选中项加入下载队列。
    /// 单选文件时保留覆盖确认;多选或单选目录时按目录边界生成任务组。
    @discardableResult
    func downloadSelected() async -> TransferTask? {
        let selected = selectedRemoteSet
        guard !selected.isEmpty else { return nil }
        if selected.count > 1 {
            let paths = selected.map { joinPath(remotePane.path, $0) }
            return await download(remotePaths: Array(paths)).first
        }
        guard let name = selected.first,
              let entry = remotePane.entries.first(where: { $0.name == name }) else { return nil }
        if entry.isDirectory {
            return await download(remotePaths: [joinPath(remotePane.path, name)]).first
        }
        return await downloadSingleFile(name: name, size: entry.size)
    }

    /// 批量上传本地路径(文件或目录)。
    /// 通过核心统一入口完成聚合与入队,保留本地扫描。
    @discardableResult
    func upload(localPaths: [String]) async -> [TransferTask] {
        guard !localPaths.isEmpty else { return [] }
        let destinationDirectory = remotePane.path
        let allItems: [BatchItemRecord]
        do {
            allItems = try await scanLocalItems(paths: localPaths, destDir: destinationDirectory)
        } catch {
            localPane.recordError(error)
            Logger.shared.error("本地扫描失败: paths=\(localPaths), error=\(error)", module: LogModule.sftp)
            return []
        }
        guard !allItems.isEmpty else { return [] }

        let ffiItems = allItems.map { TaskItemRecord(source: $0.source, destination: $0.destination, size: $0.size, name: ($0.source as NSString).lastPathComponent, isDir: $0.isDir) }
        let uploadSizes = allItems.reduce(into: [String: UInt64]()) { $0[$1.source] = $1.isDir ? 0 : (fileSize(at: $1.source) ?? $1.size) }

        guard let result = try? await runOrchestration(
            selectedPaths: localPaths, items: ffiItems, direction: .upload, destDir: destinationDirectory
        ) else { return [] }

        transfers.refresh()
        return resolveOrchestratedTasks(result: result, uploadSizes: uploadSizes)
    }

    /// 批量下载远程路径(文件或目录),通过核心统一入口完成聚合与入队。
    /// 远程扫描（SSH/SFTP 网络往返）在后台执行。
    @discardableResult
    func download(remotePaths: [String]) async -> [TransferTask] {
        guard !remotePaths.isEmpty else { return [] }
        let items: [BatchItemRecord]
        do {
            items = try await scanRemoteItems(paths: remotePaths, destDir: localPane.path)
        } catch {
            remotePane.recordError(error)
            Logger.shared.error("远程扫描失败: paths=\(remotePaths), error=\(error)", module: LogModule.sftp)
            return []
        }
        guard !items.isEmpty else { return [] }

        let ffiItems = items.map { TaskItemRecord(source: $0.source, destination: $0.destination, size: $0.size, name: ($0.source as NSString).lastPathComponent, isDir: $0.isDir) }

        guard let result = try? await runOrchestration(
            selectedPaths: remotePaths, items: ffiItems, direction: .download, destDir: localPane.path
        ) else { return [] }

        transfers.refresh()
        return resolveOrchestratedTasks(result: result, uploadSizes: [:])
    }

    /// 用户已决策覆盖确认:覆盖则加入队列,跳过则取消。
    func resolveConflict(overwrite: Bool) {
        guard let context = conflictContext else {
            pendingConflict = nil
            return
        }
        pendingConflict = nil
        defer { conflictContext = nil }
        guard overwrite else { return }
        _ = enqueueSingle(
            direction: context.direction,
            name: context.name,
            size: context.size,
            source: context.source,
            destination: context.destination
        )
    }

    // MARK: - 私有辅助

    private func uploadSingleFile(name: String, size: UInt64) async -> TransferTask? {
        let source = joinPath(localPane.path, name)
        let destination = joinPath(remotePane.path, name)
        return enqueueSingle(direction: .upload, name: name, size: size, source: source, destination: destination)
    }

    private func downloadSingleFile(name: String, size: UInt64) async -> TransferTask? {
        let source = joinPath(remotePane.path, name)
        let destination = joinPath(localPane.path, name)
        if connectionSecrets != nil,
           let conflict = try? await checkDownloadConflict(name: name, source: source, destination: destination) {
            conflictContext = (.download, name, size, source, destination)
            pendingConflict = conflict
            return nil
        }
        return enqueueSingle(direction: .download, name: name, size: size, source: source, destination: destination)
    }

    private func enqueueSingle(
        direction: TransferDirection,
        name: String,
        size: UInt64,
        source: String,
        destination: String
    ) -> TransferTask? {
        let id = transfers.add(
            direction: direction, name: name, size: size,
            source: source,
            destination: destination,
            hostID: host.id,
            password: connectionSecrets?.password,
            passphrase: connectionSecrets?.passphrase
        )
        return transfers.tasks.first { $0.id == id }
    }

    private func runOrchestration(
        selectedPaths: [String],
        items: [TaskItemRecord],
        direction: TransferDirection,
        destDir: String
    ) async throws -> OrchestrationResultRecord {
        if let handler = orchestrationHandler {
            return try handler(selectedPaths, items, direction, host.id, destDir, connectionSecrets?.password, connectionSecrets?.passphrase)
        }
        let ffiDirection: TransferDirectionEnum = direction == .upload ? .upload : .download
        let hostID = host.id
        let password = connectionSecrets?.password
        let passphrase = connectionSecrets?.passphrase
        return try await FFIBackground.run {
            try orchestrateSftpTransfers(
                selectedPaths: selectedPaths,
                items: items,
                direction: ffiDirection,
                hostId: hostID,
                destDir: destDir,
                password: password,
                passphrase: passphrase
            )
        }
    }

    func resolveOrchestratedTasks(
        result: OrchestrationResultRecord,
        uploadSizes: [String: UInt64]
    ) -> [TransferTask] {
        let ids = Set(result.transferIds)
        guard !ids.isEmpty else { return [] }
        return transfers.tasks.filter { ids.contains($0.id.uuidString) }
    }

    private func scanLocalItems(paths: [String], destDir: String) async throws -> [BatchItemRecord] {
        let handler = scanLocalHandler
        return try await FFIBackground.run { () -> [BatchItemRecord] in
            if let handler {
                return try handler(paths, destDir)
            }
            return try scanLocalBatch(sources: paths, destDir: destDir)
        }
    }

    private func scanRemoteItems(paths: [String], destDir: String) async throws -> [BatchItemRecord] {
        let handler = scanRemoteHandler
        let hostID = host.id
        if let handler {
            return try await FFIBackground.run {
                try handler(paths, destDir)
            }
        }
        guard let secrets = connectionSecrets else { return [] }
        return try await FFIBackground.run {
            try scanRemoteBatch(
                hostId: hostID,
                sources: paths,
                destDir: destDir,
                password: secrets.password,
                passphrase: secrets.passphrase
            )
        }
    }


    private func fileSize(at path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) as NSDictionary else { return nil }
        return attrs.fileSize()
    }

    private func isDirectory(at path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 安全拼接文件路径，避免双斜杠（如根目录 `/` 拼接后变成 `//name`）。
    private func joinPath(_ dir: String, _ name: String) -> String {
        sftpChildPath(directory: dir, name: name)
    }

    /// 本地删除核心逻辑(不刷新面板);批量删除时逐个调用、最后统一刷新一次。
    private func deleteLocalCore(name: String) -> String? {
        let path = joinPath(localPane.path, name)
        do {
            try FileManager.default.removeItem(atPath: path)
            return nil
        } catch {
            let description = (error as NSError).localizedDescription
            Logger.shared.error("删除本地文件失败: path=\(path), error=\(description)", module: LogModule.sftp)
            return description
        }
    }

    /// 远程删除核心逻辑(不刷新面板);支持测试注入 deleteRemoteHandler。
    /// 网络往返与测试 handler 均在后台线程执行。
    private func deleteRemoteCore(name: String) async -> String? {
        guard let entry = remotePane.entries.first(where: { $0.name == name }) else {
            return "条目不存在"
        }
        let path = joinPath(remotePane.path, name)
        let sessionHandle = sftpHandle
        let isDir = entry.isDirectory
        let handler = deleteRemoteHandler
        do {
            let result = try await FFIBackground.run { () -> String? in
                if let handler {
                    return handler(name, isDir)
                }
                guard let sessionHandle else { throw PandaError.UnknownSftpHandle(0) }
                try PandaCoreBridge.shared.removeRemoteFile(
                    handle: sessionHandle, remotePath: path, isDirectory: isDir
                )
                return nil
            }
            return result
        } catch {
            let description = (error as NSError).localizedDescription
            Logger.shared.error("删除远程文件失败: path=\(path), error=\(description)", module: LogModule.sftp)
            return description
        }
    }

    /// 批量删除本地条目;逐个删除,全部完成后刷新面板一次。
    func deleteLocalBatch(names: [String]) async -> (deleted: Int, failed: [(name: String, error: String)]) {
        var failed: [(name: String, error: String)] = []
        var deleted = 0
        for name in names {
            if let error = deleteLocalCore(name: name) {
                failed.append((name, error))
            } else {
                deleted += 1
            }
        }
        _ = await localPane.reload()
        return (deleted, failed)
    }

    /// 批量删除远程条目;逐个删除,全部完成后刷新面板一次。
    func deleteRemoteBatch(names: [String]) async -> (deleted: Int, failed: [(name: String, error: String)]) {
        var failed: [(name: String, error: String)] = []
        var deleted = 0
        for name in names {
            if let error = await deleteRemoteCore(name: name) {
                failed.append((name, error))
            } else {
                deleted += 1
            }
        }
        _ = await remotePane.reload()
        return (deleted, failed)
    }

    private func checkDownloadConflict(name: String, source: String, destination: String) async throws -> PendingConflict? {
        // 网络往返（开 SFTP channel + stat）在后台执行。
        let sessionHandle = sftpHandle
        let record = try await FFIBackground.run {
            guard let sessionHandle else { throw PandaError.UnknownSftpHandle(0) }
            return try PandaCoreBridge.shared.checkDownloadConflict(
                handle: sessionHandle, remotePath: source, localPath: destination
            )
        }
        return record.map {
            PendingConflict(
                name: name,
                sourceSize: $0.sourceSize,
                sourceDate: $0.sourceMtime.map { Date(timeIntervalSince1970: Double($0)) },
                targetSize: $0.targetSize,
                targetDate: $0.targetMtime.map { Date(timeIntervalSince1970: Double($0)) }
            )
        }
    }

    // MARK: - 会话释放

    /// 精确关闭本标签拥有的 SFTP 会话并清理敏感参数。
    func disconnect() {
        PandaCoreBridge.shared.cancelSession(sessionID: sessionID)
        connectionGeneration += 1
        connectingTask = nil
        let handle = sftpHandle
        sftpHandle = nil
        connectionSecrets = nil
        guard let handle else { return }
        closeHandle(handle)
    }

    private func closeHandle(_ handle: UInt64) {
        let closer = sessionCloser
        Task {
            do {
                try await FFIBackground.run {
                    try closer(handle)
                }
                Logger.shared.info("SFTP 已断开 host=\(host.address):\(host.port); handle=\(handle)", module: LogModule.sftp)
            } catch {
                Logger.shared.error("SFTP 断开失败 host=\(host.address):\(host.port); handle=\(handle)", module: LogModule.sftp)
            }
        }
    }
}
