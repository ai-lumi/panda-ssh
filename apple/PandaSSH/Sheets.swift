// ============================================================================
// Sheets.swift — 可复用对话框组件集合
//
// 本文件包含多个独立的对话框视图，用于 SSH 连接过程中的各种交互场景：
//
// 1. FingerprintBox — 指纹展示块（基础组件）
//    显示主机密钥指纹，支持高亮异常指纹（红色描边）
//
// 2. TofuConfirmSheet — TOFU 指纹确认对话框
//    首次连接未知主机时弹出，让用户核对并信任主机密钥
//    TOFU = Trust On First Use（首次使用信任）
//
// 3. HostKeyMismatchSheet — 主机密钥变更告警对话框
//    当服务器密钥与本地记录不一致时弹出，提示可能的安全风险
//    （服务器重装或中间人攻击）
//
// 4. PasswordPromptSheet — 密码/口令输入对话框
//    手动输入登录密码或私钥口令，仅用于当前会话，不保存
//
// 5. KeyPickerSheet — 私钥选择提示对话框
//    当密钥认证主机缺少私钥路径时弹出，引导用户选择私钥文件
//
// 6. GroupNameSheet — 分组名称输入对话框
//    新建/重命名分组时弹出，输入分组名称
//
// 这些对话框在连接流程的不同阶段触发，提供安全提示和用户交互。
// ============================================================================

// 导入 SwiftUI 框架
import SwiftUI

// ============================================================================
// FingerprintBox — 指纹展示块
// ============================================================================

/// 指纹展示块:标签 + 等宽指纹,isBad 时红色描边(密钥变更对比用)。
/// 用于显示主机密钥的 SHA256 指纹，等宽字体便于用户核对
struct FingerprintBox: View {
    // 标签文字，如 "ssh-ed25519 指纹"
    let label: String
    // 指纹字符串，如 "SHA256:xxxxx..."
    let fingerprint: String
    // 是否标记为异常（用于密钥变更告警场景）
    var isBad = false

    var body: some View {
        // 垂直排列，左对齐，间距 3pt
        VStack(alignment: .leading, spacing: 3) {
            // 标签文字
            Text(label)
                // 字体：caption 级别（小号），加粗
                .font(.caption).bold()
                // 文字颜色：次要色（灰色）
                .foregroundStyle(.secondary)
            // 指纹字符串
            Text(fingerprint)
                // 字体：caption 级别，等宽字体（便于核对字符）
                .font(.system(.caption, design: .monospaced))
                // 允许用户选中和复制指纹
                .textSelection(.enabled)
                // 固定尺寸：水平方向可换行，垂直方向自适应
                .fixedSize(horizontal: false, vertical: true)
        }
        // 宽度填满，左对齐
        .frame(maxWidth: .infinity, alignment: .leading)
        // 内边距：四周各 10pt
        .padding(10)
        // 背景：半透明材质（系统自适应深浅色）
        .background(.regularMaterial)
        // 异常时叠加淡红色背景（5% 不透明度）
        .background(isBad ? Color.red.opacity(0.05) : Color.clear)
        // 裁剪为圆角矩形（半径 8pt）
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // 叠加层：用于绘制边框
        .overlay(
            // Group 用于条件判断
            Group {
                // 仅在异常时绘制边框
                if isBad {
                    // 圆角矩形
                    RoundedRectangle(cornerRadius: 8)
                        // 描边：红色（50% 不透明度），线宽 1pt
                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                }
            }
        )
    }
}

// ============================================================================
// TofuConfirmSheet — TOFU 指纹确认对话框
// ============================================================================

