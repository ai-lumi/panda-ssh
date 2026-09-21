// =============================================================================
// SettingsView.swift — 设置页面（通用 + 终端两个标签）
//
// 本文件实现应用的设置界面，包括：
//   1. 通用标签：配置导入/导出、密码保护（加密凭据）、关于信息
//   2. 终端标签：终端缓冲区行数设置
//
// macOS 上设置页以独立窗口形式呈现（通过 cmd+, 打开），
// iPadOS 上设置页通过侧栏入口进入，使用 NavigationStack 导航。
// 两端共享同一套设置内容和标签结构。
// =============================================================================

// 引入 SwiftUI 框架
import SwiftUI
// 引入 UTType，用于文件类型标识（导入/导出配置文件）
import UniformTypeIdentifiers

/// 设置中显式操作在分区内的对齐位置。
/// 目前只支持 trailing（右对齐），预留扩展性。
enum SettingsActionAlignment: Equatable {
    // 操作按钮右对齐
    case trailing
}

/// 设置表单的可见呈现契约。
///
/// 此处只描述控件和文案，不承担缓冲区行数的解析、范围校验或默认值决策。
/// 将表单的视觉参数集中管理，便于统一调整。
enum SettingsFormContract {
    /// macOS 会把 TextField 的标题绘制为可见标签，因此保持为空；
    /// 字段的可访问名称由 `terminalBufferInputAccessibilityLabel` 单独提供。
    // TextField 的占位文字（macOS 上为空，避免重复标签）
    static let terminalBufferInputPrompt = ""
    // 无障碍标签（VoiceOver 朗读用）
    static let terminalBufferAccessibilityLabel = "缓冲区高度（行）"
    // 输入框下方的提示文字
    static let terminalBufferHelperText = "范围 1000 ～ 100000"
    // 是否使用步进器（+/- 按钮），当前不使用
    static let terminalBufferUsesStepper = false
    // 文本框左右的步进按钮
    static let terminalBufferHasDecrementButton = true
    static let terminalBufferHasIncrementButton = true
    static let terminalBufferDecrementButtonAccessibilityLabel = "减小缓冲区高度"
    static let terminalBufferIncrementButtonAccessibilityLabel = "增大缓冲区高度"
    // iPadOS 上是否使用数字键盘
    static let terminalBufferUsesNumberPad = true
    // 是否将输入框和提示放在同一行
    static let terminalBufferUsesSingleFormRow = true
    // 提示文字是否与输入框右对齐
    static let terminalBufferHelperAlignsWithInput = true
    // 操作按钮对齐方式
    static let explicitActionAlignment: SettingsActionAlignment = .trailing
}

/// 设置页标签目录。仅展示已实现功能的分类。
/// 每个标签对应设置页中的一个面板（通用、终端）。
enum SettingsTab: String, CaseIterable, Identifiable {
    // 通用设置
    case general
    // 终端设置
    case terminal

    // Identifiable 协议要求，用自身作为唯一标识
    var id: Self { self }

    /// 标签的显示标题
    var title: String {
        switch self {
        case .general: "通用"
        case .terminal: "终端"
        }
    }

    /// 标签的 SF Symbols 图标名称
    var systemImage: String {
        switch self {
        // 齿轮图标
        case .general: "gear"
        // 终端图标
        case .terminal: "terminal"
        }
    }
}

/// 凭据保护的可信展示状态。
/// 用于驱动设置页中密码保护区域的 UI 显示（不同状态显示不同的表单）。
enum ProtectionDisplayState: Equatable {
    /// 未启用保护（凭据以明文存储）
    case unprotected
    /// 已启用但锁定（重启后未解锁，需要输入密码才能访问凭据）
    case locked
    /// 已启用且已解锁（凭据已可正常使用）
    case unlocked
    /// 读取保护状态时发生错误，携带错误信息
    case readError(String)
    /// 正在执行操作中（显示加载指示器）
    case processing
}

