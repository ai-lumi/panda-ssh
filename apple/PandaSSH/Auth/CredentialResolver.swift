import Foundation

/// 凭据解析结果：密码或私钥口令（从本地凭据文件读取），或提示需要手动输入。
enum ResolvedCredential: Equatable {
    /// 已保存的凭据，可直接用于连接。
    case available(String)
    /// 未保存凭据，需要为该会话手动输入。
    case needsManualInput
}

/// 按主机认证方式解析 password / passphrase。
/// 真实后端从配置目录内的凭据文件读取；测试可注入内存 fake。
struct CredentialResolver {
    private let readSecret: (String) -> String?

    init(readSecret: @escaping (String) -> String?) {
        self.readSecret = readSecret
    }

    static func localStore() -> CredentialResolver {
        CredentialResolver(readSecret: { reference in
            try? PandaCoreBridge.shared.storedCredential(reference: reference)
        })
    }

    /// 解析指定主机的凭据。
    /// - Parameters:
    ///   - host: UI 层主机模型。
    ///   - manualSecret: 当前标签页手动输入的密码或私钥口令（会话作用域），优先于已保存值。
    /// - Returns: 可用凭据或需手动输入。
    func resolve(for host: HostEntry, manualSecret: String? = nil) -> ResolvedCredential {
        if host.auth == .password {
            if let manual = manualSecret, !manual.isEmpty {
                return .available(manual)
            }
            guard host.passwordSaved else { return .needsManualInput }
            if let secret = readSecret("host.\(host.id).password"), !secret.isEmpty {
                return .available(secret)
            }
            return .needsManualInput
        }

        // 密钥认证：口令可选；未标记保存时返回空字符串（表示无口令）。
        if let manual = manualSecret, !manual.isEmpty {
            return .available(manual)
        }
        guard host.passphraseSaved else { return .available("") }
        if let secret = readSecret("host.\(host.id).passphrase"), !secret.isEmpty {
            return .available(secret)
        }
        // 主机标记为已保存口令、但文件中缺失时必须提示，不能带空口令连接后误报超时。
        return .needsManualInput
    }

    /// 获取连接所需的 FFI 参数。
    /// - Returns: `(password, passphrase)`；密码未保存且未手动输入时返回 nil。
    func connectionSecrets(for host: HostEntry, manualSecret: String? = nil) -> (password: String?, passphrase: String?)? {
        switch resolve(for: host, manualSecret: manualSecret) {
        case .available(let secret):
            if host.auth == .password {
                return (secret, nil)
            } else {
                return (nil, secret.isEmpty ? nil : secret)
            }
        case .needsManualInput:
            return nil
        }
    }
}
