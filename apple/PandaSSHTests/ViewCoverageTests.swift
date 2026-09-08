import XCTest
import SwiftUI

#if os(macOS)
@testable import PandaSSH_macOS

/// 视图覆盖测试以真实 AppKit 宿主装配可测试的 UI 状态。
/// 不触发系统文件面板、钥匙串或网络，只使用 MockBackend 和注入的内存数据。
@MainActor
final class ViewCoverageTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    func test传输页面覆盖空列表上传下载和终态任务() {
        let emptyStore = TransferStore(failRule: { _ in false })
        install(TransferPageView(store: emptyStore).environmentObject(AppModel.previewModel()))

        let store = TransferStore(failRule: { _ in false }, random: { 0 })
        let upload = store.add(
            direction: .upload, name: "upload.txt", size: 1_000,
            source: "/local/upload.txt", destination: "/remote/upload.txt", hostID: "h-webprod"
        )
        let download = store.add(
            direction: .download, name: "download.txt", size: 1_000,
            source: "/remote/download.txt", destination: "/local/download.txt", hostID: "missing-host"
        )
        store.pause(id: upload)
        store.cancel(id: download)
        install(TransferPageView(store: store).environmentObject(AppModel.previewModel()))

        XCTAssertEqual(store.tasks.count, 2)
        XCTAssertEqual(store.tasks.first { $0.id == upload }?.status, .paused)
        XCTAssertEqual(store.tasks.first { $0.id == download }?.status, .cancelled)
    }

    func test连接监控页面覆盖空记录与多状态快照() {
        let empty = ConnectionMonitorStore(snapshotLoader: { [] }, healthChecker: { _ in .healthy })
        install(ConnectionMonitorView(store: empty))

        let records = [
            telemetry(id: 2, transport: .failed, ssh: .failed, health: .unavailable),
            telemetry(id: 1, transport: .active, ssh: .authenticated, health: .healthy)
        ]
        let populated = ConnectionMonitorStore(snapshotLoader: { records }, healthChecker: { _ in .healthy })
        install(ConnectionMonitorView(store: populated))
        waitFor { !populated.records.isEmpty }

        XCTAssertEqual(populated.records.map(\.id), [1, 2])
    }

    func test日志页面覆盖空状态和各级别条目() {
        let empty = Logger(configDirectory: nil)
        install(LogView(logger: empty))

        let logger = Logger(configDirectory: nil)
        logger.debug("debug", module: "test")
        logger.info("info", module: "test")
        logger.warning("warning", module: "test")
        logger.error("error", module: "test")
        install(LogView(logger: logger))

        XCTAssertEqual(logger.entries.count, 4)
    }

    func test片段主机编辑和安全提示页可装配() {
        let model = AppModel.previewModel()
        let toast = ToastCenter()
        install(SnippetsView().environmentObject(model).environmentObject(toast))

        let host = try! XCTUnwrap(model.hosts.first)
        install(HostEditView(host: nil, defaultGroupID: host.groupID).environmentObject(model))
        install(HostEditView(host: host).environmentObject(model))
        install(HostEditView(copySource: host).environmentObject(model))

        install(FingerprintBox(label: "SHA256", fingerprint: "fingerprint", isBad: false))
        install(FingerprintBox(label: "SHA256", fingerprint: "fingerprint", isBad: true))
        install(TofuConfirmSheet(host: host, fingerprint: "fingerprint"))
        install(HostKeyMismatchSheet(host: host, recordedFingerprint: "old", presentedFingerprint: "new"))
        install(PasswordPromptSheet(host: host))
        install(KeyPickerSheet(host: host))
        install(GroupNameSheet(title: "新建分组", message: "说明", initial: "初始值"))
        install(SnippetEditSheet(snippet: nil))
        install(SnippetEditSheet(snippet: model.snippets.first))

        XCTAssertFalse(model.hosts.isEmpty)
    }

    func test设置页覆盖密码保护开启与关闭状态() {
        let model = AppModel.previewModel()
        let workspace = WorkspaceStore.previewStore()

        install(SettingsView(credentialProtectionEnabledLoader: { false })
            .environmentObject(model)
            .environmentObject(workspace))
        install(SettingsView(credentialProtectionEnabledLoader: { true })
            .environmentObject(model)
            .environmentObject(workspace))

        XCTAssertEqual(workspace.tabBarOverflowMode, .scroll)
    }

    func testSFTP覆盖连接成功与离线失败状态() throws {
        let model = AppModel.previewModel()
        let workspace = WorkspaceStore(hostNameProvider: { id in
            model.hosts.first { $0.id == id }?.name
        })
        let transfers = TransferStore(failRule: { _ in false })
        let toast = ToastCenter()
        let goodHost = try XCTUnwrap(model.hosts.first { $0.id == "h-webprod" })
        let offlineHost = try XCTUnwrap(model.hosts.first { $0.id == "h-offline" })

        for host in [goodHost, offlineHost] {
            let tabID = workspace.openSFTP(hostID: host.id)
            let tab = try XCTUnwrap(workspace.tabs.first { $0.id == tabID })
            install(
                SftpTabView(tab: tab, host: host, transfers: transfers)
                    .environmentObject(model)
                    .environmentObject(workspace)
                    .environmentObject(transfers)
                    .environmentObject(toast),
                settle: 0.95
            )
        }

        XCTAssertEqual(workspace.connectionStatus(forHostID: goodHost.id), .connected)
        XCTAssertEqual(workspace.connectionStatus(forHostID: offlineHost.id), .failed)
    }

    private func install<V: View>(_ view: V, settle: TimeInterval = 0.03) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_024, height: 768),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        windows.append(window)
    }

    private func waitFor(_ predicate: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func telemetry(
        id: UInt64,
        transport: ConnectionStateEnum,
        ssh: SshConnectionStateEnum,
        health: HealthStateEnum
    ) -> ConnectionTelemetryRecord {
        ConnectionTelemetryRecord(
            id: id, hostId: "h", address: "example.com:22",
            ownerKind: "test", ownerId: "test", createdAtMs: 0,
            lastActivityAtMs: 0, transportState: transport, sshState: ssh,
            healthState: health, lastHealthCheckAtMs: nil, receivedBytes: 1,
            sentBytes: 2, receiveBytesPerSecond: 3, sendBytesPerSecond: 4,
            lastError: nil, channels: []
        )
    }
}
#endif