/// 设置页：macOS 走原生 Settings Scene（cmd+,），iPadOS 走侧栏入口。
/// 两端共享同一组标签和设置内容；仅导航容器与平台服务有所不同。
struct SettingsView: View {
    /// 应用数据模型
    @EnvironmentObject private var model: AppModel
    /// 导入操作出错时的错误信息（非 nil 时弹出错误对话框）
    @State private var importError: String?
    /// 导入操作成功时的成功信息（非 nil 时弹出成功对话框）
    @State private var importSuccess: String?
    /// 是否显示导入文件选择器
    @State private var showImportPicker = false

    // 密码保护表单状态
    /// 当前密码保护的展示状态（驱动 UI 显示不同的表单）
    @State private var protectionState: ProtectionDisplayState = .unprotected
    /// 当前保护密码输入框的内容（解锁/更换密码/移除保护时使用）
    @State private var currentProtectionKey = ""
    /// 新保护密码输入框的内容（启用保护/更换密码时使用）
    @State private var newProtectionKey = ""
    /// 确认新保护密码输入框的内容（必须与新密码一致）
    @State private var confirmProtectionKey = ""
    /// 密码保护操作的错误信息
    @State private var protectionError: String?
    /// 密码保护操作的成功信息
    @State private var protectionSuccess: String?
    /// 是否显示移除保护确认对话框
    @State private var showRemoveConfirmation = false

    // 终端缓冲区设置
    /// 缓冲区行数的文本输入内容（用户输入的数字字符串）
    @State private var bufferLinesText = ""

    /// 当前选中的设置标签（默认"通用"）
    @State private var selectedTab: SettingsTab = .general

    /// 设置页主体：根据平台选择不同的布局容器
    var body: some View {
        #if os(macOS)
        // macOS：固定大小的窗口布局
        macOSBody
        #else
        // iPadOS：带导航标题的布局
        iOSBody
        #endif
    }

    #if os(macOS)
    /// macOS 设置窗口主体：设置标签页 + 最小窗口尺寸约束
    private var macOSBody: some View {
        settingsTabsWithAlerts
        // 设置窗口最小宽度 480pt、最小高度 380pt，防止窗口被缩得太小
        .frame(minWidth: 480, minHeight: 380)
    }
    #endif

    /// iPadOS 设置页主体：设置标签页 + 导航栏标题"设置"
    private var iOSBody: some View {
        settingsTabsWithAlerts
        // 在导航栏显示"设置"标题
        .navigationTitle("设置")
    }

    /// 可用的设置标签列表（当前为通用 + 终端）
    private var availableTabs: [SettingsTab] {
        // 返回枚举的所有 case
        SettingsTab.allCases
    }

    /// 设置标签页容器：只有一个标签时直接显示内容，多个标签时使用 TabView
    private var settingsTabs: some View {
        Group {
            if availableTabs.count == 1 {
                // 仅一个分类时直接展示，不绘制 TabView
                tabContent(for: availableTabs[0])
            } else {
                // 多个标签时使用 TabView（macOS 底部标签栏 / iPadOS 顶部标签栏）
                // selection 绑定到 selectedTab，切换标签时自动更新
                TabView(selection: $selectedTab) {
                    ForEach(availableTabs) { tab in
                        // 每个标签对应的内容视图
                        tabContent(for: tab)
                            .tabItem {
                                // 标签项：图标 + 文字
                                Label(tab.title, systemImage: tab.systemImage)
                            }
                            // 为 TabView 的选中机制提供标签值
                            .tag(tab)
                    }
                }
            }
        }
    }

