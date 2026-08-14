import Foundation

/// 真实后端:主机与分组配置走 Rust FFI(hosts.toml / groups.toml),
/// 密钥材料走同步钥匙串,iCloud Key-Value 同步 hosts.toml。
/// 代码片段暂无真实存储,以内存空实现占位,接口与 Mock 一致,
/// 换实现时 View 不需要改动。
final class PandaCoreBackend: AppBackend {
    private(set) var startupError: String?
    var onRemoteChange: (() -> Void)?

    /// Reject 探测缓存:hostID → 呈现密钥与指纹(信任后移除)。
    /// 只从主 actor 访问(AppModel 的调用路径)。
    private var presentedKeys: [String: PresentedHostKey] = [:]
    /// 钥匙串服务；生产环境默认系统钥匙串，测试可注入内存 fake。
    private let keychain: KeychainService

    init(keychain: KeychainService = SystemKeychain.shared) {
        self.keychain = keychain
        do {
            try PandaCoreBridge.shared.start()
            try PandaCoreBridge.shared.initializeSnippets(at: AppPaths.snippetsDirectoryURL)
            if let remote = ConfigSync.shared.pullSnapshot() {
                _ = ConfigSync.shared.apply(snapshot: remote)
            }
            ConfigSync.shared.startObserving { [weak self] in
                self?.onRemoteChange?()
            }
            Logger.shared.info("FFI 初始化成功", module: LogModule.ffi)
        } catch {
            startupError = error.localizedDescription
            Logger.shared.error("FFI 初始化失败; 原因=\(error.localizedDescription)", module: LogModule.ffi)
        }
    }

    // MARK: 主机(FFI + 钥匙串 + 同步)

    func allHosts() -> [HostEntry] {
        (try? PandaCoreBridge.shared.allHosts().map(HostEntry.init(record:)))?
            .map(enrichWithRecordedFingerprint) ?? []
    }

    /// 用 known_hosts 的真实记录填充指纹与算法(详情页展示、preconnect 决策用);
    /// 无记录或查询失败保持 nil(未验证)。
    private func enrichWithRecordedFingerprint(_ host: HostEntry) -> HostEntry {
        var host = host
        guard let status = try? PandaCoreBridge.shared.recordedHostKeyStatus(host: host.address, port: host.port),
              case .known(let fingerprint, let keyType) = status else { return host }
        host.fingerprint = fingerprint
        host.fingerprintAlgorithm = keyType
        return host
    }

    @discardableResult
    func saveHost(_ host: HostEntry, password: String?, passphrase: String?) -> Bool {
        // 密钥材料先写钥匙串,失败则中止保存——否则 ref 会落进 hosts.toml
        // 而密钥丢失(与重构前 HostEditView 的行为一致)。
        var passwordSaved = false
        var passphraseSaved = false
        switch host.auth {
        case .password where host.passwordSaved:
            if let password, !password.isEmpty {
                guard keychain.save(secret: password, for: "host.\(host.id).password") else { return false }
                passwordSaved = true
            } else if existingPasswordRef(for: host.id) != nil || keychainHasSecret(for: host.id, suffix: "password") {
                // 编辑场景:未输入新密码且开关保持打开 → 保留已有 ref
                passwordSaved = true
            }
        case .password:
            // 开关关闭：若此前保存过，清除钥匙串与 config 中的 ref。
            if existingPasswordRef(for: host.id) != nil || keychainHasSecret(for: host.id, suffix: "password") {
                keychain.delete(for: "host.\(host.id).password")
            }
        case .publicKey where host.passphraseSaved:
            if let passphrase, !passphrase.isEmpty {
                guard keychain.save(secret: passphrase, for: "host.\(host.id).passphrase") else { return false }
                passphraseSaved = true
            } else if existingPassphraseRef(for: host.id) != nil || keychainHasSecret(for: host.id, suffix: "passphrase") {
                passphraseSaved = true
            }
        case .publicKey:
            if existingPassphraseRef(for: host.id) != nil || keychainHasSecret(for: host.id, suffix: "passphrase") {
                keychain.delete(for: "host.\(host.id).passphrase")
            }
        }
        var entry = host
        entry.passwordSaved = passwordSaved
        entry.passphraseSaved = passphraseSaved
        do {
            try PandaCoreBridge.shared.save(host: entry.toConfigRecord())
            pushConfig()
            return true
        } catch {
            startupError = error.localizedDescription
            return false
        }
    }

