import SwiftUI
import UniformTypeIdentifiers

/// 设置页标签目录。两个平台必须共享标签、顺序和视觉标识。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case connection
    case terminal
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .appearance: "外观"
        case .connection: "连接"
        case .terminal: "终端"
        case .advanced: "高级"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gear"
        case .appearance: "paintbrush"
        case .connection: "link"
        case .terminal: "terminal"
        case .advanced: "gearshape.2"
        }
    }
}

/// 设置页：macOS 走原生 Settings Scene（cmd+,），iPadOS 走侧栏入口。
/// 两端共享同一组标签和设置内容；仅导航容器与平台服务有所不同。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var importError: String?
    @State private var importSuccess: String?
    @State private var showImportPicker = false
    @State private var currentProtectionKey = ""
    @State private var newProtectionKey = ""
    @State private var credentialProtectionError: String?
    @State private var credentialProtectionEnabled = false
    @State private var selectedTab: SettingsTab = .general
    /// 默认仍读取真实桥接；测试可注入确定值以覆盖两种展示状态。
    private let credentialProtectionEnabledLoader: () -> Bool

    init(
        credentialProtectionEnabledLoader: @escaping () -> Bool = {
            (try? PandaCoreBridge.shared.isCredentialProtectionEnabled()) ?? false
        }
    ) {
        self.credentialProtectionEnabledLoader = credentialProtectionEnabledLoader
    }

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
        .frame(width: 560, height: 420)
    }
    #endif

    private var iOSBody: some View {
        settingsTabsWithAlerts
        .navigationTitle("设置")
    }

    private var settingsTabs: some View {
        TabView(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(tab)
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
            .alert("密码保护操作失败", isPresented: .constant(credentialProtectionError != nil)) {
                Button("确定") { credentialProtectionError = nil }
            } message: {
                Text(credentialProtectionError ?? "")
            }
            .onAppear {
                credentialProtectionEnabled = credentialProtectionEnabledLoader()
            }
    }

    @ViewBuilder
    private func tabContent(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            generalTab
        case .appearance:
            appearanceTab
        case .connection, .terminal, .advanced:
            placeholderTab(title: tab.title, systemImage: tab.systemImage, message: "\(tab.title)设置即将上线")
        }
    }

    // MARK: - 通用标签

    private var generalTab: some View {
        Form {
            configSection
            aboutSection
        }
        .formStyle(.grouped)
    }

    // MARK: - 外观标签

    private var appearanceTab: some View {
        Form {
            Section {
                Picker("页签栏溢出模式", selection: $workspace.tabBarOverflowMode) {
                    ForEach(TabBarOverflowMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                // radioGroup 仅 macOS 可用；iPadOS 用分段控件（纯 UI 差异）。
                #if os(macOS)
                .pickerStyle(.radioGroup)
                #else
                .pickerStyle(.segmented)
                #endif
            } header: {
                Text("页签栏")
            } footer: {
                Text("滚动模式支持鼠标滚轮横向翻页；多行显示模式下页签会自动换行。")
            }
        }
        .formStyle(.grouped)
    }

    private func placeholderTab(title: String, systemImage: String, message: String) -> some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: systemImage)
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 40)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 标签页标签

    // MARK: - 配置导入/导出

    private var configSection: some View {
        Group {
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
            Section("密码保护") {
                if credentialProtectionEnabled {
                    SecureField("当前保护密钥", text: $currentProtectionKey)
                    SecureField("新的保护密钥（留空则只解锁）", text: $newProtectionKey)
                    Text("重启后需在此输入当前保护密钥，才能使用已保存的密码与私钥口令。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("解锁或更新保护") { unlockOrUpdateCredentialProtection() }
                        .disabled(currentProtectionKey.isEmpty)
                    Button("移除密码保护", role: .destructive) { removeCredentialProtection() }
                        .disabled(currentProtectionKey.isEmpty)
                } else {
                    SecureField("密码保护密钥（可选）", text: $newProtectionKey)
                    Text("未设置保护密钥时，已保存的密码与私钥口令会以明文保存在本机配置目录。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("应用密码保护") { enableCredentialProtection() }
                        .disabled(newProtectionKey.isEmpty)
                }
            }
        }
    }

    private func enableCredentialProtection() {
        do {
            try PandaCoreBridge.shared.updateCredentialProtectionKey(currentKey: nil, newKey: newProtectionKey)
            credentialProtectionEnabled = true
            currentProtectionKey = newProtectionKey
            newProtectionKey = ""
        } catch {
            credentialProtectionError = "无法更新密码保护：\(error.localizedDescription)"
            newProtectionKey = ""
        }
    }

    private func unlockOrUpdateCredentialProtection() {
        do {
            let replacement = newProtectionKey.isEmpty ? currentProtectionKey : newProtectionKey
            try PandaCoreBridge.shared.updateCredentialProtectionKey(currentKey: currentProtectionKey, newKey: replacement)
            currentProtectionKey = replacement
            newProtectionKey = ""
        } catch {
            credentialProtectionError = "无法解锁或更新密码保护：\(error.localizedDescription)"
            currentProtectionKey = ""
            newProtectionKey = ""
        }
    }

    private func removeCredentialProtection() {
        do {
            try PandaCoreBridge.shared.updateCredentialProtectionKey(currentKey: currentProtectionKey, newKey: nil)
            credentialProtectionEnabled = false
            currentProtectionKey = ""
            newProtectionKey = ""
        } catch {
            credentialProtectionError = "无法移除密码保护：\(error.localizedDescription)"
            currentProtectionKey = ""
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: "Panda SSH 0.1.0 · Rust core v0.1")
            LabeledContent("开源协议", value: "Apache-2.0")
            LabeledContent("技术栈", value: "Rust（russh / russh-sftp）+ SwiftUI · uniffi 绑定")
        }
    }

    // MARK: - 导出

    private func exportConfig() {
        do {
            let data = try ConfigExporter.export(configDir: AppPaths.configDirectory)
            #if os(macOS)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "panda-config.pandassh"
            panel.allowedContentTypes = [UTType(filenameExtension: "pandassh")!]
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
            }
            #else
            // iPadOS: 写入临时目录并分享
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("panda-config.pandassh")
            try data.write(to: tempURL)
            let activity = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.windows.first?.rootViewController {
                root.present(activity, animated: true)
            }
            #endif
        } catch {
            importError = "导出失败: \(error.localizedDescription)"
        }
    }

    // MARK: - 导入处理

    private func handleImportResult(_ result: Result<Data, Error>) {
        switch result {
        case .success(let data):
            do {
                let importResult = try ConfigImporter.import(pandasshData: data, configDir: AppPaths.configDirectory)
                model.reload()
                let backupInfo = importResult.backedUpFiles.isEmpty
                    ? ""
                    : "\n已备份文件: \(importResult.backedUpFiles.joined(separator: ", "))"
                importSuccess = "配置导入成功。密码/口令未包含在归档中，需重新输入。\(backupInfo)"
            } catch ConfigImporter.ImportError.versionMismatch {
                importError = "配置格式版本过高，请升级 App 后重试。"
            } catch ConfigImporter.ImportError.invalidArchive {
                importError = "配置文件损坏或格式不正确。"
            } catch {
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
