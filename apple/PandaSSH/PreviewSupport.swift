#if DEBUG
import SwiftUI

/// Xcode 画布(Previews)专用支持:直接使用 Mock 后端的演示数据,
/// 不触碰 Rust store、外部存储与钥匙串。仅在 DEBUG 编译,不会进入 Release 包。

extension AppModel {
    /// 预览专用实例:Mock 后端 + 原型演示数据,预选中 web-prod。
    static func previewModel() -> AppModel {
        let model = AppModel(backend: MockBackend.demo())
        model.selectedHostID = "h-webprod"
        return model
    }
}

extension WorkspaceStore {
    /// 预览专用实例:预置几个标签(含同主机多标签,展示序号消歧)。
    static func previewStore() -> WorkspaceStore {
        let store = WorkspaceStore { hostID in
            MockBackend.demo().allHosts().first(where: { $0.id == hostID })?.name
        }
        store.openTerminal(hostID: "h-webprod")
        store.openTerminal(hostID: "h-webprod")
        store.openSFTP(hostID: "h-staging")
        return store
    }
}
#endif
