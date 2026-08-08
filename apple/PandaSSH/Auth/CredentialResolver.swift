import Foundation

/// 凭据解析结果：密码或密钥口令（从钥匙串读取），或提示需要手动输入。
enum ResolvedCredential: Equatable {
    /// 已保存的凭据，可直接用于连接。
    case available(String)
    /// 未保存凭据，需要为该会话手动输入。
    case needsManualInput
}

/// 按主机认证方式解析 password / passphrase。
/// 真实后端从钥匙串读取；测试注入 keychain fake。
struct CredentialResolver {
    let keychain: KeychainService

    /// 解析指定主机的凭据。
    /// - Parameters:
    ///   - host: UI 层主机模型。
    ///   - manualPassword: 当前标签页手动输入的密码（会话作用域），优先于钥匙串。
    /// - Returns: 可用凭据或需手动输入。
    func resolve(for host: HostEntry, manualPassword: String? = nil) -> ResolvedCredential {
        if host.auth == .password {
            if let manual = manualPassword, !manual.isEmpty {
                return .available(manual)
            }
            guard host.passwordSaved else { return .needsManualInput }
            if let secret = keychain.read(for: "host.\(host.id).password"), !secret.isEmpty {
                return .available(secret)
            }
            return .needsManualInput
        }

        // 密钥认证：口令可选；无保存口令时返回空字符串（表示无钥匙口令）。
        guard host.passphraseSaved else { return .available("") }
        if let secret = keychain.read(for: "host.\(host.id).passphrase"), !secret.isEmpty {
            return .available(secret)
        }
        return .available("")
    }

    /// 获取连接所需的 FFI 参数。
    /// - Returns: `(password, passphrase)`；密码未保存且未手动输入时返回 nil。
    func connectionSecrets(for host: HostEntry, manualPassword: String? = nil) -> (password: String?, passphrase: String?)? {
        switch resolve(for: host, manualPassword: manualPassword) {
        case .available(let secret):
            if host.auth == .password {
                return (secret, nil)
            } else {
                return (nil, secret)
            }
        case .needsManualInput:
            return nil
        }
    }
}