/// TOFU 指纹确认:未知主机密钥,「取消 / 信任并连接」。
/// 首次连接未知主机时弹出，让用户核对服务器出示的指纹，确认无误后信任
struct TofuConfirmSheet: View {
    // 待连接的主机信息
    let host: HostEntry
    /// 对方本次出示的指纹
    // 服务器本次连接出示的主机密钥指纹
    let fingerprint: String
    // 用户点击「信任并连接」时的回调
    var onTrust: () -> Void = {}
    // 用户点击「取消」时的回调
    var onCancel: () -> Void = {}
    // 关闭弹窗的环境值
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // 垂直排列，间距 16pt
        VStack(spacing: 16) {
            // 警告图标：橙色三角形感叹号
            // 系统图标：感叹号三角形
            Image(systemName: "exclamationmark.triangle")
                // 图标大小：40pt
                .font(.system(size: 40))
                // 图标颜色：橙色（警告色）
                .foregroundStyle(.orange)
            // 标题文字
            Text("未知主机密钥")
                // 字体：headline 级别（标题）
                .font(.headline)
            // 说明文字：解释 TOFU 机制，提醒用户核对指纹
            Text("首次连接 **\(host.name)**（\(host.address):\(host.port)）。\n请核对服务器出示的主机密钥指纹，确认无误后再信任。信任后指纹将被记录，之后连接不再询问。")
                // 字体：callout 级别（中等）
                .font(.callout)
                // 文字颜色：次要色（灰色）
                .foregroundStyle(.secondary)
                // 多行文字居中对齐
                .multilineTextAlignment(.center)
            // 指纹展示块：显示服务器出示的指纹
            // 传入算法名称和指纹值
            FingerprintBox(label: "\(host.fingerprintAlgorithm) 指纹", fingerprint: fingerprint)
            // 水平排列按钮，间距 12pt
            HStack(spacing: 12) {
                // 取消按钮：调用回调后关闭弹窗
                Button("取消", role: .cancel) { onCancel(); dismiss() }
                // 信任按钮：调用回调后关闭弹窗
                Button("信任并连接") { onTrust(); dismiss() }
                    // 按钮样式：突出显示（实心填充）
                    .buttonStyle(.borderedProminent)
            }
            // 顶部内边距：4pt，与上方指纹块保持间距
            .padding(.top, 4)
        }
    }
}

// ============================================================================
// HostKeyMismatchSheet — 主机密钥变更告警对话框
// ============================================================================

/// 主机密钥变更红色告警:已记录 vs 对方出示指纹对比,仅「断开连接」。
/// 当服务器密钥与本地记录不一致时弹出，提示可能的安全风险（服务器重装或中间人攻击）
struct HostKeyMismatchSheet: View {
    // 连接失败的主机信息
    let host: HostEntry
    /// 本地已记录(known_hosts)的指纹
    // 本地 known_hosts 文件中记录的指纹
    let recordedFingerprint: String
    /// 对方本次出示的指纹
    // 服务器本次连接出示的指纹（与记录不一致）
    let presentedFingerprint: String
    // 用户点击「断开连接」时的回调
    var onDisconnect: () -> Void = {}
    // 关闭弹窗的环境值
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // 垂直排列，间距 16pt
        VStack(spacing: 16) {
            // 错误图标：红色圆形感叹号
            // 系统图标：感叹号圆形
            Image(systemName: "exclamationmark.circle")
                // 图标大小：40pt
                .font(.system(size: 40))
                // 图标颜色：红色（错误色）
                .foregroundStyle(.red)
            // 标题文字
            Text("服务器密钥已变更！")
                // 字体：headline 级别
                .font(.headline)
                // 文字颜色：红色（强调危险）
                .foregroundStyle(.red)
            // 说明文字：解释风险，提示可能的原因
            Text("「\(host.name)」出示的主机密钥与本地记录**不一致**。\n服务器可能被重装，也可能正在遭遇**中间人攻击**。为安全起见已中断连接。")
                // 字体：callout 级别
                .font(.callout)
                // 文字颜色：次要色
                .foregroundStyle(.secondary)
                // 多行文字居中对齐
                .multilineTextAlignment(.center)
            // 垂直排列两个指纹块，间距 8pt
            VStack(spacing: 8) {
                // 显示本地记录的指纹
                FingerprintBox(label: "已记录指纹（known_hosts）", fingerprint: recordedFingerprint)
                // 显示服务器出示的指纹，标记为异常（红色描边）
                FingerprintBox(label: "对方出示指纹", fingerprint: presentedFingerprint, isBad: true)
            }
            // 断开按钮：destructive 红色样式
            Button("断开连接", role: .destructive) { onDisconnect(); dismiss() }
                // 按钮样式：突出显示
                .buttonStyle(.borderedProminent)
                // 按钮色调：红色（覆盖默认蓝色）
                .tint(.red)
                // 顶部内边距：4pt
                .padding(.top, 4)
        }
    }
}

// ============================================================================
// PasswordPromptSheet — 密码/口令输入对话框
// ============================================================================

/// 手动输入密码或私钥口令：秘密仅用于本次标签页会话，不共享、不落盘。
/// 当连接需要密码但未保存时弹出，用户输入后仅用于当前连接，不持久化
struct PasswordPromptSheet: View {
    // 待连接的主机信息
    let host: HostEntry
    // 用户点击「登录」时的回调，传入输入的密码/口令
    var onLogin: (String) -> Void = { _ in }
    // 用户点击「取消」时的回调
    var onCancel: () -> Void = {}
    // 关闭弹窗的环境值
    @Environment(\.dismiss) private var dismiss
    // 用户输入的密码/口令（@State 本地状态）
    @State private var password = ""

