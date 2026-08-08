import Foundation

/// 终端行内片段:一段文字 + 颜色角色(对应原型 term-body 的 dim/grn/red/ylw 等 class)。
struct TermSegment: Equatable {
    /// 颜色角色,由视图层映射到具体颜色。
    enum Role: Equatable {
        case plain
        case dim
        case green
        case red
        case yellow
        case blue
    }

    var text: String
    var role: Role = .plain
}

/// 终端输出的一行;id 为会话内自增序号,保证 SwiftUI 列表稳定且测试可比较文本。
struct TermLine: Identifiable, Equatable {
    let id: Int
    let segments: [TermSegment]

    /// 拼接后的纯文本(测试与无障碍用)。
    var text: String { segments.map(\.text).joined() }
}

/// 终端会话状态机：连接中 → shell / failed。
/// 支持真实 SSH shell（`ShellConnection`）与 mock 演示模式（`host.demo` 非 nil）。
@MainActor
final class TerminalSessionStore: ObservableObject {
    /// 会话阶段。
    enum Phase: Equatable {
        case connecting
        case shell
        case failed
    }

    /// 命令执行的副作用:.closeTab 时由视图关闭标签(exit 命令)。
    enum CommandResult: Equatable {
        case none
        case closeTab
    }

    let host: HostEntry

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var lines: [TermLine]
    @Published private(set) var history: [String] = []
    /// 连接尝试序号:重试时 +1,视图据此重启连接动画定时器。
    @Published private(set) var attempt = 0

    /// 历史翻页位置:-1 表示未翻页(语义与原型 histIdx 一致)。
    private var historyIndex = -1
    private var nextLineID = 0

    /// 真实连接句柄；nil 时表示 mock 模式。
    private var connection: ShellConnection?
    /// 重试时复用的连接参数。
    private var pendingRecord: HostConfigRecord?
    private var pendingPassword: String?
    private var pendingPassphrase: String?

    init(host: HostEntry) {
        self.host = host
        lines = []
        appendConnectingLine()
    }

    /// 连接动画/真实连接开始后的通用欢迎信息。
    private func appendWelcome() {
        append([
            TermSegment(text: "✓ ", role: .green),
            TermSegment(text: "已建立连接", role: .dim),
        ])
        append([
            TermSegment(text: "Last login: \(Date())", role: .dim),
        ])
        append([
            TermSegment(text: "Welcome to "),
            TermSegment(text: host.name, role: .yellow),
        ])
    }

    // MARK: - 连接阶段

    /// 连接动画结束(视图层定时器在约 800ms 后调用;测试直接调用)。
    /// mock 主机沿用原演示行为；真实主机在调用 `connect` 后进入 shell。
    func finishConnecting() {
        if host.demo == .offline {
            phase = .failed
            return
        }
        phase = .shell
        lines = []
        appendWelcome()
    }

    /// 使用真实 SSH 连接建立 shell 会话。
    /// `password`/`passphrase` 由调用方（钥匙串或手动输入）提供。
    func connect(record: HostConfigRecord, password: String?, passphrase: String?) {
        guard phase == .connecting else { return }
        pendingRecord = record
        pendingPassword = password
        pendingPassphrase = passphrase

        Task { @MainActor in
            do {
                let conn = try PandaShellConnection(
                    hostID: record.id,
                    password: password,
                    passphrase: passphrase,
                    trustOnFirstUse: false
                )
                self.connection = conn
                self.phase = .shell
                self.lines = []
                self.appendWelcome()
                self.startReading(from: conn)
            } catch {
                self.phase = .failed
            }
        }
    }

