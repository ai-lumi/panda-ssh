import SwiftUI

/// 连接门控:终端/SFTP 标签打开时决定先弹哪个对话框(TOFU / 密钥变更告警 / 密码输入),
/// 通过后才进入连接流程。手动输入的密码只由本对象持有——它随标签视图销毁,不共享、不落盘。
///
/// 真实模式下门控会异步探测未知主机的呈现密钥;多个同主机标签共享同一个 TOFU
/// 确认结果(AppModel 层并发串行化),只弹一次确认框。
@MainActor
final class PreconnectGate: ObservableObject {
    /// 待展示的对话框种类。
    enum Sheet: Int, Identifiable {
        case tofu
        case mismatch
        case password
        case keyPicker

        var id: Int { rawValue }
    }

    @Published private(set) var unlocked = false
    @Published var sheet: Sheet?
    /// 真实模式下探测到的呈现密钥,用于 TOFU 对话框展示指纹。
    private(set) var presentedKey: PresentedHostKey?
    /// 手动输入的密码或私钥口令，仅本标签会话持有。
    private(set) var manualSecret: String?

    /// 是否已经评估过(onAppear 可能多次触发,评估只进行一次)。
    private var evaluated = false

    /// 凭据解析器；生产环境读取本地凭据文件，测试可注入内存 fake。
    var credentialResolver = CredentialResolver.localStore()

    /// 打开标签时评估一次;重复调用为 no-op。返回决策结果(便于测试与日志)。
    /// 供 Mock 模式使用;真实模式调用 `evaluateAsync`。
    @discardableResult
    func evaluate(host: HostEntry) -> PreconnectAction {
        guard !evaluated else { return .proceed }
        evaluated = true
        let action = AppModel.preconnectAction(for: host)
        apply(action: action)
        return action
    }

    /// 真实模式下异步评估连接前状态。`onClose` 在确认被取消(含作为等待者收到取消结果)时调用。
    func evaluateAsync(host: HostEntry, in model: AppModel, onClose: @escaping () -> Void) async {
        guard !evaluated else { return }
        evaluated = true

        switch model.backend.hostKeyStatus(for: host.id) {
        case .known:
            checkCredentials(host: host)
        case .unknown:
            await probeUnknown(host: host, in: model, onClose: onClose)
        }
    }

    /// 主机密钥已知时，检查凭据是否已保存；未保存则弹出密码/口令输入框。
    /// 密钥认证但本机未选择私钥时，引导选择私钥。
    private func checkCredentials(host: HostEntry) {
        if host.auth == .publicKey && host.keyPath.isEmpty {
            Logger.shared.warning("私钥未选择 host=\(host.address):\(host.port)", module: LogModule.hostKey)
            sheet = .keyPicker
            return
        }
        let secrets = credentialResolver.connectionSecrets(for: host)
        if secrets == nil {
            Logger.shared.warning("凭据缺失 host=\(host.address):\(host.port)", module: LogModule.hostKey)
            sheet = .password
        } else {
            unlocked = true
        }
    }

    /// 发起连接前再次确认凭据可用，避免竞态将空密码送入 FFI。
    func requestCredentialsIfNeeded(for host: HostEntry) -> Bool {
        guard credentialResolver.connectionSecrets(for: host, manualSecret: manualSecret) == nil else {
            return false
        }
        unlocked = false
        sheet = .password
        return true
    }

    /// FFI 在连接时仍报告缺凭据时强制回到输入框，避免落入通用失败页。
    func requireCredentialInput() {
        unlocked = false
        sheet = .password
    }

    /// 会话建立阶段仍收到未知主机密钥时的安全回退。
    /// 正常路径会在连接前探测到该错误；这里处理 known_hosts 状态与握手之间
    /// 的竞态，绝不把未验证的密钥当作普通连接失败或自动信任。
    @discardableResult
    func requireTofuConfirmation(_ key: PresentedHostKey) -> Bool {
        guard !key.key.isEmpty else {
            unlocked = false
            manualSecret = nil
            return false
        }
        unlocked = false
        manualSecret = nil
        presentedKey = key
        sheet = .tofu
        return true
    }

    private func probeUnknown(host: HostEntry, in model: AppModel, onClose: @escaping () -> Void) async {
        do {
            if let key = try await model.backend.probePresentedKey(for: host.id) {
                presentedKey = key
                if let alreadyTrusted = await model.awaitTofuConfirmation(for: host.id) {
                    if alreadyTrusted {
                        Logger.shared.info("已信任主机密钥 host=\(host.address):\(host.port)", module: LogModule.hostKey)
                        unlocked = true
                    } else {
                        onClose()
                    }
                } else {
                    Logger.shared.warning("TOFU 待确认 host=\(host.address):\(host.port)", module: LogModule.hostKey)
                    sheet = .tofu
                }
            } else {
                checkCredentials(host: host)
            }
        } catch let error as HostKeyMismatchError {
            Logger.shared.warning("主机密钥变更 host=\(host.address):\(host.port); 已知指纹=\(error.storedFingerprint); 呈现指纹=\(error.presentedFingerprint)", module: LogModule.hostKey)
            presentedKey = PresentedHostKey(key: "", fingerprint: error.presentedFingerprint)
            sheet = .mismatch
        } catch {
            // 探测失败(网络/超时):交给后续真实连接阶段处理,不在门控拦截。
            Logger.shared.warning("主机密钥探测失败 host=\(host.address):\(host.port); 原因=\(error.localizedDescription)", module: LogModule.hostKey)
            unlocked = true
        }
    }