    var body: some View {
        // 垂直排列，左对齐，间距 22pt
        VStack(alignment: .leading, spacing: 22) {
            // 水平排列图标和标题，垂直居中，间距 14pt
            HStack(alignment: .center, spacing: 14) {
                // 锁图标：表示需要输入密码
                // 系统图标：实心锁
                Image(systemName: "lock.fill")
                    // 图标大小 20pt，半粗体
                    .font(.system(size: 20, weight: .semibold))
                    // 图标颜色：主题强调色
                    .foregroundStyle(Color.accentColor)
                    // 图标容器尺寸：44x44pt
                    .frame(width: 44, height: 44)
                    // 背景：主题色圆形（14% 不透明度）
                    .background(Color.accentColor.opacity(0.14), in: Circle())

                // 垂直排列标题和副标题，左对齐，间距 3pt
                VStack(alignment: .leading, spacing: 3) {
                    // 根据认证类型显示不同标题
                    Text(host.auth == .password ? "输入登录密码" : "输入私钥口令")
                        // 字体：title3 级别，半粗体
                        .font(.title3.weight(.semibold))
                    // 显示连接目标（用户名@地址:端口）
                    Text("连接至 \(host.username)@\(host.address):\(host.port)")
                        // 字体：subheadline 级别（小号）
                        .font(.subheadline)
                        // 文字颜色：次要色
                        .foregroundStyle(.secondary)
                        // 限制为 1 行
                        .lineLimit(1)
                        // 超长时从中间截断（保留用户名和端口）
                        .truncationMode(.middle)
                }
            }

            // 垂直排列密码输入区，左对齐，间距 8pt
            VStack(alignment: .leading, spacing: 8) {
                // 输入框标签
                Text(host.auth == .password ? "密码" : "私钥口令")
                    // 字体：subheadline 级别，中等粗细
                    .font(.subheadline.weight(.medium))
                // 密码输入框（内容遮掩）
                SecureField(host.auth == .password ? "请输入密码" : "请输入私钥口令", text: $password)
                    // 输入框样式：圆角边框
                    .textFieldStyle(.roundedBorder)
                    // 按回车键时调用 submit()
                    .onSubmit(submit)
            }

            // 安全提示文字
            Text("仅用于当前标签页，关闭标签后即销毁。")
                // 字体：caption 级别（小号）
                .font(.caption)
                // 文字颜色：次要色
                .foregroundStyle(.secondary)

            // 水平排列按钮，间距 12pt
            HStack(spacing: 12) {
                // 弹性空间，将按钮推到右侧
                Spacer()
                // 取消按钮
                Button("取消", role: .cancel) { onCancel(); dismiss() }
                // 登录按钮
                Button("登录") { submit() }
                    // 按钮样式：突出显示
                    .buttonStyle(.borderedProminent)
                    // 键盘快捷键：回车键（默认操作）
                    .keyboardShortcut(.defaultAction)
                    // 密码为空时禁用按钮
                    .disabled(password.isEmpty)
            }
        }
        // 内边距：四周各 28pt
        .padding(28)
        // 固定宽度：430pt，左对齐
        .frame(width: 430, alignment: .leading)
    }

    // ---- 提交方法 ----
    private func submit() {
        // 密码不为空才继续
        guard !password.isEmpty else { return }
        // 秘密只随回调进入该标签页会话，不做任何缓存。
        // 调用回调，将密码传递给连接逻辑
        onLogin(password)
        // 关闭弹窗
        dismiss()
    }
}

// ============================================================================
// KeyPickerSheet — 私钥选择提示对话框
// ============================================================================

/// 私钥选择提示:远端同步过来的密钥认证主机在本机缺少私钥路径时弹出。
/// 引导用户选择本机可用的私钥文件
struct KeyPickerSheet: View {
    // 需要私钥的主机信息
    let host: HostEntry
    // 用户选择私钥后的回调，传入私钥文件路径
    var onPick: (String) -> Void = { _ in }
    // 用户点击「取消」时的回调
    var onCancel: () -> Void = {}
    // 关闭弹窗的环境值
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // 垂直排列，间距 16pt
        VStack(spacing: 16) {
            // 钥匙图标：表示需要私钥
            // 系统图标：实心钥匙
            Image(systemName: "key.fill")
                // 图标大小：36pt
                .font(.system(size: 36))
                // 图标颜色：主题强调色
                .foregroundStyle(Color.accentColor)
            // 标题文字
            Text("需要私钥")
                // 字体：headline 级别
                .font(.headline)
            // 说明文字
            Text("主机 **\(host.name)** 使用密钥认证，但本机尚未选择私钥文件。请选择本机可用的私钥。")
                // 字体：callout 级别
                .font(.callout)
                // 文字颜色：次要色
                .foregroundStyle(.secondary)
                // 多行文字居中对齐
                .multilineTextAlignment(.center)
            // 选择私钥按钮
            Button {
                // 异步任务：文件选择器是 async 操作
                Task {
                    // 等待用户选择文件
                    if let picked = await SystemKeyPicker.shared.pickPrivateKey() {
                        // 调用回调，传入选中的文件路径
                        onPick(picked.path)
                        // 关闭弹窗
                        dismiss()
                    }
                }
            // 按钮标签：图标 + 文字
            } label: {
                // 系统图标：文档带向上箭头
                Label("选择私钥文件", systemImage: "doc.badge.arrow.up")
            }
            // 按钮样式：突出显示
            .buttonStyle(.borderedProminent)
            // 取消按钮
            Button("取消", role: .cancel) { onCancel(); dismiss() }
        }
    }
}

