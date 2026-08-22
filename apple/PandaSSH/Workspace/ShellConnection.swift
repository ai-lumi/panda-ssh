import Foundation

/// 终端标签页与远端 shell 之间的字节流抽象。
/// Mock 实现用于 Preview/测试；真实实现通过 FFI 调用 Rust 侧的 shell 通道。
protocol ShellConnection: AnyObject {
    /// 向远端 shell 写入输入字节。
    func write(_ data: Data) throws
    /// 非阻塞读取远端 shell 已产生的输出（最多 `max` 字节）。
    func read(max: UInt64) throws -> Data
    /// 通知远端 PTY 窗口尺寸变更。
    func resize(cols: UInt64, rows: UInt64) throws
    /// 关闭 shell 通道并断开 SSH 连接。
    func close() throws
}

/// 真实 SSH shell 连接：持有 FFI 返回的句柄。
/// `open` 是耗时的完整握手（DNS/网络/认证/PTY），调用方应将其放到
/// 后台线程执行（见 `FFIBackground`），再在拿到 handle 后主线程组装对象。
final class PandaShellConnection: ShellConnection {
    private let handle: UInt64

    /// 测试辅助：暴露底层 FFI handle。
    var handleForTesting: UInt64 { handle }

    init(handle: UInt64) {
        self.handle = handle
    }

    /// 同步建立 SSH shell 连接（FFI `shellOpen`，完整握手）。
    /// 阻塞调用，务必经 `FFIBackground.run` 在后台线程执行。
    static func open(
        hostID: String,
        password: String?,
        passphrase: String?,
        trustOnFirstUse: Bool = false
    ) throws -> UInt64 {
        try shellOpen(
            hostId: hostID,
            password: password,
            passphrase: passphrase,
            trustOnFirstUse: trustOnFirstUse
        )
    }

    deinit {
        try? shellClose(handle: handle)
    }

    func write(_ data: Data) throws {
        try shellWrite(handle: handle, data: data)
    }

    func read(max: UInt64) throws -> Data {
        try shellRead(handle: handle, max: max)
    }

    func resize(cols: UInt64, rows: UInt64) throws {
        try shellResize(handle: handle, cols: cols, rows: rows)
    }

    func close() throws {
        try shellClose(handle: handle)
    }
}

/// Mock shell：把输入原样回显，用于 Preview 与单元测试。
final class MockShellConnection: ShellConnection {
    private var buffer = Data()

    func write(_ data: Data) throws {
        buffer.append(data)
    }

    func read(max: UInt64) throws -> Data {
        let count = min(Int(max), buffer.count)
        let chunk = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(chunk)
    }

    func resize(cols: UInt64, rows: UInt64) throws {}

    func close() throws {}
}
