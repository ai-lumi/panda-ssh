import Foundation

/// 文件条目(对应原型 LOCAL_FS / remoteFS 的 {name, dir, size, mtime})。
struct FileEntry: Equatable, Identifiable {
    let name: String
    let isDirectory: Bool
    /// 字节数;目录恒为 0(列表显示「—」)
    let size: UInt64
    /// 展示用修改时间(格式固定为 yyyy-MM-dd HH:mm)
    let modified: String

    var id: String { name }
}

// MARK: - 文件面板数据源

/// 单栏(本地或远程)目录内容提供者。
protocol FilePaneSource: AnyObject {
    var root: String { get }
    var rootTitle: String { get }
    /// 列出指定路径下的文件条目;失败时抛出错误由视图展示连接失败。
    func list(path: String) async throws -> [FileEntry]
}

/// 演示数据源:与原型一致的静态本地/远程假文件系统。
final class DemoFilePaneSource: FilePaneSource {
    let root: String
    let rootTitle: String
    private let fs: [String: [FileEntry]]

    init(root: String, fs: [String: [FileEntry]], rootTitle: String) {
        self.root = root
        self.fs = fs
        self.rootTitle = rootTitle
    }

    func list(path: String) async throws -> [FileEntry] {
        fs[path] ?? []
    }
}

/// 本地真实数据源:通过 FileManager 读取当前用户可访问目录。
final class LocalFilePaneSource: FilePaneSource {
    let root: String
    let rootTitle = "本地"
    private let fileManager = FileManager.default

    init(root: String) {
        self.root = root
    }

