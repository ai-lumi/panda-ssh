import SwiftUI
import UniformTypeIdentifiers

/// 设置页标签目录。仅展示已实现功能的分类。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case terminal

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .terminal: "终端"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gear"
        case .terminal: "terminal"
        }
    }
}

/// 凭据保护的可信展示状态。
enum ProtectionDisplayState: Equatable {
    /// 未启用保护。
    case unprotected
    /// 已启用但锁定（重启后未解锁）。
    case locked
    /// 已启用且已解锁。
    case unlocked
    /// 读取失败。
    case readError(String)
    /// 操作中。
    case processing
}

/// 设置页：macOS 走原生 Settings Scene（cmd+,），iPadOS 走侧栏入口。
/// 两端共享同一组标签和设置内容；仅导航容器与平台服务有所不同。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importError: String?
    @State private var importSuccess: String?
    @State private var showImportPicker = false

    // 密码保护表单状态
    @State private var protectionState: ProtectionDisplayState = .unprotected
    @State private var currentProtectionKey = ""
    @State private var newProtectionKey = ""
    @State private var confirmProtectionKey = ""
    @State private var protectionError: String?
    @State private var protectionSuccess: String?
    @State private var showRemoveConfirmation = false

    // 终端缓冲区设置
    @State private var bufferLinesText = ""

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        settingsTabsWithAlerts
        .frame(minWidth: 480, minHeight: 380)
    }
    #endif

    private var iOSBody: some View {
        settingsTabsWithAlerts
        .navigationTitle("设置")
    }

    private var availableTabs: [SettingsTab] {
        SettingsTab.allCases
    }

    private var settingsTabs: some View {
        Group {
            if availableTabs.count == 1 {
                // 仅一个分类时直接展示，不绘制 TabView
                tabContent(for: availableTabs[0])
            } else {
                TabView(selection: $selectedTab) {
                    ForEach(availableTabs) { tab in
                        tabContent(for: tab)
                            .tabItem {
                                Label(tab.title, systemImage: tab.systemImage)
                            }
                            .tag(tab)
                    }
                }
            }
        }
    }

    private var settingsTabsWithAlerts: some View {
        settingsTabs
            .alert("导入失败", isPresented: .constant(importError != nil)) {
                Button("确定") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .alert("导入成功", isPresented: .constant(importSuccess != nil)) {
                Button("确定") { importSuccess = nil }
            } message: {
                Text(importSuccess ?? "")
            }
            .alert("密码保护操作失败", isPresented: .constant(protectionError != nil)) {
                Button("确定") { protectionError = nil }
            } message: {
                Text(protectionError ?? "")
            }
            .alert("操作成功", isPresented: .constant(protectionSuccess != nil)) {
                Button("确定") { protectionSuccess = nil }
            } message: {
                Text(protectionSuccess ?? "")
            }
            .alert("移除密码保护", isPresented: $showRemoveConfirmation) {
                Button("移除", role: .destructive) { performRemoveProtection() }
                Button("取消", role: .cancel) { currentProtectionKey = "" }
            } message: {
                Text("移除后已保存的密码与私钥口令将以明文存储在本机配置目录。请确认输入当前保护密钥。")
            }
            .onAppear {
                refreshProtectionStatus()
                bufferLinesText = TerminalSettings.shared.rawBufferLines()
            }
    }

    @ViewBuilder
    private func tabContent(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            generalTab
        case .terminal:
            terminalTab
        }
    }

    // MARK: - 通用标签

    private var generalTab: some View {
        Form {
            configSection
            protectionSection
            aboutSection
        }
        .formStyle(.grouped)
    }

    // MARK: - 终端标签

    private var terminalTab: some View {
        Form {
            Section("缓冲区") {
                LabeledContent("回滚行数") {
                    TextField("1000–100000", text: $bufferLinesText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .onSubmit { saveBufferLines() }
                }
                Text("范围 1000–100000，仅对新打开的终端标签生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("保存") { saveBufferLines() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 配置导入/导出

    private var configSection: some View {
        Section("配置") {
            Button("导出配置…") {
                exportConfig()
            }
            Button("导入配置…") {
                showImportPicker = true
            }
            #if os(macOS)
            .sheet(isPresented: $showImportPicker) {
                MacImportPicker { result in
                    handleImportResult(result)
                }
            }
            #else
            .sheet(isPresented: $showImportPicker) {
                IOSImportPicker { result in
                    handleImportResult(result)
                }
            }
            #endif
        }
    }

    // MARK: - 密码保护

    private var protectionSection: some View {
        Section("密码保护") {
            switch protectionState {
            case .unprotected:
                unprotectedForm
            case .locked:
                lockedForm
            case .unlocked:
                unlockedForm
            case .readError(let message):
                readErrorForm(message: message)
            case .processing:
                processingForm
            }
        }
    }

    private var unprotectedForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("未设置保护密钥时，已保存的密码与私钥口令会以明文存储在本机配置目录。")
                .font(.caption)
                .foregroundStyle(.orange)
            Text("启用后，所有已保存的 SSH 密码和私钥口令将被加密保护。")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("新保护密码", text: $newProtectionKey)
                .textFieldStyle(.roundedBorder)
            SecureField("确认保护密码", text: $confirmProtectionKey)
                .textFieldStyle(.roundedBorder)
            Button("启用密码保护") { performEnableProtection() }
                .disabled(newProtectionKey.isEmpty || newProtectionKey != confirmProtectionKey)
        }
    }

    private var lockedForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("凭据已加密保护。请输入保护密码解锁。")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("当前保护密码", text: $currentProtectionKey)
                .textFieldStyle(.roundedBorder)
            Button("解锁") { performUnlock() }
                .disabled(currentProtectionKey.isEmpty)
        }
    }

    private var unlockedForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("已解锁", systemImage: "lock.open.fill")
                .foregroundStyle(.green)
                .font(.caption)
            Text("所有已保存的 SSH 密码和私钥口令已受保护。")
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup("更换保护密码") {
                SecureField("当前密码", text: $currentProtectionKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("新密码", text: $newProtectionKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("确认新密码", text: $confirmProtectionKey)
                    .textFieldStyle(.roundedBorder)
                Button("更换密码") { performChangeKey() }
                    .disabled(newProtectionKey.isEmpty || newProtectionKey != confirmProtectionKey || currentProtectionKey.isEmpty)
            }

            DisclosureGroup("移除保护", isExpanded: .constant(false)) {
                SecureField("当前密码", text: $currentProtectionKey)
                    .textFieldStyle(.roundedBorder)
                Button("移除保护…", role: .destructive) {
                    showRemoveConfirmation = true
                }
                .disabled(currentProtectionKey.isEmpty)
            }
        }
    }

    private func readErrorForm(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("读取失败", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("重试") { refreshProtectionStatus() }
        }
    }

    private var processingForm: some View {
        HStack {
            ProgressView()
            Text("处理中…")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 保护操作

    private func refreshProtectionStatus() {
        protectionState = .processing
        Task {
            do {
                let status = try await FFIBackground.run {
                    try credentialProtectionStatus()
                }
                await MainActor.run {
                    switch status {
                    case .unprotected:
                        protectionState = .unprotected
                    case .protectedLocked:
                        protectionState = .locked
                    case .protectedUnlocked:
                        protectionState = .unlocked
                    }
                    clearSecretFields()
                }
            } catch {
                await MainActor.run {
                    protectionState = .readError(error.localizedDescription)
                }
            }
        }
    }

    private func performEnableProtection() {
        guard newProtectionKey == confirmProtectionKey, !newProtectionKey.isEmpty else {
            protectionError = "两次输入的密码不一致"
            return
        }
        let newKey = newProtectionKey
        protectionState = .processing
        Task {
            do {
                try await FFIBackground.run {
                    try PandaCoreBridge.shared.updateCredentialProtectionKey(
                        currentKey: nil, newKey: newKey
                    )
                }
                await MainActor.run {
                    protectionState = .unlocked
                    protectionSuccess = "已保护所有已保存的密码与私钥口令"
                    clearSecretFields()
                }
            } catch {
                await MainActor.run {
                    protectionError = "无法启用密码保护：\(error.localizedDescription)"
                    protectionState = .unprotected
                    clearSecretFields()
                }
            }
        }
    }

    private func performUnlock() {
        let currentKey = currentProtectionKey
        protectionState = .processing
        Task {
            do {
                let status = try await FFIBackground.run {
                    try credentialUnlockOnly(candidateKey: currentKey)
                }
                await MainActor.run {
                    switch status {
                    case .protectedUnlocked:
                        protectionState = .unlocked
                    default:
                        protectionError = "保护密码不正确"
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

    private func performChangeKey() {
        guard !currentProtectionKey.isEmpty, newProtectionKey == confirmProtectionKey, !newProtectionKey.isEmpty else {
            protectionError = "请完整填写当前密码和新密码"
            return
        }
        let currentKey = currentProtectionKey
        let newKey = newProtectionKey
        protectionState = .processing
        Task {
            do {
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
            await MainActor.run {
                refreshProtectionStatus()
            }
        }
    }

    private func performRemoveProtection() {
        guard !currentProtectionKey.isEmpty else { return }
        let currentKey = currentProtectionKey
        protectionState = .processing
        Task {
            do {
                try await FFIBackground.run {
                    try PandaCoreBridge.shared.updateCredentialProtectionKey(
                        currentKey: currentKey, newKey: nil
                    )
                }
                await MainActor.run {
                    protectionState = .unprotected
                    protectionSuccess = "已移除密码保护"
                    clearSecretFields()
                }
            } catch {
                await MainActor.run {
                    protectionError = "移除失败：\(error.localizedDescription)"
                    protectionState = .unlocked
                    clearSecretFields()
                }
            }
        }
    }

    private func clearSecretFields() {
        currentProtectionKey = ""
        newProtectionKey = ""
        confirmProtectionKey = ""
    }

    // MARK: - 终端缓冲区

    private func saveBufferLines() {
        do {
            try TerminalSettings.shared.saveBufferLines(raw: bufferLinesText)
            let validated = try validateTerminalBufferLines(raw: bufferLinesText)
            bufferLinesText = String(validated)
        } catch {
            protectionError = "请输入 1000–100000 之间的数值"
            bufferLinesText = TerminalSettings.shared.rawBufferLines()
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: "Panda SSH 0.1.0 · Rust core v0.1")
            LabeledContent("开源协议", value: "Apache-2.0")
            LabeledContent("技术栈", value: "Rust（russh / russh-sftp）+ SwiftUI · uniffi 绑定")
        }
    }

    // MARK: - 导出

    private func exportConfig() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "panda-config.pandassh"
        panel.allowedContentTypes = [UTType(filenameExtension: "pandassh")!]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                _ = try configExport(outputPath: url.path)
            } catch {
                importError = "导出失败: \(error.localizedDescription)"
            }
        }
        #else
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("panda-config.pandassh")
        do {
            _ = try configExport(outputPath: tempURL.path)
            let activity = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.windows.first?.rootViewController {
                root.present(activity, animated: true)
            }
        } catch {
            importError = "导出失败: \(error.localizedDescription)"
        }
        #endif
    }

    // MARK: - 导入处理

    private func handleImportResult(_ result: Result<Data, Error>) {
        switch result {
        case .success(let data):
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).pandassh")
            do {
                try data.write(to: tempURL)
                let importResult = try configImport(archivePath: tempURL.path)
                try? FileManager.default.removeItem(at: tempURL)
                model.reload()
                let backupInfo = importResult.backupFiles.isEmpty
                    ? ""
                    : "\n已备份文件: \(importResult.backupFiles.joined(separator: ", "))"
                importSuccess = "配置导入成功。密码/口令未包含在归档中，需重新输入。\(backupInfo)"
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                importError = "导入失败: \(error.localizedDescription)"
            }
        case .failure(let error):
            importError = "选择文件失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - macOS 导入文件选择器

#if os(macOS)
private struct MacImportPicker: View {
    let onComplete: (Result<Data, Error>) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.allowedContentTypes = [UTType(filenameExtension: "pandassh")!]
                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        let data = try Data(contentsOf: url)
                        onComplete(.success(data))
                    } catch {
                        onComplete(.failure(error))
                    }
                } else {
                    onComplete(.failure(NSError(domain: "UserCancelled", code: -1)))
                }
            }
    }
}
#endif

// MARK: - iPadOS 导入文件选择器

#if os(iOS)
private struct IOSImportPicker: UIViewControllerRepresentable {
    let onComplete: (Result<Data, Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "pandassh")!])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: (Result<Data, Error>) -> Void

        init(onComplete: @escaping (Result<Data, Error>) -> Void) {
            self.onComplete = onComplete
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onComplete(.failure(NSError(domain: "NoSelection", code: -1)))
                return
            }
            do {
                let data = try Data(contentsOf: url)
                onComplete(.success(data))
            } catch {
                onComplete(.failure(error))
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onComplete(.failure(NSError(domain: "UserCancelled", code: -1)))
        }
    }
}
#endif

#if DEBUG
#Preview("设置") {
    SettingsView()
        .environmentObject(AppModel.previewModel())
        .environmentObject(WorkspaceStore.previewStore())
}
#endif