    /// 启动读循环：定时从 shell 通道拉取输出并追加到视图。
    private func startReading(from conn: ShellConnection) {
        Task { @MainActor in
            while self.phase == .shell, self.connection === conn {
                do {
                    let data = try conn.read(max: 4096)
                    if !data.isEmpty {
                        self.appendShellOutput(data: data)
                    }
                } catch {
                    self.phase = .failed
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// 把远端 shell 输出按行追加显示（保留 UTF-8 可解码部分）。
    private func appendShellOutput(data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append([TermSegment(text: trimmed, role: .plain)])
    }

    /// 失败态重试:回到连接中并复用上一次参数重新连接。
    func retry() {
        attempt += 1
        phase = .connecting
        lines = []
        appendConnectingLine()
        if let record = pendingRecord {
            connect(record: record, password: pendingPassword, passphrase: pendingPassphrase)
        }
    }

    /// 标记连接失败（供视图层在无法取得主机配置时调用）。
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

    // MARK: - 命令执行

    /// 执行一行输入。
    /// - 真实 shell：直接发送输入（含换行），由远端回显。
    /// - mock：本地回显并解释内置命令。
    @discardableResult
    func run(_ input: String) -> CommandResult {
        let command = input.trimmingCharacters(in: .whitespaces)

        if let conn = connection {
            guard !command.isEmpty else { return .none }
            history.append(command)
            historyIndex = -1
            if command == "exit" { return .closeTab }
            let payload = (command + "\n").data(using: .utf8) ?? Data()
            _ = try? conn.write(payload)
            return .none
        }

        // mock 模式：保持原有内置 shell 行为（与原型和现有测试一致）。
        append([
            TermSegment(text: prompt, role: .green),
            TermSegment(text: " \(command)"),
        ])
        guard !command.isEmpty else { return .none }
        history.append(command)
        historyIndex = -1

        switch command {
        case "exit":
            return .closeTab
        case "clear":
            lines = []
        case "help":
            outputHelp()
        case "ls", "ls -la", "ll":
            append([
                TermSegment(text: "app", role: .blue),
                TermSegment(text: "  "),
                TermSegment(text: "logs", role: .blue),
                TermSegment(text: "  backup-2026-08-01.sql.gz  .bashrc"),
            ])
        case "pwd":
            append([TermSegment(text: "/home/\(host.username)")])
        case "whoami":
            append([TermSegment(text: host.username)])
        case "uname -a":
            append([TermSegment(text: "Linux \(host.name) 6.8.0-71-generic #71-Ubuntu SMP x86_64 GNU/Linux")])
        case "date":
            append([TermSegment(text: "\(Date())")])
        default:
            if command.hasPrefix("echo ") {
                let raw = String(command.dropFirst(5))
                append([TermSegment(text: raw.replacingOccurrences(of: #"^["']|["']$"#, with: "", options: .regularExpression))])
            } else {
                let name = command.split(separator: " ").first.map(String.init) ?? command
                append([
                    TermSegment(text: "zsh: command not found: \(name)", role: .red),
                    TermSegment(text: "（输入 help 查看可用命令）", role: .dim),
                ])
            }
        }
        return .none
    }

    /// `user@host:~$` 形式的 prompt(home 目录缩写为 ~)。
    var prompt: String {
        "\(host.username)@\(host.name):~$"
    }

    // MARK: - 命令历史(↑↓)

    /// ↑:向更早的命令翻页;到顶后停留,无历史返回空串。
    func historyUp() -> String {
        guard !history.isEmpty, historyIndex < history.count - 1 else {
            return historyIndex >= 0 ? history[history.count - 1 - historyIndex] : ""
        }
        historyIndex += 1
        return history[history.count - 1 - historyIndex]
    }

    /// ↓:向更新的命令翻页;翻回最新位置后返回空串(清空输入)。
    func historyDown() -> String {
        if historyIndex > 0 {
            historyIndex -= 1
            return history[history.count - 1 - historyIndex]
        }
        historyIndex = -1
        return ""
    }

    // MARK: - 私有

    private func appendConnectingLine() {
        append([TermSegment(text: "正在连接 \(host.address):\(host.port) …", role: .dim)])
    }

    private func outputHelp() {
        let names = ["help", "ls", "pwd", "whoami", "uname -a", "date", "echo", "clear", "exit"]
        var segments = [TermSegment(text: "可用命令：")]
        for (index, name) in names.enumerated() {
            segments.append(TermSegment(text: name, role: .yellow))
            if index < names.count - 1 { segments.append(TermSegment(text: "、")) }
        }
        append(segments)
    }

    private func append(_ segments: [TermSegment]) {
        lines.append(TermLine(id: nextLineID, segments: segments))
        nextLineID += 1
    }
}
