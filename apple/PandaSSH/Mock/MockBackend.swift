import Foundation

/// 全内存 Mock 后端:预置原型(prototype/index.html)的演示数据,
/// 增删改只在内存生效,不触碰 FFI、钥匙串与 iCloud。
/// 让阶段一的 UI 可以在 Xcode 里完整验证;阶段二连接流程同样以它为数据源。
final class MockBackend: AppBackend {
    let startupError: String? = nil
    var onRemoteChange: (() -> Void)?

    private var hosts: [HostEntry]
    private var groups: [HostGroup]
    private var snippets: [Snippet]

    init(hosts: [HostEntry], groups: [HostGroup], snippets: [Snippet]) {
        self.hosts = hosts
        self.groups = groups
        self.snippets = snippets
    }

    /// 原型演示数据:7 台主机、3 个分组(生产环境 → 华东 / 测试环境)、3 个片段。
    static func demo() -> MockBackend {
        MockBackend(hosts: DemoData.hosts, groups: DemoData.groups, snippets: DemoData.snippets)
    }

    // MARK: 主机

    func allHosts() -> [HostEntry] { hosts }

    @discardableResult
    func saveHost(_ host: HostEntry, password: String?, passphrase: String?) -> Bool {
        // Mock 模式不落密钥材料:password/passphrase 直接丢弃,
        // 仅以 passwordSaved/passphraseSaved 标记「已存钥匙串」的演示状态。
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        return true
    }

    func deleteHost(id: String) {
        hosts.removeAll { $0.id == id }
    }

    func moveHost(id: String, toGroup groupID: String?) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].groupID = groupID
    }

    func trustHost(id: String) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].fingerprint = presentedFingerprint(for: id) ?? hosts[index].fingerprint
        hosts[index].demo = nil
    }

    func presentedFingerprint(for hostID: String) -> String? {
        DemoData.presentedFingerprints[hostID]
    }

    func hostKeyStatus(for hostID: String) -> HostKeyGateStatus {
        hosts.first { $0.id == hostID }?.fingerprint == nil ? .unknown : .known
    }

    func probePresentedKey(for hostID: String) async throws -> PresentedHostKey? {
        // mock 无真实握手:演示数据有出示指纹即返回,否则视为已被信任
        guard let fingerprint = DemoData.presentedFingerprints[hostID] else { return nil }
        return PresentedHostKey(key: "", fingerprint: fingerprint)
    }

    func configRecord(for hostID: String) -> HostConfigRecord? {
        guard let host = hosts.first(where: { $0.id == hostID }) else { return nil }
        return host.toConfigRecord()
    }

    func clearKeychainCredentials(for hostID: String, auth: AuthKind) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        if auth == .password {
            hosts[index].passwordSaved = false
        } else {
            hosts[index].passphraseSaved = false
        }
    }

    // MARK: 分组

    func allGroups() -> [HostGroup] { groups }

    @discardableResult
    func createGroup(name: String, parentID: String?) -> HostGroup {
        let group = HostGroup(id: "g-\(UUID().uuidString)", name: name, parentID: parentID)
        groups.append(group)
        return group
    }

    func renameGroup(id: String, name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name
    }

    func deleteGroup(id: String) {
        let doomed = GroupTree.descendantIDs(of: id, in: groups)
        // 组内(含子分组)主机移回根级,主机配置完整保留
        for index in hosts.indices where hosts[index].groupID.map({ doomed.contains($0) }) == true {
            hosts[index].groupID = nil
        }
        groups.removeAll { doomed.contains($0.id) }
    }

    // MARK: 代码片段

    func allSnippets() -> [Snippet] { snippets }

    func saveSnippet(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
    }

    func deleteSnippet(id: String) {
        snippets.removeAll { $0.id == id }
    }
}

// MARK: - HostEntry ↔ HostConfigRecord 互转

extension HostEntry {
    /// 转为 FFI 侧配置;引用 key 按「host.<id>.password/.passphrase」约定,
    /// 与真实后端及钥匙串读写保持一致。
    func toConfigRecord() -> HostConfigRecord {
        let auth: AuthMethodEnum = switch auth {
        case .password:
                .password(passwordRef: passwordSaved ? "host.\(id).password" : nil)
        case .publicKey:
                .publicKey(
                    keyPath: keyPath,
                    passphraseRef: passphraseSaved ? "host.\(id).passphrase" : nil
                )
        }
        return HostConfigRecord(
            id: id,
            name: name,
            host: address,
            port: port,
            username: username,
            auth: auth,
            notes: note.isEmpty ? nil : note,
            groupId: groupID
        )
    }

    /// 从 FFI 侧配置还原;指纹/演示标记无真实来源,置空。
    init(record: HostConfigRecord) {
        id = record.id
        name = record.name
        address = record.host
        port = record.port
        username = record.username
        note = record.notes ?? ""
        groupID = record.groupId
        fingerprint = nil
        fingerprintAlgorithm = "ssh-ed25519"
        demo = nil
        switch record.auth {
        case .password(let ref):
            auth = .password
            keyPath = ""
            passwordSaved = ref != nil
            passphraseSaved = false
        case .publicKey(let path, let ref):
            auth = .publicKey
            keyPath = path
            passwordSaved = false
            passphraseSaved = ref != nil
        }
    }
}

// MARK: - 演示数据(与 prototype/index.html 中的 state 一一对应)

