import Foundation

/// App Group 标识符，与 entitlements 中配置的一致。
enum AppGroup {
    static let identifier = "group.com.pandassh.shared"
}

/// 配置目录解析:macOS 桌面端使用 `~/.panda-ssh/`,iPadOS 受沙盒限制使用 App Group。
/// 文件名必须与 Rust FFI 层 `init_store` 保持一致。
enum AppPaths {
    static var configDirectory: URL {
        #if os(macOS)
        // macOS:用户主目录下的隐藏配置目录,便于查看、备份与命令行工具集成。
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".panda-ssh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
        #else
        // iPadOS:必须使用 App Group 共享容器,才能被扩展/extension 访问。
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    static var hostsFileURL: URL {
        configDirectory.appendingPathComponent("hosts.toml")
    }

    static var groupsFileURL: URL {
        configDirectory.appendingPathComponent("groups.toml")
    }

    static var knownHostsFileURL: URL {
        configDirectory.appendingPathComponent("known_hosts")
    }

    static var snippetsDirectoryURL: URL {
        configDirectory.appendingPathComponent("snippets")
    }

    /// 日志文件目录(macOS: ~/.panda-ssh/logs/, iPadOS: App Group 容器/logs/)。
    static var logsDirectoryURL: URL {
        configDirectory.appendingPathComponent("logs")
    }
}

/// Thin Swift-side wrapper over the uniffi-generated `panda_ffi` bindings.
/// The generated Swift file (Rust/Generated/panda_ffi.swift) is compiled
/// directly into this target, so its top-level functions are visible here.
/// Bridge method names intentionally differ from the generated globals to
/// avoid member-vs-global lookup ambiguity.
final class PandaCoreBridge {
    static let shared = PandaCoreBridge()

    private var started = false

    private init() {}

    /// Initializes the Rust core with a config directory:
    /// macOS uses `~/.panda-ssh/`, iPadOS uses the App Group container.
    func start() throws {
        guard !started else { return }
        try initStore(configDir: AppPaths.configDirectory.path)
        started = true
    }

    func allHosts() throws -> [HostConfigRecord] {
        try listHosts()
    }

    func save(host: HostConfigRecord) throws {
        try saveHost(host: host)
    }

    func delete(id: String) throws {
        try deleteHost(id: id)
    }

    func storeCredential(reference: String, secret: String) throws { try saveCredential(reference: reference, secret: secret) }
    func storedCredential(reference: String) throws -> String? { try readCredential(reference: reference) }
    func removeCredential(reference: String) throws { try deleteCredential(reference: reference) }
    func updateCredentialProtectionKey(currentKey: String?, newKey: String?) throws {
        try setCredentialProtectionKey(currentKey: currentKey, newKey: newKey)
    }
    func isCredentialProtectionEnabled() throws -> Bool { try credentialProtectionEnabled() }

    func allGroups() throws -> [GroupRecord] {
        try listGroups()
    }

    func save(group: GroupRecord) throws {
        try saveGroup(group: group)
    }

    /// 级联语义在 Rust core 完成:组内(含子分组)主机回根级,子分组一并删除。
    /// (方法名与生成的全局函数错开,避免成员/全局查找歧义)
    func removeGroup(id: String) throws {
        try deleteGroup(id: id)
    }

    func relocateGroup(id: String, toParent parentID: String?) throws {
        try moveGroup(id: id, newParentId: parentID)
    }

    /// `password` / `passphrase` are fetched from the local credential store by the caller;
    /// the Rust layer receives them only as transient parameters. `trustOnFirstUse`
    /// maps to the unknown-host-key policy (false = Reject, true = TOFU).
    func checkConnection(of host: HostConfigRecord, password: String?, passphrase: String?, trustOnFirstUse: Bool = false) throws -> String {
        try testConnection(hostId: host.id, password: password, passphrase: passphrase, trustOnFirstUse: trustOnFirstUse)
    }

    /// 文件级主机密钥状态(不发起连接)。(方法名与生成的全局函数错开,
    /// 避免成员/全局查找歧义)
    func recordedHostKeyStatus(host: String, port: UInt16) throws -> KnownHostStatusEnum {
        try hostKeyStatus(host: host, port: port)
    }