    func deleteHost(id: String) {
        do {
            try PandaCoreBridge.shared.delete(id: id)
            // 级联删除主机凭据;ref 命名与 HostEditView 一致,删不存在项是 no-op。
            keychain.delete(for: "host.\(id).password")
            keychain.delete(for: "host.\(id).passphrase")
            pushConfig()
        } catch {
            startupError = error.localizedDescription
        }
    }

    func moveHost(id: String, toGroup groupID: String?) {
        guard var record = configRecord(for: id) else { return }
        record.groupId = groupID
        do {
            try PandaCoreBridge.shared.save(host: record)
            pushConfig()
        } catch {
            startupError = error.localizedDescription
        }
    }

    func hostKeyStatus(for hostID: String) -> HostKeyGateStatus {
        guard let record = configRecord(for: hostID) else { return .unknown }
        guard let status = try? PandaCoreBridge.shared.recordedHostKeyStatus(host: record.host, port: record.port) else {
            return .unknown
        }
        switch status {
        case .known: return .known
        case .unknown: return .unknown
        }
    }

    /// 以 Reject 策略探测未知主机,捕获服务端呈现的密钥与指纹。
    /// 返回 key 表示需要 TOFU 确认;返回 nil 表示已知/已信任;
    /// 抛出 HostKeyMismatchError 表示密钥变更;其他错误交给连接阶段处理。
    func probePresentedKey(for hostID: String) async throws -> PresentedHostKey? {
        guard let record = configRecord(for: hostID) else { return nil }
        do {
            // 探测仅取 host key,无需真实凭据(Unknown 时 host key check 在认证前失败)。
            _ = try PandaCoreBridge.shared.checkConnection(
                of: record, password: nil, passphrase: nil, trustOnFirstUse: false
            )
            return nil
        } catch {
            guard let panda = error as? PandaError else { throw error }
            switch panda {
            case .UnknownHostKey(host: let host, presented: let presented, fingerprint: let fingerprint):
                _ = host
                let key = PresentedHostKey(key: presented, fingerprint: fingerprint)
                presentedKeys[hostID] = key
                return key
            case .HostKeyMismatch(storedFingerprint: let stored, presentedFingerprint: let presented):
                presentedKeys[hostID] = PresentedHostKey(key: "", fingerprint: presented)
                throw HostKeyMismatchError(storedFingerprint: stored, presentedFingerprint: presented)
            default:
                throw error
            }
        }
    }

    func trustHost(id: String) {
        guard let record = configRecord(for: id),
              let key = presentedKeys[id]?.key, !key.isEmpty else { return }
        do {
            try PandaCoreBridge.shared.acceptPresentedHostKey(host: record.host, port: record.port, key: key)
            presentedKeys.removeValue(forKey: id)
        } catch {
            startupError = error.localizedDescription
        }
    }

    func presentedFingerprint(for hostID: String) -> String? {
        presentedKeys[hostID]?.fingerprint
    }

    func configRecord(for hostID: String) -> HostConfigRecord? {
        try? PandaCoreBridge.shared.allHosts().first { $0.id == hostID }
    }

    func clearKeychainCredentials(for hostID: String, auth: AuthKind) {
        if auth == .password {
            keychain.delete(for: "host.\(hostID).password")
        } else {
            keychain.delete(for: "host.\(hostID).passphrase")
        }
        // 同步：把 config 里的 ref 也清掉，避免悬空引用。
        guard var record = configRecord(for: hostID) else { return }
        switch record.auth {
        case .password:
            record.auth = .password(passwordRef: nil)
        case .publicKey(let path, _):
            record.auth = .publicKey(keyPath: path, passphraseRef: nil)
        }
        do {
            try PandaCoreBridge.shared.save(host: record)
            pushConfig()
        } catch {
            startupError = error.localizedDescription
        }
    }

    // MARK: 分组(FFI,groups.toml)

    func allGroups() -> [HostGroup] {
        (try? PandaCoreBridge.shared.allGroups().map {
            HostGroup(id: $0.id, name: $0.name, parentID: $0.parentId)
        }) ?? []
    }