// ============================================================================
// GroupNameSheet — 分组名称输入对话框
// ============================================================================

/// 分组名称输入:新建分组 / 新建子分组 / 重命名分组共用。
/// 提供简单的文本输入界面，用于输入分组名称
struct GroupNameSheet: View {
    // 对话框标题，如 "新建分组" 或 "重命名分组"
    let title: String
    /// 说明文字(如「在「生产环境」下创建子分组：」),可为空
    // 可选的说明文字，提供额外上下文
    var message: String = ""
    // 初始值（重命名时传入原名称）
    var initial: String = ""
    // 用户点击「确定」时的回调，传入输入的分组名称
    var onDone: (String) -> Void = { _ in }
    // 关闭弹窗的环境值
    @Environment(\.dismiss) private var dismiss
    // 用户输入的分组名称（@State 本地状态）
    @State private var name = ""

    var body: some View {
        // 垂直排列，左对齐，间距 12pt
        VStack(alignment: .leading, spacing: 12) {
            // 标题文字，headline 字体
            Text(title).font(.headline)
            // 如果有说明文字
            if !message.isEmpty {
                // 显示说明文字
                Text(message)
                    // 字体：callout 级别
                    .font(.callout)
                    // 文字颜色：次要色
                    .foregroundStyle(.secondary)
            }
            // 文本输入框
            TextField("分组名称", text: $name)
                // 输入框样式：圆角边框
                .textFieldStyle(.roundedBorder)
                // 按回车键时调用 submit()
                .onSubmit(submit)
            // 水平排列按钮
            HStack {
                // 弹性空间，将按钮推到右侧
                Spacer()
                // 取消按钮
                Button("取消", role: .cancel) { dismiss() }
                // 确定按钮
                Button("确定") { submit() }
                    // 按钮样式：突出显示
                    .buttonStyle(.borderedProminent)
                    // 名称为空时禁用
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        // 内边距：四周各 20pt
        .padding(20)
        // 窗口宽度：最小 320pt，理想 360pt
        .frame(minWidth: 320, idealWidth: 360)
        // 视图出现时填充初始值
        .onAppear { name = initial }
    }

    // ---- 提交方法 ----
    private func submit() {
        // 去除首尾空格
        let value = name.trimmingCharacters(in: .whitespaces)
        // 名称不为空才继续
        guard !value.isEmpty else { return }
        // 调用回调，传入分组名称
        onDone(value)
        // 关闭弹窗
        dismiss()
    }
}

// ---- Xcode 预览配置 ----
// 仅在 Debug 模式下注册预览
#if DEBUG
// 预览场景：首次连接未知主机
#Preview("TOFU 指纹确认") {
    // 从 Mock 数据中找到未知主机
    TofuConfirmSheet(host: MockBackend.demo().allHosts().first { $0.demo == .unknown }!,
                     // 使用演示指纹
                     fingerprint: DemoData.FP.newtoy)
}

// 预览场景：主机密钥变更
#Preview("密钥变更告警") {
    // 从 Mock 数据中找到密钥不匹配的主机
    HostKeyMismatchSheet(host: MockBackend.demo().allHosts().first { $0.demo == .mismatch }!,
                         // 本地记录的旧指纹
                         recordedFingerprint: DemoData.FP.legacyOld,
                         // 服务器出示的新指纹
                         presentedFingerprint: DemoData.FP.legacyNew)
}

// 预览场景：手动输入密码
#Preview("手动输入密码") {
    // 从 Mock 数据中找到需要手动输入密码的主机
    PasswordPromptSheet(host: MockBackend.demo().allHosts().first { $0.demo == .manual }!)
}

// 预览场景：新建子分组
#Preview("分组名称输入") {
    // 传入标题和说明文字
    GroupNameSheet(title: "新建子分组", message: "在「生产环境」下创建子分组：")
}
#endif