    /// 设置标签页 + 所有弹窗（对话框）：在标签页基础上附加各种 alert
    private var settingsTabsWithAlerts: some View {
        settingsTabs
            // 导入失败对话框：当 importError 不为 nil 时弹出
            .alert("导入失败", isPresented: .constant(importError != nil)) {
                // 点击确定后清除错误信息
                Button("确定") { importError = nil }
            } message: {
                // 显示错误信息文字
                Text(importError ?? "")
            }
            // 导入成功对话框：当 importSuccess 不为 nil 时弹出
            .alert("导入成功", isPresented: .constant(importSuccess != nil)) {
                // 点击确定后清除成功信息
                Button("确定") { importSuccess = nil }
            } message: {
                Text(importSuccess ?? "")
            }
            // 密码保护操作失败对话框
            .alert("密码保护操作失败", isPresented: .constant(protectionError != nil)) {
                Button("确定") { protectionError = nil }
            } message: {
                Text(protectionError ?? "")
            }
            // 密码保护操作成功对话框
            .alert("操作成功", isPresented: .constant(protectionSuccess != nil)) {
                Button("确定") { protectionSuccess = nil }
            } message: {
                Text(protectionSuccess ?? "")
            }
            // 移除密码保护确认对话框
            .alert("移除密码保护", isPresented: $showRemoveConfirmation) {
                // 确认移除（红色按钮）
                Button("移除", role: .destructive) { performRemoveProtection() }
                // 取消并清空密码输入
                Button("取消", role: .cancel) { currentProtectionKey = "" }
            } message: {
                Text("移除后已保存的密码与私钥口令将以明文存储在本机配置目录。请确认输入当前保护密钥。")
            }
            // 视图首次出现时执行：刷新保护状态 + 初始化缓冲区行数文本
            .onAppear {
                // 从后端获取当前密码保护状态
                refreshProtectionStatus()
                // 读取当前缓冲区行数设置
                bufferLinesText = TerminalSettings.shared.rawBufferLines()
            }
    }