enum DemoData {
    /// 原型中的指纹常量
    enum FP {
        static let webprod = "SHA256:9c:4e:ab:12:77:f0:3d:58:aa:21:6b:90:e4:18:c2:05:7a:33:d9:01:84:5f:26:b8:1c:7d:40:e3:59:0a:6d:11"
        static let webbackup = "SHA256:1a:2b:3c:4d:5e:6f:70:81:92:a3:b4:c5:d6:e7:f8:09:1b:2c:3d:4e:5f:60:71:82:93:a4:b5:c6:d7:e8:f9"
        static let legacyOld = "SHA256:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"
        static let legacyNew = "SHA256:de:ad:be:ef:12:34:56:78:9a:bc:de:f0:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55"
        static let newtoy = "SHA256:f0:e1:d2:c3:b4:a5:96:87:78:69:5a:4b:3c:2d:1e:0f:aa:bb:cc:dd:ee:ff:11:22:33:44:55:66:77:88:99:00"
        static let staging = "SHA256:55:44:33:22:11:00:ff:ee:dd:cc:bb:aa:99:88:77:66:55:44:33:22:11:00:ff:ee:dd:cc:bb:aa:99:88:77:66"
        static let manual = "SHA256:77:66:55:44:33:22:11:00:aa:bb:cc:dd:ee:ff:99:88:77:66:55:44:33:22:11:00:aa:bb:cc:dd:ee:ff:99:88"
    }

    static let groups: [HostGroup] = [
        HostGroup(id: "g-prod", name: "生产环境", parentID: nil),
        HostGroup(id: "g-east", name: "华东", parentID: "g-prod"),
        HostGroup(id: "g-test", name: "测试环境", parentID: nil),
    ]

    static let hosts: [HostEntry] = [
        HostEntry(
            id: "h-webprod", name: "web-prod", address: "203.0.113.10", port: 22,
            username: "luowenqiang", note: "线上主 Web 服务器，Nginx + Node",
            groupID: "g-east", auth: .publicKey, keyPath: "~/.ssh/id_ed25519",
            passwordSaved: false, passphraseSaved: false,
            fingerprint: FP.webprod, fingerprintAlgorithm: "ssh-ed25519", demo: nil
        ),
        HostEntry(
            id: "h-webbackup", name: "web-backup", address: "203.0.113.11", port: 22,
            username: "luowenqiang", note: "备用节点",
            groupID: "g-east", auth: .password,
            passwordSaved: true,
            fingerprint: FP.webbackup, fingerprintAlgorithm: "ssh-ed25519", demo: nil
        ),
        HostEntry(
            id: "h-legacy", name: "legacy-db", address: "192.0.2.55", port: 22,
            username: "dba", note: "老旧数据库，疑似被重装过",
            groupID: "g-prod", auth: .password,
            passwordSaved: true,
            fingerprint: FP.legacyOld, fingerprintAlgorithm: "ssh-rsa", demo: .mismatch
        ),
        HostEntry(
            id: "h-staging", name: "staging-01", address: "198.51.100.20", port: 2222,
            username: "deploy", note: "预发环境",
            groupID: "g-test", auth: .publicKey, keyPath: "~/.ssh/id_rsa",
            fingerprint: FP.staging, fingerprintAlgorithm: "ssh-ed25519", demo: nil
        ),
        HostEntry(
            id: "h-newtoy", name: "new-toy", address: "10.8.0.6", port: 22,
            username: "pi", note: "新入手的开发板，从未连接",
            groupID: nil, auth: .password,
            passwordSaved: true,
            fingerprint: nil, fingerprintAlgorithm: "ssh-ed25519", demo: .unknown
        ),
        HostEntry(
            id: "h-offline", name: "offline-srv", address: "10.255.255.1", port: 22,
            username: "ops", note: "已下线的机器，演示超时",
            groupID: nil, auth: .publicKey, keyPath: "~/.ssh/id_ed25519",
            fingerprint: FP.staging, fingerprintAlgorithm: "ssh-ed25519", demo: .offline
        ),
        HostEntry(
            id: "h-manual", name: "manual-auth", address: "172.16.9.9", port: 22,
            username: "luowenqiang", note: "密码未存钥匙串，每次手动输入",
            groupID: nil, auth: .password,
            passwordSaved: false,
            fingerprint: FP.manual, fingerprintAlgorithm: "ssh-ed25519", demo: .manual
        ),
    ]

    /// 各主机「本次出示的指纹」(TOFU / 密钥变更对话框演示用)
    static let presentedFingerprints: [String: String] = [
        "h-newtoy": FP.newtoy,
        "h-legacy": FP.legacyNew,
    ]

    static let snippets: [Snippet] = [
        Snippet(
            id: "s1", title: "查看磁盘占用 Top 10", tags: ["运维", "磁盘"],
            summary: "递归统计当前目录并按大小排序，快速定位占空间的大户。",
            code: "du -ah . | sort -rh | head -n 10"
        ),
        Snippet(
            id: "s2", title: "实时跟踪 Nginx 错误日志", tags: ["日志", "Nginx"],
            summary: "跟踪错误日志并高亮 5xx。",
            code: "tail -f /var/log/nginx/error.log | grep --line-buffered ' 5[0-9][0-9] '"
        ),
        Snippet(
            id: "s3", title: "批量重启 systemd 服务", tags: ["systemd"],
            summary: "一次性重启多个服务并查看状态。",
            code: "for s in nginx php-fpm redis; do\n  sudo systemctl restart $s\n  systemctl is-active $s\ndone"
        ),
    ]
}
