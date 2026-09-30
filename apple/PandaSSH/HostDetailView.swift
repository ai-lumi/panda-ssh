// ============================================================
// 文件: HostDetailView.swift
// 功能: 主机详情页面，展示选中 SSH 主机的完整信息。
//       包括：大图标、主机名称、连接地址（user@host:port）、
//       备注说明、分组/认证方式/主机密钥状态等标签（chips），
//       以及已记录的主机密钥指纹信息。底部提供两个操作按钮：
//       "打开终端"和"浏览文件 (SFTP)"。
// ============================================================

// 导入 SwiftUI 框架
import SwiftUI

/// 主机详情页:大图标、名称、user@host:port、备注、分组/认证/指纹 chips、
/// 已记录指纹(等宽)+ 算法,以及「打开终端」「浏览文件 (SFTP)」按钮。
/// 布局与文案参照 prototype/index.html 的 renderHostDetail。
struct HostDetailView: View {
    // 从环境注入的应用状态模型
    @EnvironmentObject private var model: AppModel
    // 从环境注入的工作区存储，用于打开终端/SFTP 标签页
    @EnvironmentObject private var workspace: WorkspaceStore
    // 要展示的主机条目，由外部传入（不可变）
    let host: HostEntry

    // 定义详情页的主体布局
    var body: some View {
        // 垂直堆叠容器，子视图间距 10pt
        VStack(spacing: 10) {
            // 弹性空白，将后续内容向下推，实现垂直居中效果
            Spacer()

            // 显示服务器机架图标（SF Symbols 系统图标）
            Image(systemName: "server.rack")
                // 设置图标大小为 52pt，视觉突出
                .font(.system(size: 52))
                // 使用应用主题色（accentColor）填充图标，通常是品牌色
                .foregroundStyle(Color.accentColor)

            // 显示主机名称
            Text(host.name)
                // 使用 title2 字号（较大标题）并加粗
                .font(.title2).bold()

            // 显示主机副标题（格式：user@host:port）
            Text(host.subtitle)
                // 使用 callout 字号 + 等宽字体设计，便于阅读地址
                .font(.system(.callout, design: .monospaced))
                // 使用次要文本颜色（灰色），降低视觉权重
                .foregroundStyle(.secondary)

            // 如果主机有备注信息，则显示备注
            if !host.note.isEmpty {
                Text(host.note)
                    // 使用 caption 字号（较小）
                    .font(.caption)
                    // 次要颜色（灰色）
                    .foregroundStyle(.secondary)
                    // 多行文本居中对齐
                    .multilineTextAlignment(.center)
            }

            // 显示标签组（分组、认证方式、密钥状态等）
            chips

            // 如果主机已记录指纹，则显示指纹详情区域
            if let fingerprint = host.fingerprint {
                // 垂直堆叠指纹信息，间距 4pt
                VStack(spacing: 4) {
                    // 显示指纹算法名称（如 "SHA256"）
                    Text(host.fingerprintAlgorithm)
                        // 使用 caption 字号 + 等宽字体
                        .font(.system(.caption, design: .monospaced))
                        // 次要颜色
                        .foregroundStyle(.secondary)

                    // 显示实际的指纹字符串
                    Text(fingerprint)
                        // 使用 caption 字号 + 等宽字体
                        .font(.system(.caption, design: .monospaced))
                        // 启用文本选择，用户可以复制指纹
                        .textSelection(.enabled)
                        // 多行文本居中对齐（指纹可能换行）
                        .multilineTextAlignment(.center)
                }
                // 内边距：上下 10pt，左右 14pt
                .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                // 限制最大宽度为 520pt，防止指纹区域过宽
                .frame(maxWidth: 520)
                // 背景使用半透明材质（regularMaterial），形状为圆角矩形（圆角半径 8pt）
                // regularMaterial 是系统提供的模糊背景效果，类似毛玻璃
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            // 水平堆叠两个操作按钮，间距 10pt
            HStack(spacing: 10) {
                // "打开终端"按钮
                Button {
                    // 点击时调用 workspace.openTerminal 打开终端标签页
                    // 然后通过 model.presentTab 将其呈现为活动标签
                    model.presentTab(workspace.openTerminal(hostID: host.id))
                } label: {
                    // 按钮标签：Apple 官方终端图标 + 文字
                    Label("打开终端", systemImage: "apple.terminal")
                }
                // 使用突出的边框按钮样式（填充背景色，视觉权重高）
                .buttonStyle(.borderedProminent)

                // "浏览文件 (SFTP)"按钮
                Button {
                    // 点击时调用 workspace.openSFTP 打开 SFTP 文件浏览标签页
                    model.presentTab(workspace.openSFTP(hostID: host.id))
                } label: {
                    // 按钮标签：填充版文件夹图标 + 文字
                    Label("浏览文件 (SFTP)", systemImage: "folder.fill")
                }
                // 使用普通边框按钮样式（仅边框，无填充背景，视觉权重较低）
                .buttonStyle(.bordered)
            }
            // 顶部外边距 6pt，与上方内容拉开距离
            .padding(.top, 6)

            // 弹性空白，将上方内容向上推，配合实现垂直居中
            Spacer()
        }
        // 水平方向尽可能占满可用空间（maxWidth: .infinity）
        .frame(maxWidth: .infinity)
        // 整体内边距 24pt，避免内容贴边
        .padding(24)
    }

    /// 分组 / 认证方式 / 密钥状态 chips（小胶囊标签）
    private var chips: some View {
        // 水平堆叠所有标签，间距 6pt
        HStack(spacing: 6) {
            // 第一个标签：显示分组路径
            // 调用 groupPath 函数获取分组的完整路径（如 "生产环境/Web 服务器"）
            // 如果获取失败或无分组，则显示 "根级"
            Chip(text: "分组：\((try? groupPath(groupId: host.groupID ?? "")) ?? "根级")")

            // 第二个标签：显示认证方式
            // authLabel 计算属性返回 "密钥 xxx" 或 "密码（已保存/未保存）"
            // 图标根据认证类型：公钥显示 "key"，密码显示 "lock"
            Chip(text: authLabel, systemImage: host.auth == .publicKey ? "key" : "lock")

            // 如果主机处于 demo.mismatch 状态（密钥不匹配），显示红色告警标签
            if host.demo == .mismatch {
                Chip(text: "⚠ 主机密钥不匹配", tint: .red)
            }

            // 如果主机已记录指纹，显示绿色确认标签
            if host.fingerprint != nil {
                Chip(text: "✓ 主机密钥已记录", tint: .green)
            } else {
                // 否则显示未验证状态的标签（无特殊颜色）
                Chip(text: "主机密钥未验证")
            }
        }
    }

    /// 计算属性：根据认证方式返回描述文本
    private var authLabel: String {
        // 根据主机的认证类型分支
        switch host.auth {
        case .publicKey:
            // 公钥认证：显示 "密钥" + 密钥文件路径
            return "密钥 \(host.keyPath)"
        case .password:
            // 密码认证：根据密码是否已保存显示不同文案
            return host.passwordSaved ? "密码（已保存）" : "密码（未保存）"
        }
    }
}

// ============================================================
// Chip：小胶囊标签组件
// 用于显示分组、认证方式、密钥状态等简短信息
// 视觉特点：圆角胶囊形状、半透明背景、可选图标和颜色
// ============================================================

/// 小胶囊标签
private struct Chip: View {
    // 标签显示的文本内容
    let text: String
    // 可选的系统图标（SF Symbols），默认为 nil 不显示
    var systemImage: String? = nil
    // 可选的主题色，默认为 nil 使用次要颜色
    var tint: Color? = nil

