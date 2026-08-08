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

    /// Initializes the Rust core with a config directory inside the shared
    /// App Group container (so macOS and iPadOS builds use the same layout;
    /// iCloud KV sync mirrors the file across devices — see Sync/ConfigSync.swift).
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

    /// `password` / `passphrase` are fetched from the keychain by the caller;
    /// the Rust layer never touches the keychain itself. `trustOnFirstUse`
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
