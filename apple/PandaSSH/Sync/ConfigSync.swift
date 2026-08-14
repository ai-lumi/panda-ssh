import Foundation

// MARK: - 数据模型

/// 跨设备同步的配置快照。版本化 JSON 存于 iCloud KV。
struct ConfigSnapshot: Codable, Equatable {
    static let currentVersion = 1
    static let kvKey = "panda-ssh.config.v1"
    static let legacyKey = "panda-ssh.hosts.toml"

    let version: Int
    /// 写入时的 Unix 时间戳(秒),冲突判定用 last-write-wins。
    let updatedAt: TimeInterval
    /// hosts.toml 完整文本。
    let hosts: String
    /// groups.toml 完整文本。
    let groups: String
}

// MARK: - KV 抽象

/// Abstraction over the iCloud key-value store, injected so tests can swap in
/// an in-memory fake instead of `NSUbiquitousKeyValueStore`.
protocol ConfigKVStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    @discardableResult
    func synchronize() -> Bool
}

/// Default store backed by the system iCloud KVS.
final class UbiquitousConfigKVStore: ConfigKVStore {
    private let kv = NSUbiquitousKeyValueStore.default

    func data(forKey key: String) -> Data? {
        kv.data(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        kv.set(value, forKey: key)
    }

    @discardableResult
    func synchronize() -> Bool {
        kv.synchronize()
    }
}

// MARK: - 合并工具

/// 文本级 hosts.toml 合并:应用远端快照时保留本机 `key_path`。
/// 解析 `[[host]]` 块并定位 `[host.auth]` 下的 `key_path` 行。
enum HostTOMLMerger {
    /// 用本地 hosts.toml 的 `key_path` 覆盖远端对应主机的 `key_path`。
    static func preserveLocalKeyPaths(local: String, remote: String) -> String {
        let localKeyPaths = keyPathsByHostID(in: local)
        let blocks = remote.components(separatedBy: "[[host]]")
        guard !blocks.isEmpty else { return remote }
        var result = blocks[0]
        for block in blocks.dropFirst() {
            guard let id = extractHostID(from: block), let localPath = localKeyPaths[id] else {
                result.append("[[host]]" + block)
                continue
            }
            result.append("[[host]]" + replaceKeyPath(in: block, with: localPath))
        }
        return result
    }

    private static func keyPathsByHostID(in text: String) -> [String: String] {
        var map: [String: String] = [:]
        for block in text.components(separatedBy: "[[host]]").dropFirst() {
            guard let id = extractHostID(from: block) else { continue }
            if let path = extractKeyPath(from: block), !path.isEmpty {
                map[id] = path
            }
        }
        return map
    }

    private static func extractHostID(from block: String) -> String? {
        for line in block.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("id =") {
                return parseStringValue(trimmed)
            }
        }
        return nil
    }

    private static func extractKeyPath(from block: String) -> String? {
        var inAuth = false
        for line in block.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[host.auth]" {
                inAuth = true
            } else if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inAuth = false
            } else if inAuth && trimmed.hasPrefix("key_path =") {
                return parseStringValue(trimmed)
            }
        }
        return nil
    }

    private static func replaceKeyPath(in block: String, with path: String) -> String {
        var inAuth = false
        var lines = block.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[host.auth]" {
                inAuth = true
            } else if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inAuth = false
            } else if inAuth && trimmed.hasPrefix("key_path =") {
                let prefix = line.prefix(while: { $0 != "=" })
                lines[index] = "\(prefix)= \"\(path)\""
                return lines.joined(separator: "\n")
            }
        }
        return block
    }

    private static func parseStringValue(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let value = String(line[line.index(after: eq)...])
            .trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, value.first == "\"", value.last == "\"" else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}

// MARK: - 同步器

/// iCloud Key-Value 配置同步:hosts + groups 版本化快照,last-write-wins,
/// 应用远端变更时抑制回环 push,保留本机私钥路径。
final class ConfigSync {
    static let shared = ConfigSync()

    private let kv: ConfigKVStore
    let hostsURL: URL
    let groupsURL: URL
    /// 应用远端变更落盘期间抑制本地 push,防止「远端到达 → 落盘 → push」回环。
    private var suppressPush = false

