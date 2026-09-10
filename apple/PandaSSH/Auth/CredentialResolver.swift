import Foundation

/// 凭据解析结果：密码或私钥口令，或提示需要手动输入。
enum ResolvedCredential: Equatable {
    /// 已保存或手动输入的凭据，可直接用于连接。
    case available(String)
    /// 未保存凭据，需要为该会话手动输入。
    case needsManualInput
}

/// 按主机认证方式解析 password / passphrase。
/// 手动输入（会话作用域）优先于已保存值；已保存值通过 Rust FFI 查询。
struct CredentialResolver {
    /// 解析指定主机的凭据。
    /// - Parameters:
    ///   - host: UI 层主机模型。
    ///   - manualSecret: 当前标签页手动输入的密码或私钥口令（会话作用域），优先于已保存值。
    /// - Returns: 可用凭据或需手动输入。
    func resolve(for host: HostEntry, manualSecret: String? = nil) -> ResolvedCredential {
        // 手动输入始终优先
        if let manual = manualSecret, !manual.isEmpty {
            return .available(manual)
        }

        // 通过 Rust FFI 查询已保存凭据
        guard let resolved = try? credentialResolve(hostId: host.id) else {
            return .needsManualInput
        }

        switch resolved {
        case .available(let password, let passphrase):
            if host.auth == .password {
                if let pw = password { return .available(pw) }
                return .needsManualInput
            } else {
                // 密钥认证：口令可选
                return .available(passphrase ?? "")
            }
        case .needsPassword:
            return .needsManualInput
        case .needsPassphrase:
            return .needsManualInput
        }
    }

    /// 获取连接所需的 FFI 参数。
    /// - Returns: `(password, passphrase)`；凭据不可用时返回 nil。
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
