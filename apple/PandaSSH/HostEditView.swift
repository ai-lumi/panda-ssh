import SwiftUI

/// 添加/编辑主机表单。字段与原型 showHostForm 对齐:主机(名称/地址/端口/
/// 用户名/备注/所属分组)+ 认证(密码或密钥)。
/// 密钥材料（密码/私钥口令）不落表单数据：真实后端写本地凭据仓库，配置文件
/// 只存引用 key;Mock 后端直接丢弃,仅保留「已保存」标记。
struct HostEditView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// 待编辑的主机;nil 表示新建
    let host: HostEntry?
    /// 复制来源；仅用于新建表单的非敏感字段预填。
    let copySource: HostEntry?
    /// 新建时的默认归属分组(侧栏选中分组/选中主机所在分组);编辑时忽略
    var defaultGroupID: String? = nil

    init(host: HostEntry? = nil, copySource: HostEntry? = nil, defaultGroupID: String? = nil,
         keyPicker: KeyPicker = SystemKeyPicker.shared) {
        self.host = host
        self.copySource = copySource
        self.defaultGroupID = defaultGroupID
        self.keyPicker = keyPicker
    }

    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var note = ""
    @State private var groupID: String?
    @State private var useKey = false
    @State private var password = ""
    @State private var savePassword = true
    @State private var keyPath = ""
    @State private var passphrase = ""
    @State private var savePassphrase = false
    @State private var showCredentialError = false
    @State private var showClearCredentialAlert = false

    /// 私钥选择器；生产环境用系统选择器，测试可注入 fake。
    let keyPicker: KeyPicker

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("主机") {
                    TextField("名称", text: $name, prompt: Text("如 web-prod"))
                    TextField("地址", text: $hostname, prompt: Text("IP 或域名"))
                    TextField("端口", text: $port)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    TextField("用户名", text: $username)
                    TextField("备注", text: $note, prompt: Text("可选"))
                    Picker("所属分组", selection: $groupID) {
                        Text("根级（无分组）").tag(String?.none)
                        ForEach(model.groups) { group in
                            Text((try? groupPath(groupId: group.id)) ?? group.name)
                                .tag(String?.some(group.id))
                        }
                    }
                }
                Section("认证") {
                    Picker("方式", selection: $useKey) {
                        Text("密码").tag(false)
                        Text("密钥").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if useKey {
                        HStack {
                            TextField("私钥路径", text: $keyPath, prompt: Text("~/.ssh/id_ed25519"))
                            Button("选择文件…") { pickKey() }
                        }
                        SecureField("密钥口令（可选）", text: $passphrase)
                        Toggle("保存口令", isOn: $savePassphrase)
                        if host != nil, existingSecretRef() != nil {
                            Button("清除已保存的口令", role: .destructive) {
                                showClearCredentialAlert = true
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                    } else {
                        SecureField(
                            "密码",
                            text: $password,
                            prompt: Text(host?.passwordSaved == true ? "已保存" : "输入密码")
                        )
                        Toggle("保存密码", isOn: $savePassword)
                        if !savePassword {
                            Text("连接时将要求手动输入")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if host != nil, host?.passwordSaved == true {
                            Button("清除已保存的密码", role: .destructive) {
                                showClearCredentialAlert = true
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(host == nil ? "添加主机" : "编辑主机")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .onAppear { loadExisting() }
        .alert("无法保存主机", isPresented: $showCredentialError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("凭据写入本地文件失败，主机未保存。请重试。")
        }
        .alert("清除已保存凭据？", isPresented: $showClearCredentialAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { clearSavedCredential() }
        } message: {
            Text("清除后下次连接需要重新输入，且不会自动填充。")
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private func pickKey() {
        Task {
            if let picked = await keyPicker.pickPrivateKey() {
                keyPath = picked.path
            }
        }
    }

    private func clearSavedCredential() {
        guard let host else { return }
        model.deleteCredentials(for: host.id, auth: host.auth)
        if host.auth == .password {
            savePassword = false
        } else {
            savePassphrase = false
        }
    }

    private func loadExisting() {
        guard let host else {
            if let copySource {
                loadCopy(HostCopyDraft(source: copySource))
                return
            }
            // 新建:默认归属侧栏当前选中分组(或选中主机所在分组)
            groupID = defaultGroupID
            return
        }
        name = host.name
        hostname = host.address
        port = String(host.port)
        username = host.username
        note = host.note
        groupID = host.groupID
        useKey = host.auth == .publicKey
        savePassword = host.passwordSaved
        savePassphrase = host.passphraseSaved
        keyPath = host.keyPath
        // Mock 模式不落密钥材料，没有可回显的密码；真实模式从本地凭据文件取回。
        if !model.usesMockBackend {
            if let ref = existingSecretRef(), let secret = try? PandaCoreBridge.shared.storedCredential(reference: ref) {
                if host.auth == .publicKey { passphrase = secret } else { password = secret }
            }
        }
    }

    private func loadCopy(_ draft: HostCopyDraft) {
        name = draft.name
        hostname = draft.address
        port = String(draft.port)
        username = draft.username
        note = draft.note
        groupID = draft.groupID
        useKey = draft.auth == .publicKey
        keyPath = draft.keyPath
        password = ""
        passphrase = ""
        savePassword = false
        savePassphrase = false
    }

    private func existingSecretRef() -> String? {
        guard let host else { return nil }
        switch host.toConfigRecord().auth {
        case .password(let ref): return ref
        case .publicKey(_, let ref): return ref
        }
    }

    private func save() {
        let isNew = host == nil
        var entry = HostEntry(
            id: host?.id ?? "h-\(UUID().uuidString)",
            name: name.trimmingCharacters(in: .whitespaces),
            address: hostname.trimmingCharacters(in: .whitespaces),
            port: UInt16(port) ?? 22,
            username: username.trimmingCharacters(in: .whitespaces),
            note: note.trimmingCharacters(in: .whitespaces),
            groupID: groupID,
            auth: useKey ? .publicKey : .password,
            keyPath: useKey ? keyPath.trimmingCharacters(in: .whitespaces) : "",
            passwordSaved: useKey ? false : savePassword,
            passphraseSaved: useKey ? savePassphrase : false,
            fingerprint: host?.fingerprint,
            fingerprintAlgorithm: host?.fingerprintAlgorithm ?? "ssh-ed25519",
            demo: host?.demo
        )
        if isNew {
            // 新主机从未连接:标记为「未验证」,首次连接走 TOFU 确认(与原型一致)
            entry.fingerprint = nil
            entry.demo = .unknown
        }
        let passwordSecret = password.isEmpty ? nil : password
        let passphraseSecret = passphrase.isEmpty ? nil : passphrase
        guard model.saveHost(entry, password: passwordSecret, passphrase: passphraseSecret) else {
            showCredentialError = true
            return
        }
        dismiss()
    }
}

#if DEBUG
#Preview("添加主机") {
    HostEditView(host: nil)
        .environmentObject(AppModel.previewModel())
}

#Preview("编辑主机(密钥认证)") {
    HostEditView(host: MockBackend.demo().allHosts().first { $0.auth == .publicKey }!)
        .environmentObject(AppModel.previewModel())
}
#endif
