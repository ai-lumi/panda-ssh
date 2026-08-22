import Foundation

/// 终端会话状态机：连接中 → shell / failed。
/// 管理真实 SSH shell（`ShellConnection`）与 mock 演示模式。
/// 数据流由 TerminalTabView 的 SwiftTerm TerminalView 包装器读取 `connection`
/// 并双向桥接（用户输入 → write，远端输出 → feed）。
@MainActor
final class TerminalSessionStore: ObservableObject {
    /// 会话阶段。
    enum Phase: Equatable {
        case connecting
        case shell
        case failed
    }

    let host: HostEntry

    @Published private(set) var phase: Phase = .connecting
    /// 当前连接句柄；nil 表示尚未建立连接。
    /// 视图层（SwiftTerm TerminalView 包装器）据此启动读循环。
    @Published private(set) var connection: ShellConnection?
    /// 连接尝试序号:重试时 +1,视图据此重启连接流程。
    @Published private(set) var attempt = 0

    /// 重试时复用的连接参数。
    private var pendingRecord: HostConfigRecord?
    private var pendingPassword: String?
    private var pendingPassphrase: String?

    /// 连接打开器注入点：返回 FFI shell handle。默认真实实现 `PandaShellConnection.open`；
    /// 测试注入慢速/失败 fake 以验证后台调度。必须可 Sendable 跨线程传递。
    var connectionOpener: @Sendable (String, String?, String?, Bool) throws -> UInt64 = {
        hostID, password, passphrase, trustOnFirstUse in
        try PandaShellConnection.open(
            hostID: hostID, password: password, passphrase: passphrase,
            trustOnFirstUse: trustOnFirstUse
        )
    }

    init(host: HostEntry) {
        self.host = host
    }

    // MARK: - 连接阶段

    /// Mock 模式连接完成（视图层定时器在约 800ms 后调用）。
    /// 创建 MockShellConnection 并写入欢迎信息，离线主机标记为失败。
    func finishConnecting() {
        if host.demo == .offline {
            phase = .failed
            return
        }
        let conn = MockShellConnection()
        // 换行用 \r\n：真实 PTY 输出经 ONLCR 映射后都是 \r\n；
        // 裸 \n 只下移光标不回车，演示文本会呈阶梯状右移。
        let welcome = "\u{1B}[32m✓\u{1B}[0m \u{1B}[2m已建立连接\u{1B}[0m\r\n"
            + "Last login: \(Date())\r\n"
            + "Welcome to \(host.name)\r\n"
        try? conn.write(welcome.data(using: .utf8) ?? Data())
        connection = conn
        phase = .shell
    }

    /// 使用真实 SSH 连接建立 shell 会话。
    /// `password`/`passphrase` 由调用方（钥匙串或手动输入）提供。
    /// 完整握手（`shellOpen`）在后台线程执行，不阻塞主线程；
    /// 多个标签的连接可并行握手（tokio 多线程 runtime 并发 block_on）。
    func connect(record: HostConfigRecord, password: String?, passphrase: String?) {
        guard phase == .connecting else { return }
        pendingRecord = record
        pendingPassword = password
        pendingPassphrase = passphrase

        let opener = connectionOpener
        Task { @MainActor in
            do {
                let handle = try await FFIBackground.run {
                    try opener(record.id, password, passphrase, false)
                }
                self.connection = PandaShellConnection(handle: handle)
                self.phase = .shell
                Logger.shared.info("已连接 host=\(record.host):\(record.port)", module: LogModule.ssh)
            } catch {
                self.phase = .failed
                Logger.shared.error("连接失败 host=\(record.host):\(record.port); 原因=\(error.localizedDescription)", module: LogModule.ssh)
            }
        }
    }

    /// 失败态重试:回到连接中并复用上一次参数重新连接。
    func retry() {
        attempt += 1
        phase = .connecting
        connection = nil
        if let record = pendingRecord {
            connect(record: record, password: pendingPassword, passphrase: pendingPassphrase)
        }
    }

    /// 标记连接失败（供视图层在无法取得主机配置或读循环出错时调用）。
    func markFailed() {
        phase = .failed
    }

    /// 关闭会话，释放真实连接。
    func close() {
        phase = .failed
        if let conn = connection {
            connection = nil
            _ = try? conn.close()
        }
    }
}
