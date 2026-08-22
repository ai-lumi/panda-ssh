import Foundation
import Combine

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
    @Published private(set) var isLoading: Bool = false

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
        isLoading = true
        defer { isLoading = false }
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

    /// 跳转到任意绝对路径:reload 成功则跳转并返回 true;
    /// reload 失败则回滚 `path` 到原值、`lastError` 置位、返回 false(item 7)。
    @discardableResult
    func navigate(to target: String) async -> Bool {
        let original = path
        path = target
        if await reload() {
            return true
        }
        path = original
        return false
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

/// SFTP 标签会话:本地/远程两个导航器 + 两侧选中项,并把上传/下载
/// 挂到共享的 TransferStore。
@MainActor
final class SftpSessionStore: ObservableObject {
    let host: HostEntry
    let transfers: TransferStore

    @Published private(set) var localPane: FilePaneNavigator
    @Published private(set) var remotePane: FilePaneNavigator
    /// 本地栏选中集合;单选模式下大小为 0 或 1,多选模式下可包含多个条目。
    @Published var selectedLocalSet: Set<String> = []
    /// 远程栏选中集合;单选模式下大小为 0 或 1,多选模式下可包含多个条目。
    @Published var selectedRemoteSet: Set<String> = []
    /// 兼容旧代码的单选访问:返回集合中的唯一选中项。
    var selectedLocal: String? { selectedLocalSet.first }
    var selectedRemote: String? { selectedRemoteSet.first }
    /// 本地栏多选模式开关。
    @Published var isLocalMultiSelect: Bool = false
    /// 远程栏多选模式开关。
    @Published var isRemoteMultiSelect: Bool = false
    /// 本地栏范围选择锚点：最近一次无 Shift 点击的条目名。
    @Published var localAnchor: String?
    /// 远程栏范围选择锚点：最近一次无 Shift 点击的条目名。
    @Published var remoteAnchor: String?
    /// 当前等待用户决策的覆盖确认;SwiftUI 通过 sheet/alert 展示。
    @Published var pendingConflict: PendingConflict?
    /// 批量任务等待覆盖确认的冲突；非 nil 时由视图弹出确认框。
    @Published var batchPendingConflict: PendingConflict?

    /// 真实连接参数;mock 模式为 nil。
    private var connectionSecrets: (password: String?, passphrase: String?)?
    /// 冲突弹窗选择后需要继续的传输上下文。
    private var conflictContext: (
        direction: TransferDirection,
        name: String,
        size: UInt64,
        source: String,
        destination: String
    )?
    /// 已自动刷新过的完成任务 id,避免重复刷新。
    private var refreshedTaskIDs: Set<UUID> = []
    /// 测试注入点:覆盖本地目录扫描行为。
    var scanLocalHandler: (([String], String) -> [BatchItemRecord])?
    /// 测试注入点:覆盖远程目录扫描行为。
    var scanRemoteHandler: (([String], String) -> [BatchItemRecord])?
    /// 测试注入点:覆盖远程文件删除行为。参数为 (name, isDirectory),返回 nil 表示成功。
    var deleteRemoteHandler: ((String, Bool) -> String?)?
    /// 测试注入点:覆盖 home 目录解析行为。参数为 (hostID, password, passphrase)。
    /// 默认为 nil 走真实 FFI;注入后验证后台调度与回退语义。
    var homeDirResolver: (@Sendable (String, String?, String?) throws -> String)?
    /// 待刷新面板标记;完成事件通过 debounce 合并,避免目录传输产生大量文件时频繁刷新。
    private var pendingReload: (local: Bool, remote: Bool) = (false, false)
    private var reloadWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

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
        observeCompletedTransfers()
    }

    /// 监听传输任务完成,自动刷新受影响的面板。
    /// 通过 0.3s debounce 合并多个同时完成的文件任务,避免目录传输时反复刷新。
    private func observeCompletedTransfers() {
        transfers.$tasks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks in
                guard let self else { return }
                self.observeBatchConflicts(in: tasks)
                var needsLocal = false
                var needsRemote = false
                for task in tasks where task.status == .done && !self.refreshedTaskIDs.contains(task.id) {
                    self.refreshedTaskIDs.insert(task.id)
                    switch task.direction {
                    case .upload:
                        if task.destination.hasPrefix(self.remotePane.path) { needsRemote = true }
                    case .download:
                        if task.destination.hasPrefix(self.localPane.path) { needsLocal = true }
                    }
                }
                if needsLocal { self.pendingReload.local = true }
                if needsRemote { self.pendingReload.remote = true }
                // 清理已不在任务列表中的旧 ID，避免无限增长。
                let liveIDs = Set(tasks.map(\.id))
                self.refreshedTaskIDs = self.refreshedTaskIDs.intersection(liveIDs)
                self.schedulePendingReload()
            }
            .store(in: &cancellables)
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
        Logger.shared.info("SFTP 已连接 host=\(host.address):\(host.port)", module: LogModule.sftp)
    }

    private func resolveHomeDir(password: String?, passphrase: String?) async -> String {
        let hostID = host.id
        let resolver = homeDirResolver
        do {
            // 完整握手（SSH + SFTP + home 解析）在后台线程执行，不阻塞主线程；
            // 多标签连接并行握手（tokio 多线程 runtime 并发 block_on）。
            return try await FFIBackground.run { () -> String in
                if let resolver {
                    return try resolver(hostID, password, passphrase)
                }
                return try PandaCoreBridge.shared.resolveSftpHomeDir(
                    of: hostID,
                    password: password,
                    passphrase: passphrase,
                    trustOnFirstUse: false
                )
            }
        } catch {
            // 兜底：解析失败时使用 `/`，让用户仍能手动导航。
            Logger.shared.error("home 目录解析失败 host=\(host.address):\(host.port); 原因=\(error.localizedDescription)", module: LogModule.sftp)
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
        selectedLocalSet.removeAll()
        selectedRemoteSet.removeAll()
        localAnchor = nil
        remoteAnchor = nil
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
        await localPane.goUp()
        selectedLocalSet.removeAll()
        localAnchor = nil
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
        await remotePane.goUp()
        selectedRemoteSet.removeAll()
        remoteAnchor = nil
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

    /// 批量上传本地路径(文件或目录),按目录边界生成任务组。
    /// 仅单个文件时生成独立任务;多个文件时每个文件独立;目录单独成组。
    /// 目录扫描（可能耗时）在后台执行。
    @discardableResult
    func upload(localPaths: [String]) async -> [TransferTask] {
        guard !localPaths.isEmpty else { return [] }
        // 先用 Rust 扫描结果识别目录(测试 handler 也走这里),
        // 回退到 FileManager 判断真实本地路径。
        let scannedDirPaths = Set((await scanLocalItems(paths: localPaths, destDir: remotePane.path)).filter { $0.isDir }.map { $0.source })
        let dirs = localPaths.filter { scannedDirPaths.contains($0) || isDirectory(at: $0) }
        let files = localPaths.filter { !dirs.contains($0) }

        var tasks: [TransferTask] = []

        // 仅单个文件:走独立任务,与单选文件行为一致。
        if dirs.isEmpty, files.count == 1, let file = files.first {
            let name = (file as NSString).lastPathComponent
            if let size = fileSize(at: file),
               let task = enqueueSingle(direction: .upload, name: name, size: size, source: file, destination: joinPath(remotePane.path, name)) {
                tasks.append(task)
            }
            return tasks
        }

        // 多个文件:每个文件独立任务,不组成任务组;扫描结果可提供大小回退(便于测试)。
        for file in files {
            let name = (file as NSString).lastPathComponent
            let scannedSize = (await scanLocalItems(paths: [file], destDir: remotePane.path)).first { $0.source == file }?.size
            if let size = fileSize(at: file) ?? scannedSize,
               let task = enqueueSingle(direction: .upload, name: name, size: size, source: file, destination: joinPath(remotePane.path, name)) {
                tasks.append(task)
            }
        }

        // 每个目录生成一个任务组,组内每个文件为独立任务。
        for dir in dirs {
            let name = (dir as NSString).lastPathComponent
            let destDir = joinPath(remotePane.path, name)
            let items = await scanLocalItems(paths: [dir], destDir: destDir)
            tasks += enqueueGroup(direction: .upload, groupName: name, items: items)
        }

        return tasks
    }

    /// 批量下载远程路径(文件或目录),按目录边界生成任务组。
    /// 远程扫描（SSH/SFTP 网络往返）在后台执行。
    @discardableResult
    func download(remotePaths: [String]) async -> [TransferTask] {
        guard !remotePaths.isEmpty else { return [] }
        // 远程路径类型需通过 Rust 扫描结果中的 isDir 判断;先全部交给扫描器。
        let items = await scanRemoteItems(paths: remotePaths, destDir: localPane.path)
        let allDirs = items.filter { $0.isDir }.map { $0.source }
        // 只取真正的顶层目录：不是其他目录的前缀，避免嵌套子目录被重复建组。
        let topLevelDirs = Set(allDirs.filter { dir in
            !allDirs.contains(where: { $0 != dir && dir.hasPrefix($0 + "/") })
        })

        var tasks: [TransferTask] = []

        // 仅单个文件:走独立任务。
        if items.count == 1, let item = items.first, !item.isDir {
            return enqueueSingle(direction: .download, name: (item.source as NSString).lastPathComponent, size: item.size, source: item.source, destination: item.destination).map { [$0] } ?? []
        }

        // 顶层文件:独立任务(不属于任何顶层目录的后代)。
        let topLevelFiles = items.filter { item in
            !item.isDir && !topLevelDirs.contains(where: { item.source.hasPrefix($0 + "/") })
        }
        for item in topLevelFiles {
            if let task = enqueueSingle(direction: .download, name: (item.source as NSString).lastPathComponent, size: item.size, source: item.source, destination: item.destination) {
                tasks.append(task)
            }
        }

        // 每个顶层目录一个任务组。
        for dirSource in topLevelDirs {
            let groupName = (dirSource as NSString).lastPathComponent
            let groupItems = items.filter { $0.source == dirSource || $0.source.hasPrefix(dirSource + "/") }
            tasks += enqueueGroup(direction: .download, groupName: groupName, items: groupItems)
        }

        return tasks
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
        if connectionSecrets != nil,
           let conflict = try? await checkUploadConflict(name: name, source: source, destination: destination) {
            conflictContext = (.upload, name, size, source, destination)
            pendingConflict = conflict
            return nil
        }
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

    private func enqueueGroup(
        direction: TransferDirection,
        groupName: String,
        items: [BatchItemRecord]
    ) -> [TransferTask] {
        let fileItems = items.filter { !$0.isDir }
        guard !fileItems.isEmpty else { return [] }
        let groupID = UUID()
        var tasks: [TransferTask] = []
        for item in fileItems {
            let id = transfers.add(
                direction: direction,
                name: (item.source as NSString).lastPathComponent,
                size: item.size,
                source: item.source,
                destination: item.destination,
                hostID: host.id,
                groupID: groupID,
                groupName: groupName,
                password: connectionSecrets?.password,
                passphrase: connectionSecrets?.passphrase
            )
            if let task = transfers.tasks.first(where: { $0.id == id }) {
                tasks.append(task)
            }
        }
        return tasks
    }

    private func scanLocalItems(paths: [String], destDir: String) async -> [BatchItemRecord] {
        let handler = scanLocalHandler
        // 本地递归扫描可能在主线程耗时数百 ms，放后台执行（测试 handler 亦同）。
        return (try? await FFIBackground.run { () -> [BatchItemRecord] in
            if let handler {
                return handler(paths, destDir)
            }
            return try scanLocalBatch(sources: paths, destDir: destDir)
        }) ?? []
    }

    private func scanRemoteItems(paths: [String], destDir: String) async -> [BatchItemRecord] {
        let handler = scanRemoteHandler
        let hostID = host.id
        // 远端递归扫描含 SSH/SFTP 网络往返，放后台执行（测试 handler 亦同）。
        if let handler {
            return (try? await FFIBackground.run {
                handler(paths, destDir)
            }) ?? []
        }
        guard let secrets = connectionSecrets else { return [] }
        return (try? await FFIBackground.run {
            try scanRemoteBatch(
                hostId: hostID,
                sources: paths,
                destDir: destDir,
                password: secrets.password,
                passphrase: secrets.passphrase
            )
        }) ?? []
    }

    private func fileSize(at path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) as NSDictionary else { return nil }
        return attrs.fileSize()
    }

    private func isDirectory(at path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func parentPath(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// 安全拼接文件路径，避免双斜杠（如根目录 `/` 拼接后变成 `//name`）。
    private func joinPath(_ dir: String, _ name: String) -> String {
        if dir.hasSuffix("/") {
            return dir + name
        } else {
            return dir + "/" + name
        }
    }

    /// 删除本地文件或目录;删除成功后刷新本地面板。
    /// 返回 `nil` 表示成功，否则返回错误描述。
    func deleteLocal(name: String) async -> String? {
        let error = deleteLocalCore(name: name)
        if error == nil { _ = await localPane.reload() }
        return error
    }

    /// 删除远程文件或目录;删除成功后刷新远程面板。
    /// 返回 `nil` 表示成功，否则返回错误描述。
    func deleteRemote(name: String) async -> String? {
        let error = await deleteRemoteCore(name: name)
        if error == nil { _ = await remotePane.reload() }
        return error
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
        let hostID = host.id
        let password = connectionSecrets?.password
        let passphrase = connectionSecrets?.passphrase
        let isDir = entry.isDirectory
        let handler = deleteRemoteHandler
        do {
            let result = try await FFIBackground.run { () -> String? in
                if let handler {
                    return handler(name, isDir)
                }
                try PandaCoreBridge.shared.removeRemoteFile(
                    hostID: hostID,
                    remotePath: path,
                    isDirectory: isDir,
                    password: password,
                    passphrase: passphrase,
                    trustOnFirstUse: false
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

    /// 右键菜单「删除」action:若条目已在选中集合 → 删除整个集合;
    /// 否则先置为唯一选中再删除(item 5 修复:多选删除未处理)。
    @discardableResult
    func contextDelete(entry: FileEntry, local: Bool) async -> (deleted: Int, failed: [(name: String, error: String)]) {
        let selectedSet = local ? selectedLocalSet : selectedRemoteSet
        let isMulti = local ? isLocalMultiSelect : isRemoteMultiSelect
        if isMulti && selectedSet.contains(entry.name) && selectedSet.count > 1 {
            let names = Array(selectedSet)
            return local ? await deleteLocalBatch(names: names) : await deleteRemoteBatch(names: names)
        }
        if !selectedSet.contains(entry.name) {
            if local { selectLocal(entry.name, append: false) } else { selectRemote(entry.name, append: false) }
        }
        return local ? await deleteLocalBatch(names: [entry.name]) : await deleteRemoteBatch(names: [entry.name])
    }

    private func checkUploadConflict(name: String, source: String, destination: String) async throws -> PendingConflict? {
        let hostID = host.id
        let password = connectionSecrets?.password
        let passphrase = connectionSecrets?.passphrase
        // 网络往返（开 SFTP channel + stat）在后台执行。
        let record = try await FFIBackground.run {
            try PandaCoreBridge.shared.checkUploadConflict(
                hostID: hostID,
                localPath: source,
                remotePath: destination,
                password: password,
                passphrase: passphrase,
                trustOnFirstUse: false
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

    private func checkDownloadConflict(name: String, source: String, destination: String) async throws -> PendingConflict? {
        let hostID = host.id
        let password = connectionSecrets?.password
        let passphrase = connectionSecrets?.passphrase
        // 网络往返（开 SFTP channel + stat）在后台执行。
        let record = try await FFIBackground.run {
            try PandaCoreBridge.shared.checkDownloadConflict(
                hostID: hostID,
                remotePath: source,
                localPath: destination,
                password: password,
                passphrase: passphrase,
                trustOnFirstUse: false
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

    /// 关闭 SFTP 会话并清理敏感参数。
    /// 当前 FFI 的 SFTP 调用为无状态短连接,此处主要为后续持久会话预留生命周期钩子。
    func disconnect() {
        connectionSecrets = nil
    }
}