    /// 用户确认信任后,把探测呈现的密钥写入 known_hosts。
    func acceptPresentedHostKey(host: String, port: UInt16, key: String) throws {
        try acceptUnknownHostKey(host: host, port: port, key: key)
    }

    /// 解析远端 SFTP 会话初始工作目录（通常为 home 目录）。
    func resolveSftpHomeDir(of hostID: String, password: String? = nil, passphrase: String? = nil, trustOnFirstUse: Bool = false) throws -> String {
        try sftpHomeDir(hostId: hostID, password: password, passphrase: passphrase, trustOnFirstUse: trustOnFirstUse)
    }

    /// 上传前预检查远端目标是否已存在。
    func checkUploadConflict(
        hostID: String,
        localPath: String,
        remotePath: String,
        password: String? = nil,
        passphrase: String? = nil,
        trustOnFirstUse: Bool = false
    ) throws -> RemoteFileConflictRecord? {
        try sftpCheckUploadConflict(
            hostId: hostID,
            localPath: localPath,
            remotePath: remotePath,
            password: password,
            passphrase: passphrase,
            trustOnFirstUse: trustOnFirstUse
        )
    }

    /// 下载前预检查本地目标是否已存在。
    func checkDownloadConflict(
        hostID: String,
        remotePath: String,
        localPath: String,
        password: String? = nil,
        passphrase: String? = nil,
        trustOnFirstUse: Bool = false
    ) throws -> RemoteFileConflictRecord? {
        try sftpCheckDownloadConflict(
            hostId: hostID,
            remotePath: remotePath,
            localPath: localPath,
            password: password,
            passphrase: passphrase,
            trustOnFirstUse: trustOnFirstUse
        )
    }

    /// 删除远端文件或空目录。
    func removeRemoteFile(
        hostID: String,
        remotePath: String,
        isDirectory: Bool,
        password: String? = nil,
        passphrase: String? = nil,
        trustOnFirstUse: Bool = false
    ) throws {
        if isDirectory {
            try sftpRemoveDir(
                hostId: hostID,
                remotePath: remotePath,
                password: password,
                passphrase: passphrase,
                trustOnFirstUse: trustOnFirstUse
            )
        } else {
            try sftpRemoveFile(
                hostId: hostID,
                remotePath: remotePath,
                password: password,
                passphrase: passphrase,
                trustOnFirstUse: trustOnFirstUse
            )
        }
    }

    /// 在远端创建目录（父目录必须已存在）。
    func createRemoteDir(
        hostID: String,
        remotePath: String,
        password: String? = nil,
        passphrase: String? = nil,
        trustOnFirstUse: Bool = false
    ) throws {
        try sftpCreateDir(
            hostId: hostID,
            remotePath: remotePath,
            password: password,
            passphrase: passphrase,
            trustOnFirstUse: trustOnFirstUse
        )
    }

    /// 回传批量任务中单个冲突文件的覆盖决策（true=覆盖 / false=跳过）。
    func resolveBatchConflict(taskID: String, overwrite: Bool) throws {
        try batchTransferResolveConflict(taskId: taskID, overwrite: overwrite)
    }

    // MARK: - 代码片段

    func initializeSnippets(at url: URL) throws {
        try initSnippets(dir: url.path)
    }

    func allSnippets() throws -> [SnippetRecord] {
        try listSnippets()
    }

    func save(snippet: SnippetRecord) throws {
        try saveSnippet(snippet: snippet)
    }

    func removeSnippet(name: String) throws {
        try deleteSnippet(name: name)
    }
}

/// 阻塞型 FFI 调用的后台调度设施。
///
/// Rust 侧导出函数是同步的（内部 `block_on` 全局 tokio runtime），若在
/// 主线程直接调用会冻结 UI。`FFIBackground.run` 把同步闭包放到协作线程池
/// （`Task.detached`）执行，调用方 `await` 后结果回主线程；多个调用并发
/// 时由 tokio 多线程 runtime 并行握手，互不排队。
enum FFIBackground {
    /// 在后台线程执行 `op` 并返回其结果；`op` 抛出的错误原样传播。
    /// 注意：`op` 是同步 FFI 调用（网络往返/文件扫描），执行期间不占主线程。
    static func run<T: Sendable>(_ op: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: op).value
    }
}
