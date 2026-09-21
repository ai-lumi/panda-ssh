// ============================================================================
// HostEditView.swift — 添加/编辑主机表单视图
//
// 本文件提供主机信息的录入界面，支持两种模式：
//   1. 新建模式：host 参数为 nil，所有字段为空，用户填写后创建新主机
//   2. 编辑模式：host 参数非 nil，表单预填已有数据，用户修改后保存
//   3. 复制模式：copySource 非 nil，从已有主机复制非敏感字段（名称/地址/端口等）
//
// 界面分为两大区域：
//   - 「主机」区域：名称、地址、端口、用户名、备注、所属分组
//   - 「认证」区域：密码登录 或 密钥登录（通过分段选择器切换）
//
// 安全设计：密码和私钥口令等敏感信息不直接存在配置文件中，
// 而是写入本地凭据仓库（credentials.toml），配置文件只存引用 key。
// ============================================================================

// 导入 SwiftUI 框架，提供声明式 UI 构建能力
import SwiftUI

/// 添加/编辑主机表单。字段与原型 showHostForm 对齐:主机(名称/地址/端口/
/// 用户名/备注/所属分组)+ 认证(密码或密钥)。
/// 密钥材料（密码/私钥口令）不落表单数据：真实后端写本地凭据仓库，配置文件
/// 只存引用 key;Mock 后端直接丢弃,仅保留「已保存」标记。
struct HostEditView: View {
    // ---- 环境对象 ----
    // @EnvironmentObject 从视图树中自动注入共享对象，无需手动传递
    // 应用全局数据模型，管理主机列表、分组、后端操作等
    @EnvironmentObject private var model: AppModel
    // 系统提供的关闭弹窗/表单的环境值，调用 dismiss() 即可关闭当前 sheet
    @Environment(\.dismiss) private var dismiss

    /// 待编辑的主机;nil 表示新建
    // 如果为 nil，说明是新建模式；否则是编辑模式，预填该主机数据
    let host: HostEntry?
    /// 复制来源；仅用于新建表单的非敏感字段预填。
    // 从哪个主机复制信息（只复制名称/地址等非敏感字段，不复制密码/密钥）
    let copySource: HostEntry?
    /// 新建时的默认归属分组(侧栏选中分组/选中主机所在分组);编辑时忽略
    // 新建时自动选中的分组 ID，编辑模式下此参数被忽略
    var defaultGroupID: String? = nil

    // ---- 初始化器 ----
    // 自定义 init 用于接收依赖注入的 keyPicker（私钥文件选择器）
    init(host: HostEntry? = nil, copySource: HostEntry? = nil, defaultGroupID: String? = nil,
         // keyPicker 默认使用系统文件选择器，测试时可注入 fake
         keyPicker: KeyPicker = SystemKeyPicker.shared) {
        // 保存待编辑主机引用
        self.host = host
        // 保存复制来源引用
        self.copySource = copySource
        // 保存默认分组 ID
        self.defaultGroupID = defaultGroupID
        // 保存私钥选择器实例
        self.keyPicker = keyPicker
    }

    // ---- 表单状态变量 ----
    // @State 标记的变量是视图的本地状态，值变化时自动触发 UI 刷新
    // 主机名称，如 "web-prod"
    @State private var name = ""
    // 主机地址，可以是 IP 地址或域名
    @State private var hostname = ""
    // SSH 端口号，默认 22；用字符串类型因为要绑定 TextField
    @State private var port = "22"
    // 登录用户名，如 "root"
    @State private var username = ""
    // 备注信息，可选填
    @State private var note = ""
    // 所属分组的 ID，nil 表示根级（不属于任何分组）
    @State private var groupID: String?
    // 是否使用密钥认证：false = 密码认证，true = 密钥认证
    @State private var useKey = false
    // 登录密码输入框的值
    @State private var password = ""
    // 是否保存密码到凭据仓库，默认勾选
    @State private var savePassword = true
    // 私钥文件在本机的路径，如 "~/.ssh/id_ed25519"
    @State private var keyPath = ""
    // 私钥口令（passphrase），可选
    @State private var passphrase = ""
    // 是否保存私钥口令到凭据仓库，默认不勾选
    @State private var savePassphrase = false
    // 控制「凭据写入失败」弹窗的显示状态
    @State private var showCredentialError = false
    // 控制「确认清除已保存凭据」弹窗的显示状态
    @State private var showClearCredentialAlert = false

