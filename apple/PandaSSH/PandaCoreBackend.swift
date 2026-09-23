import Foundation

/// 真实后端:主机与分组配置走 Rust FFI(hosts.toml / groups.toml),
/// 密钥材料走 Rust 本地凭据仓库。代码片段暂无真实存储,以内存空实现占位,
/// 接口与 Mock 一致,换实现时 View 不需要改动。
final class PandaCoreBackend: AppBackend {
    private(set) var startupError: String?

    /// Reject 探测缓存:hostID → 呈现密钥与指纹(信任后移除)。
    /// 只从主 actor 访问(AppModel 的调用路径)。
    private var presentedKeys: [String: PresentedHostKey] = [:]
    init() {
        do {
            try PandaCoreBridge.shared.start()
            Logger.shared.info("FFI 初始化成功", module: LogModule.ffi)
        } catch {
            startupError = error.localizedDescription
            Logger.shared.error("FFI 初始化失败; 原因=\(error.localizedDescription)", module: LogModule.ffi)
        }
    }

    // MARK: 主机（FFI + 本地凭据仓库 + 同步）

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
        do {
            _ = try PandaCoreBridge.shared.saveHostComplete(
                host: host.toConfigRecord(),
                password: credentialIntent(
                    enabled: host.auth == .password && host.passwordSaved,
                    secret: password
                ),
                passphrase: credentialIntent(
                    enabled: host.auth == .publicKey && host.passphraseSaved,
                    secret: passphrase
                )
            )
            return true
        } catch {
            startupError = error.localizedDescription
            return false
        }
    }

    private func credentialIntent(enabled: Bool, secret: String?) -> CredentialIntentEnum {
        guard enabled else { return .remove }
        guard let secret, !secret.isEmpty else { return .preserve }
        return .set(secret: secret)
    }

    func deleteHost(id: String) {
        do {
            try PandaCoreBridge.shared.delete(id: id)
            // 级联删除主机凭据;ref 命名与 HostEditView 一致,删不存在项是 no-op。
        } catch {
            startupError = error.localizedDescription
        }
    }

    func moveHost(id: String, toGroup groupID: String?) {
        guard var record = configRecord(for: id) else { return }
        record.groupId = groupID
        do {
            try PandaCoreBridge.shared.save(host: record)
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

    func cachePresentedKey(_ key: PresentedHostKey, for hostID: String) {
        presentedKeys[hostID] = key
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

    func clearCredentials(for hostID: String, auth: AuthKind) {
        // 先清除配置引用，再删除秘密；删除失败也不会遗留悬空引用。
        guard var record = configRecord(for: hostID) else { return }
        switch record.auth {
        case .password:
            record.auth = .password(passwordRef: nil)
        case .publicKey(let path, _):
            record.auth = .publicKey(keyPath: path, passphraseRef: nil)
        }
        do {
            try PandaCoreBridge.shared.save(host: record)
            let suffix = auth == .password ? "password" : "passphrase"
            try PandaCoreBridge.shared.removeCredential(reference: "host.\(hostID).\(suffix)")
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
        } catch {
            startupError = error.localizedDescription
        }
        return group
    }

    func renameGroup(id: String, name: String) {
        guard let existing = try? PandaCoreBridge.shared.allGroups().first(where: { $0.id == id }) else { return }
        do {
            try PandaCoreBridge.shared.save(group: GroupRecord(id: id, name: name, parentId: existing.parentId))
        } catch {
            startupError = error.localizedDescription
        }
    }

    func deleteGroup(id: String) {
        do {
            // 级联在 Rust core 完成:组内(含子分组)主机 group_id 清空、子分组一并删除。
            try PandaCoreBridge.shared.removeGroup(id: id)
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

    private func existingPasswordRef(for id: String) -> String? {
        guard case .password(let ref) = configRecord(for: id)?.auth else { return nil }
        return ref
    }

    private func existingPassphraseRef(for id: String) -> String? {
        guard case .publicKey(_, let ref) = configRecord(for: id)?.auth else { return nil }
        return ref
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