    // 定义标签的布局
    var body: some View {
        // 水平堆叠图标和文字，间距 4pt
        HStack(spacing: 4) {
            // 如果提供了系统图标，则显示
            if let systemImage {
                Image(systemName: systemImage)
                    // 图标缩放为小号（.small），适配标签尺寸
                    .imageScale(.small)
            }
            // 显示标签文本
            Text(text)
        }
        // 使用 caption2 字号（非常小的标题字号）
        .font(.caption2)
        // 水平内边距 8pt，给文字左右留白
        .padding(.horizontal, 8)
        // 垂直内边距 3pt，给文字上下留白
        .padding(.vertical, 3)
        // 背景使用胶囊形状（Capsule），颜色根据 tint 决定：
        // - 如果 tint 为 nil：使用 .primary 颜色，透明度 0.06（非常浅）
        // - 如果 tint 有值：使用 tint 颜色，透明度 0.14（稍深）
        .background((tint ?? .primary).opacity(tint == nil ? 0.06 : 0.14), in: Capsule())
        // 前景色（文字和图标颜色）：如果有 tint 则用 tint，否则用 .secondary（灰色）
        .foregroundStyle(tint ?? .secondary)
    }
}

// ============================================================
// Xcode Preview 预览（仅 DEBUG 模式）
// 用于在 Xcode Canvas 中实时查看主机详情页的不同状态
// ============================================================

#if DEBUG
// 预览场景 1：正常状态，主机已记录指纹
#Preview("主机详情(已记录指纹)") {
    HostDetailView(host: MockBackend.demo().allHosts().first { $0.id == "h-webprod" }!)
        // 注入预览用的假数据模型
        .environmentObject(AppModel.previewModel())
        // 注入预览用的假工作区存储
        .environmentObject(WorkspaceStore.previewStore())
        // 注入空的 toast 中心
        .environmentObject(ToastCenter())
}

// 预览场景 2：异常状态，主机密钥不匹配
#Preview("主机详情(密钥不匹配)") {
    HostDetailView(host: MockBackend.demo().allHosts().first { $0.id == "h-legacy" }!)
        .environmentObject(AppModel.previewModel())
        .environmentObject(WorkspaceStore.previewStore())
        .environmentObject(ToastCenter())
}
#endif