    @discardableResult
    func createGroup(name: String, parentID: String?) -> HostGroup {
        // id 由 Swift 侧生成(FFI save_group 空 id 也会生成,但协议要求返回完整分组)
        let group = HostGroup(id: UUID().uuidString, name: name, parentID: parentID)
        do {
            try PandaCoreBridge.shared.save(group: GroupRecord(id: group.id, name: name, parentId: parentID))
            pushConfig()
        } catch {
            startupError = error.localizedDescription
        }
        return group
    }

    func renameGroup(id: String, name: String) {
        guard let existing = try? PandaCoreBridge.shared.allGroups().first(where: { $0.id == id }) else { return }
        do {
            try PandaCoreBridge.shared.save(group: GroupRecord(id: id, name: name, parentId: existing.parentId))
            pushConfig()
        } catch {
            startupError = error.localizedDescription
        }
    }

    func deleteGroup(id: String) {
        do {
            // 级联在 Rust core 完成:组内(含子分组)主机 group_id 清空、子分组一并删除;
            // hosts.toml 被改写,需要重新上传同步
            try PandaCoreBridge.shared.removeGroup(id: id)
            pushConfig()
        } catch {
            startupError = error.localizedDescription
        }
    }

    // MARK: 代码片段(Rust FFI)

    func allSnippets() -> [Snippet] {
        (try? PandaCoreBridge.shared.allSnippets().map(Snippet.init(record:))) ?? []
    }

    func saveSnippet(_ snippet: Snippet) {
        do {
            try PandaCoreBridge.shared.save(snippet: snippet.toSnippetRecord())
        } catch {
            startupError = error.localizedDescription
        }
    }

    func deleteSnippet(id: String) {
        do {
            try PandaCoreBridge.shared.removeSnippet(name: id)
        } catch {
            startupError = error.localizedDescription
        }
    }

    // MARK: 同步(行为与重构前 AppModel 一致)

    /// 本地保存/删除后上传配置快照。
    private func pushConfig() {
        ConfigSync.shared.push()
    }

    private func existingPasswordRef(for id: String) -> String? {
        guard case .password(let ref) = configRecord(for: id)?.auth else { return nil }
        return ref
    }

    private func existingPassphraseRef(for id: String) -> String? {
        guard case .publicKey(_, let ref) = configRecord(for: id)?.auth else { return nil }
        return ref
    }

    private func keychainHasSecret(for id: String, suffix: String) -> Bool {
        keychain.read(for: "host.\(id).\(suffix)") != nil
    }
}

// MARK: - Snippet <-> SnippetRecord 互转

extension Snippet {
    /// Swift 层把 summary + code 拼成 Rust 期望的 Markdown body。
    /// 格式与 `panda-core::Snippet::to_markdown` 一致,便于 Rust 侧再解析。
    func toSnippetRecord() -> SnippetRecord {
        let body = """
        ## 说明
        \(summary)

        ## 代码
        ```
        \(code)
        ```
        """
        return SnippetRecord(name: id, title: title, tags: tags, body: body)
    }

    /// 从 Rust `SnippetRecord` 还原;`body` 按「## 说明」/「## 代码」解析,
    /// 解析失败时 summary/code 整体回退到 body。
    init(record: SnippetRecord) {
        let (s, c) = Self.parse(body: record.body)
        self.init(id: record.name, title: record.title, tags: record.tags, summary: s, code: c)
    }

    private static func parse(body: String) -> (summary: String, code: String) {
        let markerNote = "## 说明"
        let markerCode = "## 代码"
        guard let noteRange = body.range(of: markerNote) else {
            return ("", body)
        }
        let afterNote = String(body[noteRange.upperBound...])
        guard let codeRange = afterNote.range(of: markerCode) else {
            return (afterNote.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        let summaryPart = String(afterNote[..<codeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var codePart = String(afterNote[codeRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉首尾的代码块标记行(如 ```bash / ```)
        if codePart.hasPrefix("```") {
            if let newline = codePart.firstIndex(of: "\n") {
                codePart = String(codePart[newline...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                codePart = ""
            }
        }
        if codePart.hasSuffix("```") {
            codePart = String(codePart.prefix(codePart.count - 3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (summaryPart, codePart)
    }
}