    /// 根据标签类型返回对应的设置内容视图
    @ViewBuilder
    private func tabContent(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            // 通用标签内容
            generalTab
        case .terminal:
            // 终端标签内容
            terminalTab
        }
    }

    // MARK: - 通用标签

    /// 通用标签页内容：包含配置导入/导出、密码保护、关于三个分区
    private var generalTab: some View {
        // Form 是系统风格的表单布局（macOS 为分组列表，iPadOS 为 inset group 样式）
        Form {
            // 配置导入/导出分区
            configSection
            // 密码保护分区
            protectionSection
            // 关于信息分区
            aboutSection
        }
        // 使用分组样式（每个 Section 有圆角背景 + 间距）
        .formStyle(.grouped)
    }

    // MARK: - 终端标签

    /// 终端标签页内容：缓冲区行数设置
    private var terminalTab: some View {
        Form {
            // Section 标题为"缓冲区"
            Section("缓冲区") {
                // 垂直堆叠，左对齐，间距 12pt
                VStack(alignment: .leading, spacing: 12) {
                    // 水平排列：标签 + 弹性空间 + 输入框
                    HStack(spacing: 16) {
                        // 显示"缓冲区高度（行）"标签文字
                        Text(SettingsFormContract.terminalBufferAccessibilityLabel)
                        // 弹性空间，最小 24pt（标签和输入框之间至少 24pt 间距）
                        Spacer(minLength: 24)
                        HStack(spacing: 8) {
                            Button {
                                stepBufferLines(by: -1)
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(SettingsFormContract.terminalBufferDecrementButtonAccessibilityLabel)

                            // 文本输入框，绑定到 bufferLinesText
                            TextField(SettingsFormContract.terminalBufferInputPrompt, text: $bufferLinesText)
                                #if os(iOS)
                                    // iPadOS：弹出数字键盘（只能输入数字）
                                    .keyboardType(.numberPad)
                                #endif
                                    // 圆角边框样式（输入框有圆角矩形边框）
                                    .textFieldStyle(.roundedBorder)
                                    // 文字右对齐（数字靠右显示）
                                    .multilineTextAlignment(.trailing)
                                    // 输入框固定宽度 120pt
                                    .frame(width: 120)
                                    // 无障碍标签
                                    .accessibilityLabel(SettingsFormContract.terminalBufferAccessibilityLabel)
                                    // 用户按回车时保存设置
                                    .onSubmit { saveBufferLines() }
                            Button {
                                stepBufferLines(by: 1)
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(SettingsFormContract.terminalBufferIncrementButtonAccessibilityLabel)
                        }
                        .fixedSize()
                    }
                    // 显示"范围 1000 ～ 100000"提示文字
                    Text(SettingsFormContract.terminalBufferHelperText)
                        // 小号字体
                        .font(.caption)
                        // 灰色文字
                        .foregroundStyle(.secondary)
                        // 占满宽度，右对齐
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        // 文字右对齐
                        .multilineTextAlignment(.trailing)
                    // 水平分割线
                    Divider()
                    // 操作按钮行（右对齐）
                    settingsActionRow {
                        // 保存按钮，点击后保存缓冲区设置
                        Button("保存") { saveBufferLines() }
                    }
                }
                // 垂直内边距 4pt
                .padding(.vertical, 4)
            }
        }
        // 分组样式
        .formStyle(.grouped)
    }

    // MARK: - 配置导入/导出

    /// 配置分区：导出和导入按钮
    private var configSection: some View {
        // Section 标题为"配置"
        Section("配置") {
            // 操作按钮右对齐
            settingsActionRow {
                // 水平排列两个按钮
                HStack {
                    Button("导出配置…") {
                        // 点击导出按钮：调用导出功能
                        exportConfig()
                    }
                    Button("导入配置…") {
                        // 点击导入按钮：显示文件选择器
                        showImportPicker = true
                    }
                    #if os(macOS)
                    // macOS：使用 NSSavePanel 风格的文件选择器（通过 sheet 弹出）
                    .sheet(isPresented: $showImportPicker) {
                        MacImportPicker { result in
                            // 文件选择完成后处理结果
                            handleImportResult(result)
                        }
                    }
                    #else
                    // iPadOS：使用 UIDocumentPicker 文件选择器
                    .sheet(isPresented: $showImportPicker) {
                        IOSImportPicker { result in
                            handleImportResult(result)
                        }
                    }
                    #endif
                }
            }
        }
    }

    // MARK: - 密码保护

    /// 密码保护分区：根据当前保护状态显示不同的表单
    private var protectionSection: some View {
        // Section 标题为"密码保护"
        Section("密码保护") {
            switch protectionState {
            case .unprotected:
                // 未启用保护：显示启用表单
                unprotectedForm
            case .locked:
                // 已锁定：显示解锁表单
                lockedForm
            case .unlocked:
                // 已解锁：显示更换密码/移除保护表单
                unlockedForm
            case .readError(let message):
                // 读取失败：显示错误信息和重试按钮
                readErrorForm(message: message)
            case .processing:
                // 操作中：显示加载指示器
                processingForm
            }
        }
    }

    /// 未启用保护时的表单：警告文字 + 设置新密码的两个输入框 + 启用按钮
    private var unprotectedForm: some View {
        // 垂直堆叠，左对齐，间距 8pt
        VStack(alignment: .leading, spacing: 8) {
            Text("未设置保护密钥时，已保存的密码与私钥口令会以明文存储在本机配置目录。")
                // 小号字体
                .font(.caption)
                // 橙色文字，表示警告
                .foregroundStyle(.orange)
            Text("启用后，所有已保存的 SSH 密码和私钥口令将被加密保护。")
                .font(.caption)
                // 灰色说明文字
                .foregroundStyle(.secondary)
            // 密码输入框（输入内容显示为圆点）
            SecureField("新保护密码", text: $newProtectionKey)
                // 圆角边框
                .textFieldStyle(.roundedBorder)
            // 确认密码输入框
            SecureField("确认保护密码", text: $confirmProtectionKey)
                .textFieldStyle(.roundedBorder)
            // 操作按钮右对齐
            settingsActionRow {
                // 启用按钮
                Button("启用密码保护") { performEnableProtection() }
                    // 密码为空或两次输入不一致时禁用按钮
                    .disabled(newProtectionKey.isEmpty || newProtectionKey != confirmProtectionKey)
            }
        }
    }

    /// 已锁定时的表单：提示文字 + 当前密码输入框 + 解锁按钮
    private var lockedForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("凭据已加密保护。请输入保护密码解锁。")
                .font(.caption)
                .foregroundStyle(.secondary)
            // 密码输入框
            SecureField("当前保护密码", text: $currentProtectionKey)
                .textFieldStyle(.roundedBorder)
            settingsActionRow {
                // 解锁按钮
                Button("解锁") { performUnlock() }
                    // 密码为空时禁用按钮
                    .disabled(currentProtectionKey.isEmpty)
            }
        }
    }

    /// 已解锁时的表单：状态标签 + 更换密码折叠区 + 移除保护折叠区
    private var unlockedForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 锁打开图标 + "已解锁"文字
            Label("已解锁", systemImage: "lock.open.fill")
                // 绿色，表示安全状态
                .foregroundStyle(.green)
                .font(.caption)
            Text("所有已保存的 SSH 密码和私钥口令已受保护。")
                .font(.caption)
                .foregroundStyle(.secondary)

            // 折叠区域：更换保护密码（点击标题可展开/收起）
            DisclosureGroup("更换保护密码") {
                // 当前密码
                SecureField("当前密码", text: $currentProtectionKey)
                    .textFieldStyle(.roundedBorder)
                // 新密码
                SecureField("新密码", text: $newProtectionKey)
                    .textFieldStyle(.roundedBorder)
                // 确认新密码
                SecureField("确认新密码", text: $confirmProtectionKey)
                    .textFieldStyle(.roundedBorder)
                settingsActionRow {
                    // 更换密码按钮
                    Button("更换密码") { performChangeKey() }
                        // 任一字段为空或两次新密码不一致时禁用
                        .disabled(newProtectionKey.isEmpty || newProtectionKey != confirmProtectionKey || currentProtectionKey.isEmpty)
                }
            }

            // 折叠区域：移除保护（isExpanded: .constant(false) 表示默认收起且不可展开，仅作为视觉占位）
            DisclosureGroup("移除保护", isExpanded: .constant(false)) {
                SecureField("当前密码", text: $currentProtectionKey)
                    .textFieldStyle(.roundedBorder)
                settingsActionRow {
                    // 红色按钮，表示危险操作
                    Button("移除保护…", role: .destructive) {
                        // 显示确认对话框
                        showRemoveConfirmation = true
                    }
                    // 未输入密码时禁用
                    .disabled(currentProtectionKey.isEmpty)
                }
            }
        }
    }

    /// 读取保护状态失败时的表单：错误图标 + 错误信息 + 重试按钮
    private func readErrorForm(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 警告三角图标
            Label("读取失败", systemImage: "exclamationmark.triangle")
                // 红色，表示错误
                .foregroundStyle(.red)
                .font(.caption)
            // 错误详情
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            settingsActionRow {
                // 重试按钮：重新读取状态
                Button("重试") { refreshProtectionStatus() }
            }
        }
    }

    /// 操作进行中的表单：加载指示器 + "处理中…"文字
    private var processingForm: some View {
        // 水平排列
        HStack {
            // 系统加载指示器（旋转的菊花 / 进度条）
            ProgressView()
            // 提示文字
            Text("处理中…")
                // 灰色
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 保护操作

    /// 刷新密码保护状态：从后端异步读取当前保护状态并更新 UI
    private func refreshProtectionStatus() {
        // 先显示"处理中"状态
        protectionState = .processing
        // 创建异步任务
        Task {
            do {
                // 在后台线程执行 FFI 调用（避免阻塞主线程）
                let status = try await FFIBackground.run {
                    // 查询当前保护状态
                    try credentialProtectionStatus()
                }
                // 回到主线程更新 UI
                await MainActor.run {
                    switch status {
                    case .unprotected:
                        // 未启用保护
                        protectionState = .unprotected
                    case .protectedLocked:
                        // 已保护但锁定
                        protectionState = .locked
                    case .protectedUnlocked:
                        // 已保护且已解锁
                        protectionState = .unlocked
                    }
                    // 清空密码输入框
                    clearSecretFields()
                }
            } catch {
                // 发生错误时显示错误状态
                await MainActor.run {
                    protectionState = .readError(error.localizedDescription)
                }
            }
        }
    }

    /// 启用密码保护：验证两次输入一致后，调用后端设置新的保护密码
    private func performEnableProtection() {
        // 前置验证：两次密码输入必须一致且不为空
        guard newProtectionKey == confirmProtectionKey, !newProtectionKey.isEmpty else {
            protectionError = "两次输入的密码不一致"
            return
        }
        // 本地副本（避免在 Task 中访问 @State）
        let newKey = newProtectionKey
        // 显示处理中
        protectionState = .processing
        Task {
            do {
                // 调用后端设置保护密码（currentKey 为 nil 表示首次启用，无旧密码）
                try await FFIBackground.run {
                    try PandaCoreBridge.shared.updateCredentialProtectionKey(
                        currentKey: nil, newKey: newKey
                    )
                }
                await MainActor.run {
                    // 启用成功，状态变为已解锁
                    protectionState = .unlocked
                    // 成功提示
                    protectionSuccess = "已保护所有已保存的密码与私钥口令"
                    // 清空密码输入框
                    clearSecretFields()
                }
            } catch {
                await MainActor.run {
                    // 显示错误
                    protectionError = "无法启用密码保护：\(error.localizedDescription)"
                    // 回退到未保护状态
                    protectionState = .unprotected
                    clearSecretFields()
                }
            }
        }
    }

    /// 解锁密码保护：用用户输入的密码尝试解锁已保护的凭据
    private func performUnlock() {
        // 本地副本
        let currentKey = currentProtectionKey
        protectionState = .processing
        Task {
            do {
                // 调用后端尝试解锁
                let status = try await FFIBackground.run {
                    try credentialUnlockOnly(candidateKey: currentKey)
                }
                await MainActor.run {
                    switch status {
                    case .protectedUnlocked:
                        // 解锁成功
                        protectionState = .unlocked
                    default:
                        // 密码错误
                        protectionError = "保护密码不正确"
                        // 保持锁定状态
                        protectionState = .locked
                    }
                    clearSecretFields()
                }
            } catch {
                await MainActor.run {
                    protectionError = "解锁失败：\(error.localizedDescription)"
                    protectionState = .locked
                    clearSecretFields()
                }
            }
        }
    }

    /// 更换保护密码：验证输入后，用旧密码认证并设置新密码
    private func performChangeKey() {
        // 前置验证：当前密码不为空，新密码两次输入一致且不为空
        guard !currentProtectionKey.isEmpty, newProtectionKey == confirmProtectionKey, !newProtectionKey.isEmpty else {
            protectionError = "请完整填写当前密码和新密码"
            return
        }
        let currentKey = currentProtectionKey
        let newKey = newProtectionKey
        protectionState = .processing
        Task {
            do {
                // 调用后端更换密码（需要提供旧密码认证）
                try await FFIBackground.run {
                    try PandaCoreBridge.shared.updateCredentialProtectionKey(
                        currentKey: currentKey, newKey: newKey
                    )
                }
                await MainActor.run {
                    protectionSuccess = "已更换保护密码"
                    clearSecretFields()
                }
            } catch {
                await MainActor.run {
                    protectionError = "更换失败：\(error.localizedDescription)"
                    clearSecretFields()
                }
            }
            // 无论成功失败都刷新状态
            await MainActor.run {
                refreshProtectionStatus()
            }
        }
    }

    /// 移除密码保护：用当前密码认证后，将保护密钥设为 nil（取消加密）
    private func performRemoveProtection() {
        guard !currentProtectionKey.isEmpty else { return }
        let currentKey = currentProtectionKey
        protectionState = .processing
        Task {
            do {
                // 调用后端移除保护（newKey 为 nil 表示移除加密）
                try await FFIBackground.run {
                    try PandaCoreBridge.shared.updateCredentialProtectionKey(
                        currentKey: currentKey, newKey: nil
                    )
                }
                await MainActor.run {
                    // 状态变为未保护
                    protectionState = .unprotected
                    protectionSuccess = "已移除密码保护"
                    clearSecretFields()
                }
            } catch {
                await MainActor.run {
                    protectionError = "移除失败：\(error.localizedDescription)"
                    // 失败时保持已解锁状态
                    protectionState = .unlocked
                    clearSecretFields()
                }
            }
        }
    }

    /// 清空所有密码输入框（操作完成后调用，避免密码残留在界面上）
    private func clearSecretFields() {
        // 清空当前密码
        currentProtectionKey = ""
        // 清空新密码
        newProtectionKey = ""
        // 清空确认密码
        confirmProtectionKey = ""
    }

    // MARK: - 终端缓冲区

    /// 操作按钮行：将内容右对齐（根据 SettingsFormContract 的配置）
    /// 泛型方法，接受任意 View 作为内容
    @ViewBuilder
    private func settingsActionRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        switch SettingsFormContract.explicitActionAlignment {
        case .trailing:
            // 水平排列
            HStack {
                // 弹性空间：将内容推到右边
                Spacer()
                // 传入的按钮内容
                content()
            }
        }
    }

    /// 使用 Rust FFI 校验后，以一个步长调整缓冲区行数。
    private func stepBufferLines(by offset: Int64) {
        let current = (try? validateTerminalBufferLines(raw: bufferLinesText))
            ?? TerminalSettings.shared.bufferLines()
        let candidate = Int64(current) + offset
        guard let validated = try? validateTerminalBufferLines(raw: String(candidate)) else {
            return
        }
        bufferLinesText = String(validated)
    }

    /// 保存终端缓冲区行数设置：验证输入范围后保存到后端
    private func saveBufferLines() {
        do {
            // 尝试保存用户输入的缓冲区行数
            try TerminalSettings.shared.saveBufferLines(raw: bufferLinesText)
            // 保存成功后，用验证后的值更新文本框（可能格式化了输入）
            let validated = try validateTerminalBufferLines(raw: bufferLinesText)
            bufferLinesText = String(validated)
        } catch {
            // 输入无效（不在 1000-100000 范围内）
            protectionError = "请输入 1000–100000 之间的数值"
            // 恢复为之前的有效值
            bufferLinesText = TerminalSettings.shared.rawBufferLines()
        }
    }

    // MARK: - 关于

    /// 关于分区：显示应用版本、开源协议、技术栈信息
    private var aboutSection: some View {
        // Section 标题为"关于"
        Section("关于") {
            // LabeledContent 显示"标签: 值"格式的信息行
            // 版本号
            LabeledContent("版本", value: "Panda SSH 0.1.0 · Rust core v0.1")
            // 开源协议
            LabeledContent("开源协议", value: "Apache-2.0")
            // 技术栈
            LabeledContent("技术栈", value: "Rust（russh / russh-sftp）+ SwiftUI · uniffi 绑定")
        }
    }

    // MARK: - 导出

    /// 导出配置：将当前所有主机配置打包为 .pandassh 文件
    private func exportConfig() {
        #if os(macOS)
        // macOS：使用 NSSavePanel（系统保存文件对话框）
        // 创建保存面板
        let panel = NSSavePanel()
        // 默认文件名
        panel.nameFieldStringValue = "panda-config.pandassh"
        // 允许的文件类型
        panel.allowedContentTypes = [UTType(filenameExtension: "pandassh")!]
        // 用户点击保存 且获得了文件路径
        if panel.runModal() == .OK, let url = panel.url {
            do {
                // 调用后端导出功能
                _ = try configExport(outputPath: url.path)
            } catch {
                // 导出失败时显示错误
                importError = "导出失败: \(error.localizedDescription)"
            }
        }
        #else
        // iPadOS：导出到临时目录，然后通过系统分享面板让用户选择保存位置
        let tempURL = FileManager.default.temporaryDirectory
            // 临时文件路径
            .appendingPathComponent("panda-config.pandassh")
        do {
            // 导出到临时文件
            _ = try configExport(outputPath: tempURL.path)
            // 创建系统分享面板（UIActivityViewController）
            let activity = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            // 获取当前窗口的根视图控制器来弹出分享面板
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.windows.first?.rootViewController {
                // 以动画方式弹出分享面板
                root.present(activity, animated: true)
            }
        } catch {
            importError = "导出失败: \(error.localizedDescription)"
        }
        #endif
    }

    // MARK: - 导入处理

    /// 处理导入文件选择器的结果
    /// - Parameter result: 成功时携带文件数据，失败时携带错误信息
    private func handleImportResult(_ result: Result<Data, Error>) {
        switch result {
        case .success(let data):
            // 将选择的数据写入临时文件
            let tempURL = FileManager.default.temporaryDirectory
                // 用 UUID 确保文件名唯一
                .appendingPathComponent("import-\(UUID().uuidString).pandassh")
            do {
                // 写入临时文件
                try data.write(to: tempURL)
                // 调用后端导入
                let importResult = try configImport(archivePath: tempURL.path)
                // 清理临时文件
                try? FileManager.default.removeItem(at: tempURL)
                // 重新加载数据模型（使导入的配置生效）
                model.reload()
                // 拼接备份文件信息（如果导入时有文件被备份）
                let backupInfo = importResult.backupFiles.isEmpty
                    ? ""
                    : "\n已备份文件: \(importResult.backupFiles.joined(separator: ", "))"
                importSuccess = "配置导入成功。密码/口令未包含在归档中，需重新输入。\(backupInfo)"
            } catch {
                // 出错时也清理临时文件
                try? FileManager.default.removeItem(at: tempURL)
                importError = "导入失败: \(error.localizedDescription)"
            }
        case .failure(let error):
            // 用户取消或文件读取失败
            importError = "选择文件失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - macOS 导入文件选择器

#if os(macOS)
/// macOS 导入文件选择器：使用 NSOpenPanel 让用户选择 .pandassh 配置文件
/// 这是一个技巧：用一个不可见的 1x1 视图，在 onAppear 时弹出系统文件选择对话框
private struct MacImportPicker: View {
    /// 文件选择完成后的回调：成功时携带文件数据，取消或失败时携带错误
    let onComplete: (Result<Data, Error>) -> Void

    var body: some View {
        // 完全透明的视图（用户看不到）
        Color.clear
            // 固定为 1x1 像素（几乎不占空间）
            .frame(width: 1, height: 1)
            .onAppear {
                // 视图出现时立即弹出系统文件选择对话框
                // 创建打开文件面板
                let panel = NSOpenPanel()
                // 不允许选择多个文件
                panel.allowsMultipleSelection = false
                // 不允许选择文件夹
                panel.canChooseDirectories = false
                // 只显示 .pandassh 文件
                panel.allowedContentTypes = [UTType(filenameExtension: "pandassh")!]
                // 用户选择了文件
                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        // 读取文件内容
                        let data = try Data(contentsOf: url)
                        // 回调成功
                        onComplete(.success(data))
                    } catch {
                        // 文件读取失败
                        onComplete(.failure(error))
                    }
                } else {
                    // 用户取消了文件选择
                    onComplete(.failure(NSError(domain: "UserCancelled", code: -1)))
                }
            }
    }
}
#endif

// MARK: - iPadOS 导入文件选择器

#if os(iOS)
/// iPadOS 导入文件选择器：使用 UIDocumentPickerViewController 让用户选择 .pandassh 文件
/// 这是一个 UIViewControllerRepresentable，将 UIKit 的文档选择器桥接到 SwiftUI
private struct IOSImportPicker: UIViewControllerRepresentable {
    /// 文件选择完成后的回调
    let onComplete: (Result<Data, Error>) -> Void

    /// 创建 UIDocumentPickerViewController
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // 创建文档选择器，只接受 .pandassh 类型的文件
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "pandassh")!])
        // 设置代理，处理选择结果
        picker.delegate = context.coordinator
        return picker
    }

    /// 视图更新时无需额外操作
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    /// 创建协调器（代理对象），桥接 UIKit 回调到 SwiftUI
    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    /// 协调器类：实现 UIDocumentPickerDelegate，处理文件选择和取消事件
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        /// 文件选择完成后的回调
        let onComplete: (Result<Data, Error>) -> Void

        init(onComplete: @escaping (Result<Data, Error>) -> Void) {
            self.onComplete = onComplete
        }

        /// 用户选择了文件后调用
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                // 没有选择文件（理论上不会发生）
                onComplete(.failure(NSError(domain: "NoSelection", code: -1)))
                return
            }
            do {
                // 读取文件内容
                let data = try Data(contentsOf: url)
                // 回调成功
                onComplete(.success(data))
            } catch {
                // 文件读取失败
                onComplete(.failure(error))
            }
        }

        /// 用户取消了文件选择后调用
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // 回调取消错误
            onComplete(.failure(NSError(domain: "UserCancelled", code: -1)))
        }
    }
}
#endif

// MARK: - 预览

#if DEBUG
// Xcode Preview：在开发时实时预览设置页面
#Preview("设置") {
    SettingsView()
        // 注入预览用的应用数据模型
        .environmentObject(AppModel.previewModel())
        // 注入预览用的工作区状态
        .environmentObject(WorkspaceStore.previewStore())
}
#endif
