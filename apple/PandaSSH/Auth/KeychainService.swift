import Foundation
import Security

/// 钥匙串服务协议：对凭据的 save/read/delete 做抽象，
/// 生产环境走系统钥匙串，测试环境注入内存 fake。
protocol KeychainService {
    @discardableResult
    func save(secret: String, for ref: String) -> Bool
    func read(for ref: String) -> String?
    func delete(for ref: String)
}

/// 系统钥匙串实现：同步钥匙串（kSecAttrSynchronizable），
/// 允许 iCloud Keychain 跨设备漫游；不设显式 access group。
final class SystemKeychain: KeychainService {
    static let shared = SystemKeychain()

    @discardableResult
    func save(secret: String, for ref: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: ref,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrSynchronizable as String] = true
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func read(for ref: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: ref,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(for ref: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: ref,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 内存 fake：用于 Swift 单元测试，不触碰真实钥匙串。
final class InMemoryKeychain: KeychainService {
    private var storage: [String: String] = [:]
    private let queue = DispatchQueue(label: "panda.in-memory-keychain")

    @discardableResult
    func save(secret: String, for ref: String) -> Bool {
        queue.sync { storage[ref] = secret }
        return true
    }

    func read(for ref: String) -> String? {
        queue.sync { storage[ref] }
    }

    func delete(for ref: String) {
        _ = queue.sync { storage.removeValue(forKey: ref) }
    }

    func clear() {
        queue.sync { storage.removeAll() }
    }
}
