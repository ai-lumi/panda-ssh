import SwiftUI

/// 设置页:macOS 走原生 Settings Scene(cmd+,),iPadOS 走侧栏入口 + sheet。
/// 内容用原生 Form + .formStyle(.grouped),不再手绘卡片。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var toast: ToastCenter

    var body: some View {
        Form {
            Section {
                Toggle("iCloud 同步", isOn: iCloudBinding)
                LabeledContent("片段存储目录") {
                    Text("规划中").foregroundStyle(.secondary)
                }
            } header: {
                Text("同步")
            } footer: {
                Text("通过 iCloud Key-Value Storage 同步主机配置与代码片段")
            }
            Section("关于") {
                LabeledContent("版本", value: "Panda SSH 0.1.0 · Rust core v0.1")
                LabeledContent("开源协议", value: "Apache-2.0")
                LabeledContent("技术栈", value: "Rust（russh / russh-sftp）+ SwiftUI · uniffi 绑定")
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle("设置")
        #endif
    }

    /// iCloud 开关联动(纯演示,不落盘)
    private var iCloudBinding: Binding<Bool> {
        Binding(
            get: { model.iCloudSyncEnabled },
            set: { newValue in
                model.iCloudSyncEnabled = newValue
                toast.show(newValue ? "iCloud 同步已开启" : "iCloud 同步已暂停")
            }
        )
    }
}

#if DEBUG
#Preview("设置") {
    SettingsView()
        .environmentObject(AppModel.previewModel())
        .environmentObject(ToastCenter())
}
#endif
