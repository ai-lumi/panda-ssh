import SwiftUI

/// 状态栏(窗口底部,与原型一致):左侧 iCloud 同步状态(点击切换,纯演示),
/// 中间主机数,右侧版本信息。
struct StatusBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var toast: ToastCenter

    var body: some View {
        HStack(spacing: 14) {
            syncButton
            Spacer()
            Text("\(model.hosts.count) 台主机")
            Spacer()
            Text("Rust core v0.1 · 原型演示")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color.cardBackground)
    }

    /// iCloud 同步状态:绿点「已同步」⇄ 灰点「同步已暂停」,与设置页开关联动。
    private var syncButton: some View {
        Button {
            model.iCloudSyncEnabled.toggle()
            toast.show(model.iCloudSyncEnabled ? "iCloud 同步已恢复" : "同步已暂停")
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.iCloudSyncEnabled ? Color.green : Color.gray.opacity(0.6))
                    .frame(width: 7, height: 7)
                Image(systemName: "icloud")
                Text(model.iCloudSyncEnabled ? "iCloud 已同步" : "同步已暂停")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("状态栏") {
    StatusBarView()
        .environmentObject(AppModel.previewModel())
        .environmentObject(ToastCenter())
}
#endif