    private func apply(action: PreconnectAction) {
        switch action {
        case .proceed:
            unlocked = true
        case .confirmTofu:
            sheet = .tofu
        case .keyMismatch:
            sheet = .mismatch
        case .askPassword:
            sheet = .password
        }
    }

    /// 对话框确认通过:TOFU 信任 / 密码输入完成后进入连接流程。
    func unlock(secret: String? = nil) {
        self.manualSecret = secret
        unlocked = true
        sheet = nil
    }

    /// TOFU 信任后继续：若凭据未保存，先弹出密码输入框；否则直接放行。
    func continueAfterTrust(host: HostEntry) {
        let secrets = credentialResolver.connectionSecrets(for: host)
        if secrets == nil {
            sheet = .password
        } else {
            unlocked = true
        }
    }
}

/// 连接中状态行:「正在连接 addr:port …」+ 转圈,终端与 SFTP 标签共用。
struct ConnectingRow: View {
    let host: HostEntry

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在连接 \(host.address):\(host.port) …")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 连接失败类型：只把真正的网络超时呈现为超时，避免遮蔽认证或凭据问题。
enum ConnectionFailure: Equatable {
    case timeout
    case authenticationFailed
    case missingCredential
    case unknownHostKey(PresentedHostKey)
    case other(String)

    init(error: Error) {
        guard let panda = error as? PandaError else {
            self = .other(error.localizedDescription)
            return
        }
        switch panda {
        case .Timeout:
            self = .timeout
        case .AuthFailed:
            self = .authenticationFailed
        case .MissingPassword, .MissingPassphrase:
            self = .missingCredential
        case .UnknownHostKey(_, let presented, let fingerprint):
            self = .unknownHostKey(PresentedHostKey(key: presented, fingerprint: fingerprint))
        default:
            self = .other(error.localizedDescription)
        }
    }

    var presentedHostKey: PresentedHostKey? {
        guard case .unknownHostKey(let key) = self else { return nil }
        return key
    }

    var title: String {
        switch self {
        case .timeout: return "连接超时"
        case .authenticationFailed: return "认证失败"
        case .missingCredential: return "缺少凭据"
        case .unknownHostKey: return "需要确认主机密钥"
        case .other: return "连接失败"
        }
    }

    var detail: String {
        switch self {
        case .timeout: return "无法在规定时间内连接到远程主机，请检查网络或主机是否在线。"
        case .authenticationFailed: return "服务器拒绝了提供的认证信息，请检查用户名、密码或私钥。"
        case .missingCredential: return "连接需要密码或私钥口令。"
        case .unknownHostKey: return "服务器主机密钥尚未确认。"
        case .other(let message): return message
        }
    }
}

/// 连接失败态:对应错误图标、详情 + [重试][关闭标签]；终端与 SFTP 标签共用。
struct ConnectFailureView: View {
    let host: HostEntry
    var failure: ConnectionFailure = .timeout
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label(failure.title, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
            } description: {
                Text("\(host.address):\(host.port)\n\(failure.detail)")
                    .font(.system(.caption, design: .monospaced))
            }
            HStack(spacing: 10) {
                Button("重试", action: onRetry)
                    .buttonStyle(.borderedProminent)
                Button("关闭标签", action: onClose)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 把三个连接前对话框(TOFU / 密钥变更 / 密码)挂到标签视图上。
/// 任何方式关闭对话框而未通过门控(取消 / Esc / 下滑)都按原型语义
/// 不建立会话:直接关闭该标签,并向等待同一主机确认的其他标签广播取消结果。
private struct PreconnectSheets: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var toast: ToastCenter
    @ObservedObject var gate: PreconnectGate
    let host: HostEntry
    let tabID: UUID

    func body(content: Content) -> some View {
        content.sheet(item: $gate.sheet, onDismiss: {
            if !gate.unlocked {
                model.resolveTofuConfirmation(for: host.id, trusted: false)
                workspace.close(tabID: tabID)
            }
        }) { sheet in
            switch sheet {
            case .tofu:
                TofuConfirmSheet(
                    host: host,
                    fingerprint: gate.presentedKey?.fingerprint ?? "SHA256:—",
                    onTrust: {
                        model.resolveTofuConfirmation(for: host.id, trusted: true)
                        toast.show("已记录主机密钥指纹")
                        gate.continueAfterTrust(host: host)
                    }
                )
            case .mismatch:
                HostKeyMismatchSheet(
                    host: host,
                    recordedFingerprint: host.fingerprint ?? "—",
                    presentedFingerprint: gate.presentedKey?.fingerprint ?? "SHA256:—"
                )
            case .password:
                PasswordPromptSheet(host: host, onLogin: { password in
                    gate.unlock(secret: password)
                })
            case .keyPicker:
                KeyPickerSheet(host: host, onPick: { path in
                    var updated = host
                    updated.keyPath = path
                    _ = model.saveHost(updated, password: nil, passphrase: nil)
                    gate.unlock()
                }, onCancel: {
                    model.resolveTofuConfirmation(for: host.id, trusted: false)
                    workspace.close(tabID: tabID)
                })
            }
        }
    }
}

extension View {
    /// 挂接连接门控对话框(终端 / SFTP 标签共用)。
    func preconnectSheets(gate: PreconnectGate, host: HostEntry, tabID: UUID) -> some View {
        modifier(PreconnectSheets(gate: gate, host: host, tabID: tabID))
    }
}

#if DEBUG
#Preview("连接失败") {
    ConnectFailureView(
        host: MockBackend.demo().allHosts().first { $0.demo == .offline }!,
        onRetry: {}, onClose: {}
    )
}
#endif
