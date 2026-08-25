import SwiftUI

/// 可复用对话框组件,文案与 prototype/index.html 一致。
/// 触发时机(打开终端/SFTP 前的 preconnect 检查)由阶段二接线;
/// 本阶段在主机详情页提供临时预览入口,各组件也有独立 #Preview。

/// 指纹展示块:标签 + 等宽指纹,isBad 时红色描边(密钥变更对比用)。
struct FingerprintBox: View {
    let label: String
    let fingerprint: String
    var isBad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            Text(fingerprint)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial)
        .background(isBad ? Color.red.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            Group {
                if isBad {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                }
            }
        )
    }
}

/// TOFU 指纹确认:未知主机密钥,「取消 / 信任并连接」。
struct TofuConfirmSheet: View {
    let host: HostEntry
    /// 对方本次出示的指纹
    let fingerprint: String
    var onTrust: () -> Void = {}
    var onCancel: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("未知主机密钥")
                .font(.headline)
            Text("首次连接 **\(host.name)**（\(host.address):\(host.port)）。\n请核对服务器出示的主机密钥指纹，确认无误后再信任。信任后指纹将被记录，之后连接不再询问。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            FingerprintBox(label: "\(host.fingerprintAlgorithm) 指纹", fingerprint: fingerprint)
            HStack(spacing: 12) {
                Button("取消", role: .cancel) { onCancel(); dismiss() }
                Button("信任并连接") { onTrust(); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
    }
}

/// 主机密钥变更红色告警:已记录 vs 对方出示指纹对比,仅「断开连接」。
struct HostKeyMismatchSheet: View {
    let host: HostEntry
    /// 本地已记录(known_hosts)的指纹
    let recordedFingerprint: String
    /// 对方本次出示的指纹
    let presentedFingerprint: String
    var onDisconnect: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("服务器密钥已变更！")
                .font(.headline)
                .foregroundStyle(.red)
            Text("「\(host.name)」出示的主机密钥与本地记录**不一致**。\n服务器可能被重装，也可能正在遭遇**中间人攻击**。为安全起见已中断连接。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                FingerprintBox(label: "已记录指纹（known_hosts）", fingerprint: recordedFingerprint)
                FingerprintBox(label: "对方出示指纹", fingerprint: presentedFingerprint, isBad: true)
            }
            Button("断开连接", role: .destructive) { onDisconnect(); dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.top, 4)
        }
    }
}

/// 手动输入密码或私钥口令：秘密仅用于本次标签页会话，不共享、不落盘。
struct PasswordPromptSheet: View {
    let host: HostEntry
    var onLogin: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            Text(host.auth == .password ? "需要密码" : "需要私钥口令")
                .font(.headline)
            Text(promptDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SecureField(host.auth == .password ? "输入登录密码" : "输入私钥口令", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack(spacing: 12) {
                Button("取消", role: .cancel) { onCancel(); dismiss() }
                Button("登录") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
            .padding(.top, 4)
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        // 秘密只随回调进入该标签页会话，不做任何缓存。
        onLogin(password)
        dismiss()
    }

    private var promptDescription: String {
        let credential = host.auth == .password ? "密码" : "私钥口令"
        return "输入 **\(host.username)@\(host.name)** 的\(credential)。\n该主机缺少可用的已保存\(credential)，它仅用于本次标签页会话，关闭标签即销毁；同一主机的其他标签页需各自输入。"
    }
}

/// 私钥选择提示:远端同步过来的密钥认证主机在本机缺少私钥路径时弹出。
struct KeyPickerSheet: View {
    let host: HostEntry
    var onPick: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            Text("需要私钥")
                .font(.headline)
            Text("主机 **\(host.name)** 使用密钥认证，但本机尚未选择私钥文件。请选择本机可用的私钥。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task {
                    if let picked = await SystemKeyPicker.shared.pickPrivateKey() {
                        onPick(picked.path)
                        dismiss()
                    }
                }
            } label: {
                Label("选择私钥文件", systemImage: "doc.badge.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            Button("取消", role: .cancel) { onCancel(); dismiss() }
        }
    }
}

/// 分组名称输入:新建分组 / 新建子分组 / 重命名分组共用。
struct GroupNameSheet: View {
    let title: String
    /// 说明文字(如「在「生产环境」下创建子分组：」),可为空
    var message: String = ""
    var initial: String = ""
    var onDone: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            TextField("分组名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("确定") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 360)
        .onAppear { name = initial }
    }

    private func submit() {
        let value = name.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        onDone(value)
        dismiss()
    }
}

#if DEBUG
#Preview("TOFU 指纹确认") {
    TofuConfirmSheet(host: MockBackend.demo().allHosts().first { $0.demo == .unknown }!,
                     fingerprint: DemoData.FP.newtoy)
}

#Preview("密钥变更告警") {
    HostKeyMismatchSheet(host: MockBackend.demo().allHosts().first { $0.demo == .mismatch }!,
                         recordedFingerprint: DemoData.FP.legacyOld,
                         presentedFingerprint: DemoData.FP.legacyNew)
}

#Preview("手动输入密码") {
    PasswordPromptSheet(host: MockBackend.demo().allHosts().first { $0.demo == .manual }!)
}

#Preview("分组名称输入") {
    GroupNameSheet(title: "新建子分组", message: "在「生产环境」下创建子分组：")
}
#endif