    init(
        kv: ConfigKVStore = UbiquitousConfigKVStore(),
        hostsURL: URL = AppPaths.hostsFileURL,
        groupsURL: URL = AppPaths.groupsFileURL
    ) {
        self.kv = kv
        self.hostsURL = hostsURL
        self.groupsURL = groupsURL
    }

    // MARK: 快照读写

    /// 从本地 TOML 文件组装当前快照;文件不存在时返回空快照(首次启动)。
    func makeSnapshot() -> ConfigSnapshot? {
        let hosts = (try? String(contentsOf: hostsURL, encoding: .utf8)) ?? ""
        let groups = (try? String(contentsOf: groupsURL, encoding: .utf8)) ?? ""
        return ConfigSnapshot(
            version: ConfigSnapshot.currentVersion,
            updatedAt: Date().timeIntervalSince1970,
            hosts: hosts,
            groups: groups
        )
    }

    /// 将当前本地配置 push 到 iCloud KV(抑制期间为 no-op)。
    func push() {
        guard !suppressPush, let snapshot = makeSnapshot() else { return }
        push(snapshot: snapshot)
    }

    /// 直接 push 指定快照(测试/迁移用)。
    func push(snapshot: ConfigSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        kv.set(data, forKey: ConfigSnapshot.kvKey)
        kv.synchronize()
    }

    /// 从 KV 读取最新快照;无数据或解码失败返回 nil。
    func pullSnapshot() -> ConfigSnapshot? {
        migrateLegacyIfNeeded()
        guard let data = kv.data(forKey: ConfigSnapshot.kvKey) else { return nil }
        return try? JSONDecoder().decode(ConfigSnapshot.self, from: data)
    }

    // MARK: 应用远端快照

    /// 根据 last-write-wins 应用远端快照到本地文件。
    /// - Returns: 是否确实写入了本地文件。
    @discardableResult
    func apply(snapshot: ConfigSnapshot) -> Bool {
        guard snapshot.version == ConfigSnapshot.currentVersion else { return false }
        guard shouldApply(remote: snapshot) else { return false }

        suppressPush = true
        defer { suppressPush = false }

        let localHosts = (try? String(contentsOf: hostsURL, encoding: .utf8)) ?? ""
        let mergedHosts = HostTOMLMerger.preserveLocalKeyPaths(local: localHosts, remote: snapshot.hosts)

        do {
            try mergedHosts.write(to: hostsURL, atomically: true, encoding: .utf8)
            try snapshot.groups.write(to: groupsURL, atomically: true, encoding: .utf8)
            Logger.shared.info("配置同步完成", module: LogModule.config)
            return true
        } catch {
            Logger.shared.error("配置同步失败; 原因=\(error.localizedDescription)", module: LogModule.config)
            return false
        }
    }

    /// 启动监听远端变更;收到通知后若应用成功则调用 `onChange`。
    func startObserving(onChange: @escaping () -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let snapshot = self.pullSnapshot(), self.apply(snapshot: snapshot) else { return }
            onChange()
        }
        kv.synchronize()
    }

    // MARK: 内部

    private func shouldApply(remote: ConfigSnapshot) -> Bool {
        guard let local = makeSnapshot() else { return true }
        // last-write-wins;时间戳相等时本地方案优先。
        return remote.updatedAt > local.updatedAt
    }

    /// 旧 key `panda-ssh.hosts.toml` 迁移到版本化快照。
    private func migrateLegacyIfNeeded() {
        guard let legacyData = kv.data(forKey: ConfigSnapshot.legacyKey) else { return }
        kv.set(nil, forKey: ConfigSnapshot.legacyKey)
        guard kv.data(forKey: ConfigSnapshot.kvKey) == nil else { return }
        let snapshot = ConfigSnapshot(
            version: ConfigSnapshot.currentVersion,
            updatedAt: Date().timeIntervalSince1970,
            hosts: String(data: legacyData, encoding: .utf8) ?? "",
            groups: ""
        )
        push(snapshot: snapshot)
    }
}
