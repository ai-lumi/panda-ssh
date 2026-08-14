import SwiftUI

/// 主机详情页:大图标、名称、user@host:port、备注、分组/认证/指纹 chips、
/// 已记录指纹(等宽)+ 算法,以及「打开终端」「浏览文件 (SFTP)」按钮。
/// 布局与文案参照 prototype/index.html 的 renderHostDetail。
struct HostDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    let host: HostEntry

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
            Text(host.name)
                .font(.title2).bold()
            Text(host.subtitle)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            if !host.note.isEmpty {
                Text(host.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            chips
            if let fingerprint = host.fingerprint {
                VStack(spacing: 4) {
                    Text(host.fingerprintAlgorithm)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                }
                .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                .frame(maxWidth: 520)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 10) {
                Button {
                    workspace.openTerminal(hostID: host.id)
                } label: {
                    Label("打开终端", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    workspace.openSFTP(hostID: host.id)
                } label: {
                    Label("浏览文件 (SFTP)", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    /// 分组 / 认证方式 / 密钥状态 chips
    private var chips: some View {
        HStack(spacing: 6) {
            Chip(text: "分组：\(GroupTree.path(of: host.groupID, in: model.groups))")
            Chip(text: authLabel, systemImage: host.auth == .publicKey ? "key" : "lock")
            if host.demo == .mismatch {
                Chip(text: "⚠ 主机密钥不匹配", tint: .red)
            }
            if host.fingerprint != nil {
                Chip(text: "✓ 主机密钥已记录", tint: .green)
            } else {
                Chip(text: "主机密钥未验证")
            }
        }
    }

    private var authLabel: String {
        switch host.auth {
        case .publicKey:
            return "密钥 \(host.keyPath)"
        case .password:
            return host.passwordSaved ? "密码（已存钥匙串）" : "密码（未保存）"
        }
    }
}

/// 小胶囊标签
private struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((tint ?? .primary).opacity(tint == nil ? 0.06 : 0.14), in: Capsule())
        .foregroundStyle(tint ?? .secondary)
    }
}

#if DEBUG
#Preview("主机详情(已记录指纹)") {
    HostDetailView(host: MockBackend.demo().allHosts().first { $0.id == "h-webprod" }!)
        .environmentObject(AppModel.previewModel())
        .environmentObject(WorkspaceStore.previewStore())
        .environmentObject(ToastCenter())
}

#Preview("主机详情(密钥不匹配)") {
    HostDetailView(host: MockBackend.demo().allHosts().first { $0.id == "h-legacy" }!)
        .environmentObject(AppModel.previewModel())
        .environmentObject(WorkspaceStore.previewStore())
        .environmentObject(ToastCenter())
}
#endif
