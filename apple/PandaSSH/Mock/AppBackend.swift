import Foundation

/// known_hosts 记录状态(preconnect 决策依据,文件级查询、无需连接)。
/// 真实的「密钥已变更」只能在连接握手时判定,以 HostKeyMismatch 错误呈现。
enum HostKeyGateStatus: Equatable {
    /// 无记录 → 首次连接需 TOFU 确认
    case unknown
    /// 已有记录 → 直接连接
    case known
}

/// Reject 探测未知主机拿到的呈现密钥信息(不落盘;
/// 用户在确认框点「信任」后,呈现的 key 经 accept_unknown_host_key 写入 known_hosts)。
struct PresentedHostKey: Equatable {
    /// 服务端呈现的 OpenSSH 公钥串(ssh-ed25519 AAAA…)
    let key: String
    /// SHA256 冒号分隔指纹
    let fingerprint: String
}

/// Reject 探测时发现主机密钥与本地记录不一致,供 PreconnectGate 直接展示告警。
struct HostKeyMismatchError: Error, Equatable {
    let storedFingerprint: String
    let presentedFingerprint: String
}

/// 后端抽象:主机/分组/代码片段的增删改查。View 与 AppModel 只依赖本协议,
/// Mock 与真实实现可以互换而不改 View。
///
/// 实现方:
/// - `MockBackend`(DEBUG 默认):全内存,预置原型演示数据,不碰 FFI/钥匙串/iCloud。
/// - `PandaCoreBackend`(Release 默认):主机、分组与代码片段走 Rust FFI + 钥匙串 + iCloud 同步。
protocol AppBackend: AnyObject {
    /// 启动阶段的错误(如 Rust store 初始化失败),无错为 nil。
    var startupError: String? { get }
    /// 远端配置变更回调(真实后端的 iCloud 同步用);实现方在主队列调用。
    var onRemoteChange: (() -> Void)? { get set }

    // MARK: 主机

    func allHosts() -> [HostEntry]
    /// 新增或更新主机(按 id 判断)。password/passphrase 为明文密钥材料:
    /// 真实后端负责写入钥匙串,Mock 后端直接忽略。返回是否成功。
    @discardableResult
    func saveHost(_ host: HostEntry, password: String?, passphrase: String?) -> Bool
    func deleteHost(id: String)
    /// 改变主机归属分组;groupID 为 nil 表示移回根级。
    func moveHost(id: String, toGroup groupID: String?)
    /// TOFU:信任对方出示的主机密钥,把探测呈现的 key 写入 known_hosts。
    func trustHost(id: String)
    /// 「对方本次出示的指纹」(TOFU / 密钥变更对话框用);
    /// mock 来自演示数据,真实实现来自 Reject 探测的缓存,未探测返回 nil。
    func presentedFingerprint(for hostID: String) -> String?
    /// known_hosts 是否已有该主机记录(真实模式 preconnect 决策依据)。
    func hostKeyStatus(for hostID: String) -> HostKeyGateStatus
    /// 以 Reject 策略探测未知主机,返回呈现密钥与指纹(不落盘);
    /// 仅应在 hostKeyStatus == .unknown 时调用。返回 nil 表示探测期间
    /// 密钥已被信任(并发确认),无需再弹框。探测失败(超时/网络)抛错。
    func probePresentedKey(for hostID: String) async throws -> PresentedHostKey?
    /// 提供 FFI 侧的主机配置(阶段二的终端/SFTP 视图仍基于 HostConfigRecord)。
    func configRecord(for hostID: String) -> HostConfigRecord?
    /// 清除主机已保存的凭据（密码或密钥口令），不影响主机配置本身。
    func clearKeychainCredentials(for hostID: String, auth: AuthKind)

    // MARK: 分组

    func allGroups() -> [HostGroup]
    @discardableResult
    func createGroup(name: String, parentID: String?) -> HostGroup
    func renameGroup(id: String, name: String)
    /// 删除分组:组内(含子分组)主机移回根级,子分组一并删除。
    func deleteGroup(id: String)

    // MARK: 代码片段

    func allSnippets() -> [Snippet]
    func saveSnippet(_ snippet: Snippet)
    func deleteSnippet(id: String)
}