    func list(path: String) async throws -> [FileEntry] {
        let url = URL(fileURLWithPath: path)
        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        )
        return try contents.map { item in
            let resourceValues = try item.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ])
            let isDirectory = resourceValues.isDirectory ?? false
            let size = isDirectory ? 0 : UInt64(resourceValues.fileSize ?? 0)
            let modified = formatFileDate(resourceValues.contentModificationDate)
            return FileEntry(
                name: item.lastPathComponent,
                isDirectory: isDirectory,
                size: size,
                modified: modified
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// 远程真实数据源:通过 FFI `sftpList` 拉取远端目录。
final class RemoteFilePaneSource: FilePaneSource {
    let root: String
    let rootTitle: String
    let hostID: String
    let password: String?
    let passphrase: String?

    init(root: String, rootTitle: String, hostID: String, password: String?, passphrase: String?) {
        self.root = root
        self.rootTitle = rootTitle
        self.hostID = hostID
        self.password = password
        self.passphrase = passphrase
    }

    func list(path: String) async throws -> [FileEntry] {
        let records = try sftpList(
            hostId: hostID,
            path: path,
            password: password,
            passphrase: passphrase,
            trustOnFirstUse: false
        )
        return records.map { record in
            FileEntry(
                name: record.name,
                isDirectory: record.isDir,
                size: record.isDir ? 0 : record.size,
                modified: formatFileDate(record.modified.map { Date(timeIntervalSince1970: Double($0)) })
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

private func formatFileDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: date)
}

/// 演示文件系统:本地为固定假数据(对应原型 LOCAL_FS),
/// 远程按用户名生成 home 目录(对应原型 remoteFS,两层以上)。
enum DemoFileSystem {
    static let localRoot: String = {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.path
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        #endif
    }()

    static let local: [String: [FileEntry]] = {
        let modified = { (month: Int, day: Int, hour: Int, minute: Int) in
            "2026-\(String(format: "%02d", month))-\(String(format: "%02d", day)) \(String(format: "%02d", hour)):\(String(format: "%02d", minute))"
        }
        return [
            localRoot: [
                FileEntry(name: "Documents", isDirectory: true, size: 0, modified: modified(7, 30, 14, 2)),
                FileEntry(name: "Downloads", isDirectory: true, size: 0, modified: modified(8, 4, 9, 41)),
                FileEntry(name: "deploy.tar.gz", isDirectory: false, size: 18_432_000, modified: modified(8, 3, 22, 15)),
                FileEntry(name: "notes.md", isDirectory: false, size: 4_096, modified: modified(8, 1, 11, 20)),
                FileEntry(name: "id_ed25519.pub", isDirectory: false, size: 102, modified: modified(5, 12, 16, 0)),
            ],
            localRoot + "/Documents": [
                FileEntry(name: "spec-drafts", isDirectory: true, size: 0, modified: modified(7, 28, 10, 0)),
                FileEntry(name: "roadmap.pdf", isDirectory: false, size: 2_355_200, modified: modified(7, 29, 18, 30)),
                FileEntry(name: "budget.xlsx", isDirectory: false, size: 51_200, modified: modified(6, 15, 9, 0)),
            ],
            localRoot + "/Downloads": [
                FileEntry(name: "panda-ssh-v0.1.dmg", isDirectory: false, size: 8_920_000, modified: modified(8, 4, 9, 41)),
                FileEntry(name: "wallpaper.heic", isDirectory: false, size: 3_145_728, modified: modified(8, 2, 20, 5)),
            ],
            localRoot + "/Documents/spec-drafts": [
                FileEntry(name: "sftp-spec.md", isDirectory: false, size: 12_288, modified: modified(7, 28, 10, 12)),
            ],
        ]
    }()

    static func remoteRoot(username: String) -> String { "/home/\(username)" }

    static func remote(username: String) -> [String: [FileEntry]] {
        let home = remoteRoot(username: username)
        return [
            home: [
                FileEntry(name: "app", isDirectory: true, size: 0, modified: "2026-08-01 03:12"),
                FileEntry(name: "logs", isDirectory: true, size: 0, modified: "2026-08-05 06:00"),
                FileEntry(name: ".bashrc", isDirectory: false, size: 3_526, modified: "2025-11-20 12:00"),
                FileEntry(name: "backup-2026-08-01.sql.gz", isDirectory: false, size: 52_428_800, modified: "2026-08-01 03:30"),
            ],
            "\(home)/app": [
                FileEntry(name: "current", isDirectory: true, size: 0, modified: "2026-08-01 03:12"),
                FileEntry(name: "releases", isDirectory: true, size: 0, modified: "2026-07-20 03:12"),
                FileEntry(name: ".env.example", isDirectory: false, size: 512, modified: "2026-06-01 09:00"),
            ],
            "\(home)/app/current": [
                FileEntry(name: "server.js", isDirectory: false, size: 20_480, modified: "2026-08-01 03:12"),
                FileEntry(name: "package.json", isDirectory: false, size: 1_024, modified: "2026-07-31 22:00"),
            ],
            "\(home)/logs": [
                FileEntry(name: "app.log", isDirectory: false, size: 10_485_760, modified: "2026-08-05 06:00"),
                FileEntry(name: "access.log", isDirectory: false, size: 8_388_608, modified: "2026-08-05 05:58"),
            ],
        ]
    }
}

/// 面包屑一段:标题 + 对应绝对路径。
struct Crumb: Equatable {
    let title: String
    let path: String
}

/// 单栏(本地或远程)目录导航模型:当前路径、进入/返回上级/面包屑跳转。
/// 根路径不可再向上;进入非目录或未知名称会被拒绝。
final class FilePaneNavigator: ObservableObject {
    let source: any FilePaneSource
    private(set) var path: String

    @Published private(set) var entries: [FileEntry] = []
    @Published private(set) var lastError: Error? = nil

    init(source: any FilePaneSource) {
        self.source = source
        self.path = source.root
    }

    /// 兼容旧初始化器:基于静态假文件系统构造导航器。
    convenience init(root: String, fs: [String: [FileEntry]], rootTitle: String) {
        self.init(source: DemoFilePaneSource(root: root, fs: fs, rootTitle: rootTitle))
    }

    var root: String { source.root }
    var rootTitle: String { source.rootTitle }

    var canGoUp: Bool { path != source.root }

    /// 面包屑:根段显示 rootTitle(「本地」/「远程」),其后逐级目录名。
    var breadcrumbs: [Crumb] {
        let root = source.root
        var crumbs = [Crumb(title: source.rootTitle, path: root)]
        guard path != root, path.hasPrefix(root + "/") else { return crumbs }
        var acc = root
        for segment in path.dropFirst(root.count + 1).split(separator: "/") {
            acc += "/" + segment
            crumbs.append(Crumb(title: String(segment), path: acc))
        }
        return crumbs
    }

    /// 刷新当前目录内容;失败时写入 `lastError` 并返回 false。
    @discardableResult
    func reload() async -> Bool {
        do {
            entries = try await source.list(path: path)
            lastError = nil
            return true
        } catch {
            lastError = error
            return false
        }
    }

    /// 进入子目录;目标是文件或不存在时拒绝并返回 false。
    /// 进入成功后自动刷新新目录内容。
    @discardableResult
    func enter(_ name: String) async -> Bool {
        guard let entry = entries.first(where: { $0.name == name }), entry.isDirectory else { return false }
        path = path + "/" + name
        _ = await reload()
        return true
    }

    /// 返回上级;根目录下为 no-op。
    /// 返回成功后自动刷新目录内容。
    func goUp() async {
        guard canGoUp else { return }
        if let slash = path.lastIndex(of: "/") {
            path = slash == path.startIndex ? "/" : String(path[..<slash])
            _ = await reload()
        }
    }

    /// 面包屑跳转:仅接受当前路径前缀内的祖先路径(含根)。
    /// 跳转后自动刷新目录内容。
    func navigate(to target: String) async {
        let root = source.root
        guard target == root || (path.hasPrefix(target) && target.hasPrefix(root)) else { return }
        path = target
        _ = await reload()
    }
}

/// SFTP 标签会话:本地/远程两个导航器 + 两侧选中项,并把上传/下载
/// 挂到共享的 TransferStore。
@MainActor
final class SftpSessionStore: ObservableObject {
    let host: HostEntry
    let transfers: TransferStore

    @Published private(set) var localPane: FilePaneNavigator
    @Published private(set) var remotePane: FilePaneNavigator
    @Published private(set) var selectedLocal: String?
    @Published private(set) var selectedRemote: String?

    /// 真实连接参数;mock 模式为 nil。
    private var connectionSecrets: (password: String?, passphrase: String?)?

    init(host: HostEntry, transfers: TransferStore) {
        self.host = host
        self.transfers = transfers
        localPane = FilePaneNavigator(source: LocalFilePaneSource(root: DemoFileSystem.localRoot))
        remotePane = FilePaneNavigator(
            source: DemoFilePaneSource(
                root: DemoFileSystem.remoteRoot(username: host.username),
                fs: DemoFileSystem.remote(username: host.username),
                rootTitle: "远程"
            )
        )
    }

    /// 用真实后端初始化远程面板;调用前需先通过连接门控取得密码/口令。
    /// 通过 `sftp_home_dir` 解析服务器实际 home 目录,避免硬编码 `/home/<username>`
    /// 在非标准 home 路径的服务器上失效。
    func connect(password: String?, passphrase: String?) async {
        connectionSecrets = (password, passphrase)
        let root = await resolveHomeDir(password: password, passphrase: passphrase)
        remotePane = FilePaneNavigator(
            source: RemoteFilePaneSource(
                root: root,
                rootTitle: "远程 — \(host.name)",
                hostID: host.id,
                password: password,
                passphrase: passphrase
            )
        )
    }

    private func resolveHomeDir(password: String?, passphrase: String?) async -> String {
        do {
            return try PandaCoreBridge.shared.resolveSftpHomeDir(
                of: host.id,
                password: password,
                passphrase: passphrase,
                trustOnFirstUse: false
            )
        } catch {
            // 兜底：解析失败时使用 `/`，让用户仍能手动导航。
            return "/"
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
    }

    var localPath: String { localPane.path }
    var remotePath: String { remotePane.path }

    // MARK: - 本地栏操作

    func selectLocal(_ name: String) { selectedLocal = name }
    func enterLocal(_ name: String) async { if await localPane.enter(name) { selectedLocal = nil } }
    func goUpLocal() async { await localPane.goUp(); selectedLocal = nil }
    func navigateLocal(to path: String) async { await localPane.navigate(to: path); selectedLocal = nil }

    // MARK: - 远程栏操作

    func selectRemote(_ name: String) { selectedRemote = name }
    func enterRemote(_ name: String) async { if await remotePane.enter(name) { selectedRemote = nil } }
    func goUpRemote() async { await remotePane.goUp(); selectedRemote = nil }
    func navigateRemote(to path: String) async { await remotePane.navigate(to: path); selectedRemote = nil }

    // MARK: - 传输挂载

    /// 把本地选中项加入上传队列;无选中或条目不存在时返回 nil。
    @discardableResult
    func uploadSelected() -> TransferTask? {
        guard let name = selectedLocal,
              let entry = localPane.entries.first(where: { $0.name == name }) else { return nil }
        let size = entry.isDirectory ? 3_145_728 : entry.size
        let id = transfers.add(
            direction: .upload, name: name, size: size,
            source: localPane.path + "/" + name,
            destination: remotePane.path + "/" + name,
            hostID: host.id,
            password: connectionSecrets?.password,
            passphrase: connectionSecrets?.passphrase
        )
        return transfers.tasks.first { $0.id == id }
    }

    /// 把远程选中项加入下载队列;无选中或条目不存在时返回 nil。
    @discardableResult
    func downloadSelected() -> TransferTask? {
        guard let name = selectedRemote,
              let entry = remotePane.entries.first(where: { $0.name == name }) else { return nil }
        let size = entry.isDirectory ? 6_291_456 : entry.size
        let id = transfers.add(
            direction: .download, name: name, size: size,
            source: remotePane.path + "/" + name,
            destination: localPane.path + "/" + name,
            hostID: host.id,
            password: connectionSecrets?.password,
            passphrase: connectionSecrets?.passphrase
        )
        return transfers.tasks.first { $0.id == id }
    }

    // MARK: - 会话释放

    /// 关闭 SFTP 会话并清理敏感参数。
    /// 当前 FFI 的 SFTP 调用为无状态短连接,此处主要为后续持久会话预留生命周期钩子。
    func disconnect() {
        connectionSecrets = nil
    }
}