    /// 私钥选择器；生产环境用系统选择器，测试可注入 fake。
    // 协议类型，抽象了文件选择行为，便于测试替换
    let keyPicker: KeyPicker

    // ---- 计算属性：是否可以保存 ----
    // 只有当名称、地址、用户名三个必填字段都不为空时，保存按钮才可用
    private var canSave: Bool {
        // 名称去除首尾空格后不为空
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            // 地址去除空格后不为空
            && !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            // 用户名去除空格后不为空
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // ---- 主视图体 ----
    var body: some View {
        // NavigationStack 提供导航栏（顶部标题栏）和工具栏的容器
        NavigationStack {
            // Form 是系统风格的表单布局，自动分组、加间距、适配各平台外观
            Form {
                // ---- 第一个分区：「主机」基本信息 ----
                // Section 标题显示为 "主机"，表单自动以此作为分组标题
                Section("主机") {
                    // TextField：单行文本输入框
                    // 参数 "名称" 是占位提示文字（placeholder），$name 是双向绑定
                    // prompt 是更详细的灰色提示文字（iOS 16+/macOS 13+ 支持）
                    // 输入主机显示名称
                    TextField("名称", text: $name, prompt: Text("如 web-prod"))
                    // 输入主机 IP 地址或域名
                    TextField("地址", text: $hostname, prompt: Text("IP 或域名"))
                    // 输入 SSH 端口号
                    TextField("端口", text: $port)
                        // 条件编译：仅在 iOS 平台生效
                        #if os(iOS)
                        // 弹出数字键盘，因为端口只能是数字
                        .keyboardType(.numberPad)
                        #endif
                    // 输入 SSH 登录用户名
                    TextField("用户名", text: $username)
                    // 输入备注，提示用户此项可选
                    TextField("备注", text: $note, prompt: Text("可选"))

                    // Picker：下拉选择器，让用户选择主机归属的分组
                    // "所属分组" 是标签文字，$groupID 双向绑定当前选中的分组 ID
                    Picker("所属分组", selection: $groupID) {
                        // 第一个选项：根级（不属于任何分组），tag 值为 nil
                        // String?.none 等价于 nil，表示不归属任何分组
                        Text("根级（无分组）").tag(String?.none)
                        // 遍历所有分组，为每个分组生成一个选项
                        // model.groups 是顶层分组列表
                        ForEach(model.groups) { group in
                            // 显示分组的完整路径（如 "生产环境/数据库"），让用户清楚层级关系
                            // 尝试获取路径，失败则只显示名称
                            Text((try? groupPath(groupId: group.id)) ?? group.name)
                                // tag 是选项的唯一标识，用于和 $groupID 匹配
                                .tag(String?.some(group.id))
                        }
                    }
                // end Section("主机")
                }

                // ---- 第二个分区：「认证」设置 ----
                // Section 标题显示为 "认证"
                Section("认证") {
                    // 分段选择器：切换密码认证 / 密钥认证
                    // $useKey: false=密码, true=密钥
                    Picker("方式", selection: $useKey) {
                        // 密码认证选项，对应 useKey = false
                        Text("密码").tag(false)
                        // 密钥认证选项，对应 useKey = true
                        Text("密钥").tag(true)
                    }
                    // 以分段按钮样式显示（两个并排的按钮段）
                    .pickerStyle(.segmented)

                    // 根据认证方式显示不同的输入字段
                    // 密钥认证模式
                    if useKey {
                        // 水平排列：私钥路径输入框 + 文件选择按钮
                        HStack {
                            // 手动输入或显示私钥文件路径
                            TextField("私钥路径", text: $keyPath, prompt: Text("~/.ssh/id_ed25519"))
                            // 点击后弹出系统文件选择器，让用户选择私钥文件
                            Button("选择文件…") { pickKey() }
                        }
                        // SecureField：密码输入框，输入内容以圆点遮掩，防止旁人窥视
                        // 私钥口令（passphrase），可以为空
                        SecureField("密钥口令（可选）", text: $passphrase)
                        // Toggle：开关控件，控制是否保存口令到凭据仓库
                        // $savePassphrase 绑定开关状态
                        Toggle("保存口令", isOn: $savePassphrase)
                        // 仅在编辑模式（host != nil）且已有保存的口令时，才显示「清除」按钮
                        if host != nil, existingSecretRef() != nil {
                            // role: .destructive 让按钮文字显示为红色
                            Button("清除已保存的口令", role: .destructive) {
                                // 弹出确认对话框，防止误操作
                                showClearCredentialAlert = true
                            }
                            // 使用小号字体（caption 级别），降低视觉权重
                            .font(.caption)
                            // 文字颜色为红色，强调这是危险操作
                            .foregroundStyle(.red)
                        }
                    // 密码认证模式
                    } else {
                        // SecureField：密码输入框，内容被遮掩
                        SecureField(
                            "密码",
                            text: $password,
                            // prompt 提示文字：如果密码已保存过，显示"已保存"提醒用户；否则显示"输入密码"
                            prompt: Text(host?.passwordSaved == true ? "已保存" : "输入密码")
                        )
                        // Toggle：开关控件，控制是否保存密码到凭据仓库
                        // $savePassword 绑定开关状态
                        Toggle("保存密码", isOn: $savePassword)
                        // 如果用户关闭了「保存密码」开关，显示一行提示
                        if !savePassword {
                            // 告知用户：不保存密码的话每次连接都要手动输入
                            Text("连接时将要求手动输入")
                                // 小号字体
                                .font(.caption)
                                // 次要文字颜色（灰色），降低视觉权重
                                .foregroundStyle(.secondary)
                        }
                        // 仅在编辑模式且密码已保存时，显示「清除」按钮
                        if host != nil, host?.passwordSaved == true {
                            // 红色危险按钮样式
                            Button("清除已保存的密码", role: .destructive) {
                                // 弹出确认对话框
                                showClearCredentialAlert = true
                            }
                            // 小号字体
                            .font(.caption)
                            // 红色文字
                            .foregroundStyle(.red)
                        }
                    }
                // end Section("认证")
                }
            // end Form
            }
            // 导航栏标题：新建时显示"添加主机"，编辑时显示"编辑主机"
            .navigationTitle(host == nil ? "添加主机" : "编辑主机")
            // toolbar：在导航栏上添加操作按钮
            .toolbar {
                // 取消按钮：放在导航栏左侧（cancellationAction 位置）
                // .cancellationAction 在 macOS 上位于左上角
                ToolbarItem(placement: .cancellationAction) {
                    // 点击后调用 dismiss() 关闭表单，不保存任何更改
                    Button("取消") { dismiss() }
                }
                // 保存按钮：放在导航栏右侧（confirmationAction 位置）
                // .confirmationAction 在 macOS 上位于右上角
                ToolbarItem(placement: .confirmationAction) {
                    // 点击后调用 save() 方法保存主机信息
                    Button("保存") { save() }
                        // 当 canSave 为 false（必填字段有空值）时，按钮变灰不可点击
                        .disabled(!canSave)
                }
            // end toolbar
            }
        // end NavigationStack
        }
        // onAppear：视图首次出现时触发，用于加载已有数据到表单
        // 调用 loadExisting() 将 host 的数据填充到 @State 变量
        .onAppear { loadExisting() }
        // 凭据写入失败的告警弹窗
        // isPresented 绑定控制弹窗显示/隐藏
        .alert("无法保存主机", isPresented: $showCredentialError) {
            // 只有一个确认按钮，点击关闭弹窗
            Button("好", role: .cancel) {}
        } message: {
            // 弹窗内的说明文字
            Text("凭据写入本地文件失败，主机未保存。请重试。")
        }
        // 清除已保存凭据的确认弹窗
        // 绑定 showClearCredentialAlert 控制显示
        .alert("清除已保存凭据？", isPresented: $showClearCredentialAlert) {
            // 取消按钮，关闭弹窗不做任何操作
            Button("取消", role: .cancel) {}
            // destructive 红色按钮，确认清除
            Button("清除", role: .destructive) { clearSavedCredential() }
        } message: {
            // 告知用户清除凭据的后果
            Text("清除后下次连接需要重新输入，且不会自动填充。")
        }
        // 条件编译：仅在 macOS 平台生效
        #if os(macOS)
        // 设置表单窗口的最小尺寸，防止窗口太小导致内容被裁切
        .frame(minWidth: 440, minHeight: 420)
        #endif
    // end body
    }

    // ---- 私有方法 ----

    /// 弹出系统文件选择器，让用户选择私钥文件
    private func pickKey() {
        // Task 创建异步任务，因为 pickPrivateKey() 是 async 方法
        Task {
            // await 等待用户完成文件选择
            if let picked = await keyPicker.pickPrivateKey() {
                // 将选中的文件路径赋值给 keyPath，自动更新输入框显示
                keyPath = picked.path
            }
        }
    }

    /// 清除已保存的凭据（密码或私钥口令）
    private func clearSavedCredential() {
        // 确保 host 不为 nil（编辑模式），否则直接返回
        guard let host else { return }
        // 调用 model 删除该主机在凭据仓库中存储的密码/口令
        // 传入主机 ID 和认证类型，定位要删除的凭据
        model.deleteCredentials(for: host.id, auth: host.auth)
        // 如果是密码认证模式
        if host.auth == .password {
            // 关闭「保存密码」开关，反映凭据已被清除的状态
            savePassword = false
        // 如果是密钥认证模式
        } else {
            // 关闭「保存口令」开关
            savePassphrase = false
        }
    }

    /// 加载已有主机数据到表单（编辑模式）或预填复制数据（复制模式）
    private func loadExisting() {
        // 如果 host 为 nil，说明不是编辑模式
        guard let host else {
            // 检查是否有复制来源
            if let copySource {
                // 将复制来源转为草稿，预填到表单
                loadCopy(HostCopyDraft(source: copySource))
                // 预填完毕，返回
                return
            }
            // 新建:默认归属侧栏当前选中分组(或选中主机所在分组)
            // 新建模式下，默认选中传入的分组 ID
            groupID = defaultGroupID
            // 其他字段保持初始空值，返回
            return
        }
        // ---- 以下是编辑模式：将已有主机数据填充到各表单字段 ----
        // 填充主机名称
        name = host.name
        // 填充主机地址
        hostname = host.address
        // 将 UInt16 类型的端口转为字符串，填充到输入框
        port = String(host.port)
        // 填充用户名
        username = host.username
        // 填充备注
        note = host.note
        // 填充所属分组 ID
        groupID = host.groupID
        // 根据认证类型设置分段选择器：publicKey → 密钥模式
        useKey = host.auth == .publicKey
        // 填充「是否保存密码」开关状态
        savePassword = host.passwordSaved
        // 填充「是否保存口令」开关状态
        savePassphrase = host.passphraseSaved
        // 填充私钥文件路径
        keyPath = host.keyPath
        // Mock 模式不落密钥材料，没有可回显的密码；真实模式从本地凭据文件取回。
        // 只有真实后端才存储了凭据，Mock 后端不存储
        if !model.usesMockBackend {
            // 尝试获取已保存的凭据引用，再从凭据仓库读取实际值
            if let ref = existingSecretRef(), let secret = try? PandaCoreBridge.shared.storedCredential(reference: ref) {
                // 根据认证类型，将凭据填入对应的字段
                if host.auth == .publicKey { passphrase = secret } else { password = secret }
            }
        }
    }

    /// 从复制来源预填表单（不复制敏感信息）
    private func loadCopy(_ draft: HostCopyDraft) {
        // 复制主机名称
        name = draft.name
        // 复制主机地址
        hostname = draft.address
        // 复制端口号
        port = String(draft.port)
        // 复制用户名
        username = draft.username
        // 复制备注
        note = draft.note
        // 复制所属分组
        groupID = draft.groupID
        // 复制认证方式
        useKey = draft.auth == .publicKey
        // 复制私钥路径（只是路径字符串，不涉及实际密钥文件）
        keyPath = draft.keyPath
        // 密码不复制，留空
        password = ""
        // 口令不复制，留空
        passphrase = ""
        // 密码保存状态重置为 false
        savePassword = false
        // 口令保存状态重置为 false
        savePassphrase = false
    }

    /// 获取当前主机已保存的凭据引用 key（用于读取或清除凭据）
    private func existingSecretRef() -> String? {
        // 编辑模式才有已保存的凭据
        guard let host else { return nil }
        // 将 host 转为配置记录，从中提取凭据引用
        switch host.toConfigRecord().auth {
        // 密码认证：返回密码的引用 key
        case .password(let ref): return ref
        // 密钥认证：返回口令的引用 key
        case .publicKey(_, let ref): return ref
        }
    }

    /// 保存主机信息到后端
    private func save() {
        // 判断是新建还是编辑
        let isNew = host == nil
        // 构造 HostEntry 对象，包含所有表单字段
        var entry = HostEntry(
            // 编辑时保留原 ID；新建时生成新的唯一 ID（前缀 h-）
            id: host?.id ?? "h-\(UUID().uuidString)",
            // 去除名称首尾空格
            name: name.trimmingCharacters(in: .whitespaces),
            // 去除地址首尾空格
            address: hostname.trimmingCharacters(in: .whitespaces),
            // 将字符串端口转为 UInt16，转换失败则默认 22
            port: UInt16(port) ?? 22,
            // 去除用户名首尾空格
            username: username.trimmingCharacters(in: .whitespaces),
            // 去除备注首尾空格
            note: note.trimmingCharacters(in: .whitespaces),
            // 所属分组 ID，nil 表示根级
            groupID: groupID,
            // 根据 useKey 开关决定认证类型枚举
            auth: useKey ? .publicKey : .password,
            // 密钥模式时保存路径，密码模式时留空
            keyPath: useKey ? keyPath.trimmingCharacters(in: .whitespaces) : "",
            // 密钥模式下 passwordSaved 始终为 false
            passwordSaved: useKey ? false : savePassword,
            // 密码模式下 passphraseSaved 始终为 false
            passphraseSaved: useKey ? savePassphrase : false,
            // 保留已有的主机密钥指纹（编辑时）
            fingerprint: host?.fingerprint,
            // 指纹算法，默认 ssh-ed25519
            fingerprintAlgorithm: host?.fingerprintAlgorithm ?? "ssh-ed25519",
            // 保留 demo 标记（原型演示数据用）
            demo: host?.demo
        )
        if isNew {
            // 新主机从未连接:标记为「未验证」,首次连接走 TOFU 确认(与原型一致)
            // 新建主机没有指纹记录，首次连接时触发 TOFU 流程
            entry.fingerprint = nil
            // 标记为「未知」状态（未验证过主机密钥）
            entry.demo = .unknown
        }
        // 处理敏感信息：空字符串视为 nil（不保存）
        // 密码为空则不保存
        let passwordSecret = password.isEmpty ? nil : password
        // 口令为空则不保存
        let passphraseSecret = passphrase.isEmpty ? nil : passphrase
        // 调用 model 保存主机，同时传入密码和口令；返回 false 表示凭据写入失败
        guard model.saveHost(entry, password: passwordSecret, passphrase: passphraseSecret) else {
            // 保存失败，弹出错误提示弹窗
            showCredentialError = true
            // 不关闭表单，让用户可以重试
            return
        }
        // 保存成功，关闭表单
        dismiss()
    }
}

// ---- Xcode 预览配置 ----
// 仅在 Debug 模式下注册预览，Release 构建不包含预览代码
#if DEBUG
// Xcode Canvas 中的预览场景：新建主机
#Preview("添加主机") {
    // host 为 nil，进入新建模式
    HostEditView(host: nil)
        // 注入用于预览的 Mock 数据模型
        .environmentObject(AppModel.previewModel())
}

// 预览场景：编辑一个使用密钥认证的主机
#Preview("编辑主机(密钥认证)") {
    // 从 Mock 数据中找到第一个密钥认证的主机
    HostEditView(host: MockBackend.demo().allHosts().first { $0.auth == .publicKey }!)
        // 注入预览数据模型
        .environmentObject(AppModel.previewModel())
}
#endif
