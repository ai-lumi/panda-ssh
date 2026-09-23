import Foundation

/// 终端会话状态机：连接中 → shell / ended / failed。
/// 管理真实 SSH shell（`ShellConnection`）与 mock 演示模式。
/// 数据流由 TerminalTabView 的 SwiftTerm TerminalView 包装器读取 `connection`
/// 并双向桥接（用户输入 → write，远端输出 → feed）。
@MainActor
final class TerminalSessionStore: ObservableObject {
    /// 会话阶段。
    enum Phase: Equatable {
        case connecting
        case shell
        case ended
        case failed
    }

    let host: HostEntry
    /// 核心会话标识：用于代次跟踪与资源释放。
    let sessionID: String

    @Published private(set) var phase: Phase = .connecting
    /// 最近一次连接失败的结构化类别；仅在 `phase == .failed` 时有意义。
    @Published private(set) var failure: ConnectionFailure = .timeout
    /// 当前连接句柄；nil 表示尚未建立连接。
    /// 视图层（SwiftTerm TerminalView 包装器）据此启动读循环。
    @Published private(set) var connection: ShellConnection?
    /// 连接尝试序号:重试时 +1,视图据此重启连接流程。
    @Published private(set) var attempt = 0

    /// 主线程上先占用代次，再提交后台握手，避免视图重复触发。
    private var connectingAttempt: Int?
    var staleConnectionCloser: @Sendable (UInt64) throws -> Void = { try shellClose(handle: $0) }

    /// 连接打开器注入点：返回 FFI shell handle。默认真实实现 `PandaShellConnection.trackedOpen`；
    /// 测试注入慢速/失败 fake 以验证后台调度。必须可 Sendable 跨线程传递。
    var connectionOpener: @Sendable (String, String?, String?, Bool, String, UInt32) throws -> UInt64 = {
        hostID, password, passphrase, trustOnFirstUse, sessionID, generation in
        try PandaShellConnection.trackedOpen(
            hostID: hostID, password: password, passphrase: passphrase,
            trustOnFirstUse: trustOnFirstUse, sessionID: sessionID, generation: generation
        )
    }

    init(host: HostEntry) {
        self.host = host
        self.sessionID = "shell-\(host.id)-\(UUID().uuidString)"
    }

    // MARK: - 连接阶段

    /// Mock 模式连接完成（视图层定时器在约 800ms 后调用）。
    /// 创建 MockShellConnection 并写入欢迎信息，离线主机标记为失败。
    func finishConnecting() {
        guard phase == .connecting else { return }
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
    /// `password`/`passphrase` 由调用方（本地凭据文件或手动输入）提供。
    /// 完整握手（`trackedShellOpen`）在后台线程执行，不阻塞主线程；
    /// 多个标签的连接可并行握手（tokio 多线程 runtime 并发 block_on）。
    func connect(record: HostConfigRecord, password: String?, passphrase: String?) {
        guard phase == .connecting, connectingAttempt != attempt else { return }
        let generation = attempt
        connectingAttempt = generation
        let opener = connectionOpener
        let closer = staleConnectionCloser
        let sid = sessionID
        Task { @MainActor in
            do {
                let handle = try await FFIBackground.run {
                    try opener(record.id, password, passphrase, false, sid, UInt32(generation))
                }
                let stale = PandaCoreBridge.shared.isSessionStale(sessionID: sid, generation: UInt32(generation))
                if stale {
                    do {
                        try await FFIBackground.run { try closer(handle) }
                    } catch {
                        Logger.shared.error("SSH 过期握手释放失败 handle=\(handle)", module: LogModule.ssh)
                    }
                    return
                }
                self.connectingAttempt = nil
                self.connection = PandaShellConnection(handle: handle)
                self.phase = .shell
                Logger.shared.info("已连接 host=\(record.host):\(record.port); owner=终端标签#\(handle); attempt=\(generation)", module: LogModule.ssh)
            } catch {
                let stale = PandaCoreBridge.shared.isSessionStale(sessionID: sid, generation: UInt32(generation))
                guard !stale else { return }
                self.connectingAttempt = nil
                self.failure = ConnectionFailure(error: error)
                self.phase = .failed
                Logger.shared.error("连接失败 host=\(record.host):\(record.port); attempt=\(generation)", module: LogModule.ssh)
            }
        }
    }

    /// 失败态重试：只推进连接代次；视图的 `.task(id:)` 是唯一建连执行器。
    func retry() {
        PandaCoreBridge.shared.cancelSession(sessionID: sessionID)
        Logger.shared.info("SSH 重试 host=\(host.address):\(host.port); attempt=\(attempt + 1)", module: LogModule.ssh)
        attempt += 1
        releaseConnection()
        phase = .connecting
    }

    /// 缺凭据时停止复用旧参数，等待门控取得本标签的新瞬态输入后再连接。
    func waitForCredentialInput() {
        PandaCoreBridge.shared.cancelSession(sessionID: sessionID)
        attempt += 1
        releaseConnection()
        phase = .connecting
    }

    /// 主机密钥确认前停止当前尝试。确认后由视图层以新尝试重新建立连接。
    func waitForHostKeyConfirmation() {
        PandaCoreBridge.shared.cancelSession(sessionID: sessionID)
        attempt += 1
        releaseConnection()
        phase = .connecting
    }

    /// 标记连接失败（供视图层在无法取得主机配置或读循环出错时调用）。
    func markFailed() {
        failure = .other("SSH 会话已断开。")
        phase = .failed
        releaseConnection()
    }

    /// 远端 shell 正常结束只释放该标签自己的 FFI 句柄与 Socket。
    @discardableResult
    func handleSessionEnd(_ error: Error, attempt generation: Int) -> Bool {
        let stale = PandaCoreBridge.shared.isSessionStale(sessionID: sessionID, generation: UInt32(generation))
        guard !stale, phase == .shell else { return false }
        if let core = error as? PandaError, core == .ShellSessionClosed {
            handleRemoteShellExit()
        } else {
            // 不记录原始错误描述：其中可能夹带远端返回的数据。
            Logger.shared.error("SSH 通信异常 host=\(host.address):\(host.port); attempt=\(generation)", module: LogModule.ssh)
            failure = .other("SSH 连接异常，无法继续通信。")
            phase = .failed
            releaseConnection()
        }
        return true
    }

    func handleRemoteShellExit() {
        Logger.shared.info("SSH shell 已结束 host=\(host.address):\(host.port)", module: LogModule.ssh)
        phase = .ended
        releaseConnection()
    }

    /// 关闭会话，释放真实连接。
    func close() {
        PandaCoreBridge.shared.cancelSession(sessionID: sessionID)
        attempt += 1
        Logger.shared.info("SSH 显式关闭 host=\(host.address):\(host.port)", module: LogModule.ssh)
        phase = .failed
        releaseConnection()
    }

    private func releaseConnection() {
        if let conn = connection {
            connection = nil
            do {
                try conn.close()
            } catch {
                Logger.shared.error("SSH 句柄释放失败 host=\(host.address):\(host.port)", module: LogModule.ssh)
            }
        }
    }
}
