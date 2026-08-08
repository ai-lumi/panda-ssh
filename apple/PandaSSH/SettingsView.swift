import SwiftUI

/// 设置页:iCloud 同步开关(与状态栏联动)、片段存储目录(模拟选择)、关于信息。
/// 布局与原型 renderSettings 一致;当前所有设置仅保存在会话中(演示)。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var toast: ToastCenter
    @State private var showDirPicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.title3).bold()
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    settingsCard
                    aboutCard
                    Text("此页面为交互原型演示，所有设置仅保存在当前页面会话中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
                .frame(maxWidth: 640)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showDirPicker) {
            MockFilePickerSheet { _ in
                toast.show("目录已更新（模拟）")
            }
        }
    }

    /// 同步与片段存储设置
    private var settingsCard: some View {
        VStack(spacing: 0) {
            SettingsRow(
                title: "iCloud 同步",
                subtitle: "通过 iCloud Key-Value Storage 同步主机配置与代码片段"
            ) {
                Toggle("", isOn: iCloudBinding)
                    .labelsHidden()
            }
            Divider()
            SettingsRow(
                title: "片段存储目录",
                subtitle: "代码片段在本地库中的存储位置（规划中）"
            ) {
                Button("选择…") { showDirPicker = true }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// iCloud 开关与状态栏联动(纯演示,不落盘)
    private var iCloudBinding: Binding<Bool> {
        Binding(
            get: { model.iCloudSyncEnabled },
            set: { newValue in
                model.iCloudSyncEnabled = newValue
                toast.show(newValue ? "iCloud 同步已开启" : "iCloud 同步已暂停")
            }
        )
    }

    /// 关于信息
    private var aboutCard: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "版本", subtitle: "Panda SSH 0.1.0 · Rust core v0.1") { EmptyView() }
            Divider()
            SettingsRow(title: "开源协议", subtitle: "Apache-2.0") { EmptyView() }
            Divider()
            SettingsRow(title: "技术栈", subtitle: "Rust（russh / russh-sftp）+ SwiftUI · uniffi 绑定") { EmptyView() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 设置卡片行:标题 + 副标题 + 右侧控件。
private struct SettingsRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
        .padding(.vertical, 10)
    }
}

#if DEBUG
#Preview("设置") {
    SettingsView()
        .environmentObject(AppModel.previewModel())
        .environmentObject(ToastCenter())
}
#endif
