import Foundation

/// 认证方式（与 FFI 的 AuthMethodEnum 对应，但不含凭据引用 key，
/// 引用与密钥材料的写入由后端在保存时负责)。
enum AuthKind: String, Equatable {
    case password
    case publicKey
}

/// 演示状态标记:驱动侧栏状态圆点与连接前的对话框演示。
/// 真实后端接入后,这些状态由实际连接结果取代。
enum DemoFlag: String, Equatable {
    /// 未验证过的主机 → 连接前弹 TOFU 指纹确认
    case unknown
    /// 主机密钥不匹配 → 连接前弹红色告警并阻断
    case mismatch
    /// 已下线 → 连接超时演示(阶段二终端用)
    case offline
    /// 密码未保存 → 每个标签页手动输入密码
    case manual
}

/// UI 层主机模型:聚合连接配置、备注、分组归属、指纹与演示标记。
/// View 只依赖本类型,后续换真实后端实现时 View 不需要改动。
struct HostEntry: Identifiable, Equatable {
    var id: String
    var name: String
    var address: String
    var port: UInt16
    var username: String
    var note = ""
    /// 所属分组;nil 表示根级
    var groupID: String?
    var auth: AuthKind = .password
    /// 密钥方式下的私钥路径
    var keyPath = ""
    /// 密码是否已保存到本地凭据文件
    var passwordSaved = false
    /// 私钥口令是否已保存到本地凭据文件
    var passphraseSaved = false
    /// 已记录的主机密钥指纹(SHA256 冒号格式);nil 表示未验证
    var fingerprint: String?
    var fingerprintAlgorithm = "ssh-ed25519"
    /// 演示标记(仅 mock 数据使用)
    var demo: DemoFlag?

    /// `user@host:port` 形式的副标题
    var subtitle: String { "\(username)@\(address):\(port)" }
}

/// 复制主机时允许预填的非敏感字段。
/// 凭据保存标记、主机密钥信任状态与演示状态均不随副本传递。
struct HostCopyDraft: Equatable {
    let name: String
    let address: String
    let port: UInt16
    let username: String
    let note: String
    let groupID: String?
    let auth: AuthKind
    let keyPath: String

    init(source: HostEntry) {
        name = source.name
        address = source.address
        port = source.port
        username = source.username
        note = source.note
        groupID = source.groupID
        auth = source.auth
        keyPath = source.keyPath
    }
}

/// 服务器分组:任意层级树形,parentID 为 nil 表示根级分组。
struct HostGroup: Identifiable, Equatable {
    var id: String
    var name: String
    var parentID: String?
}

/// 代码片段(规划中功能,当前仅存内存)。
struct Snippet: Identifiable, Equatable {
    var id: String
    var title: String
    var tags: [String]
    /// 说明文字
    var summary: String
    var code: String
}

/// 分组树纯函数工具:View 与后端共用。
enum GroupTree {
    /// 根级分组:parentID 为 nil,或 parent 已不存在(悬空 parent 降级为根级)。
    static func roots(of groups: [HostGroup]) -> [HostGroup] {
        groups.filter { group in
            guard let parent = group.parentID else { return true }
            return !groups.contains { $0.id == parent }
        }
    }

    static func children(of parentID: String, in groups: [HostGroup]) -> [HostGroup] {
        groups.filter { $0.parentID == parentID }
    }

    /// 「生产环境 / 华东」式的完整路径;nil 或未知 id 返回「根级」。
    /// 带 visited 集合防御脏数据里的环。
    static func path(of groupID: String?, in groups: [HostGroup]) -> String {
        var names: [String] = []
        var visited: Set<String> = []
        var current = groups.first { $0.id == groupID }
        while let group = current, !visited.contains(group.id) {
            visited.insert(group.id)
            names.insert(group.name, at: 0)
            current = groups.first { $0.id == group.parentID }
        }
        return names.isEmpty ? "根级" : names.joined(separator: " / ")
    }

    /// 分组及其全部后代分组的 id 集合(删除分组级联用)。
    static func descendantIDs(of groupID: String, in groups: [HostGroup]) -> Set<String> {
        var ids: Set<String> = [groupID]
        var changed = true
        while changed {
            changed = false
            for group in groups {
                if let parent = group.parentID, ids.contains(parent), !ids.contains(group.id) {
                    ids.insert(group.id)
                    changed = true
                }
            }
        }
        return ids
    }
}

/// 侧栏搜索过滤:匹配主机名/地址/用户名(大小写不敏感);
/// 分组路径命中时,该分组(含祖先分组命中时的子分组)下的主机一并显示。
enum HostSearch {
    static func filter(hosts: [HostEntry], groups: [HostGroup], query: String) -> [HostEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return hosts }
        return hosts.filter { host in
            host.name.lowercased().contains(q)
                || host.address.lowercased().contains(q)
                || host.username.lowercased().contains(q)
                || (host.groupID != nil
                    && GroupTree.path(of: host.groupID, in: groups).lowercased().contains(q))
        }
    }
}
