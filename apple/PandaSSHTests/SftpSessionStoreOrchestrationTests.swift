import XCTest
#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// 任务 9.5:SFTP UI 提交路径经核心编排入口,验证任务创建、错误传播与边界行为。
@MainActor
final class SftpSessionStoreOrchestrationTests: XCTestCase {

    // MARK: - 辅助

    private struct TestError: Error {}

    private func makeSession() -> (SftpSessionStore, TransferStore) {
        let host = HostEntry(
            id: "h-orch", name: "orch-host", address: "198.51.100.30", port: 22,
            username: "deploy", groupID: "g-orch", fingerprint: "SHA256:y", demo: nil
        )
        let transfers = TransferStore(failRule: { _ in false }, random: { 0 })
        let session = SftpSessionStore(host: host, transfers: transfers)
        session.useDemoSource()
        return (session, transfers)
    }

    /// 注入扫描与编排 handler,使 upload/download 完全在内存中运行。
    private func injectHandlers(
        session: SftpSessionStore,
        transfers: TransferStore,
        scanItems: [BatchItemRecord],
        direction: TransferDirection
    ) {
        session.scanLocalHandler = { _, _ in scanItems }
        session.scanRemoteHandler = { _, _ in scanItems }
        session.orchestrationHandler = { _, items, dir, hostID, destDir, _, _ in
            var ids: [String] = []
            for item in items {
                let id = transfers.add(
                    direction: dir,
                    name: item.name,
                    size: item.size,
                    source: item.source,
                    destination: item.destination,
                    hostID: hostID
                )
                ids.append(id.uuidString)
            }
            return OrchestrationResultRecord(transferIds: ids, batchIds: [])
        }
    }

    // MARK: - 正常流程

    func testUploadSingleFileViaOrchestration() async {
        let (session, transfers) = makeSession()
        let items = [
            BatchItemRecord(source: DemoFileSystem.localRoot + "/notes.md", destination: "/home/deploy/notes.md", size: 4_096, isDir: false),
        ]
        injectHandlers(session: session, transfers: transfers, scanItems: items, direction: .upload)

        let tasks = await session.upload(localPaths: [DemoFileSystem.localRoot + "/notes.md"])

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.direction, .upload)
        XCTAssertEqual(tasks.first?.name, "notes.md")
        XCTAssertEqual(tasks.first?.size, 4_096)
        XCTAssertEqual(transfers.tasks.count, 1)
    }

    func testUploadMultipleFilesViaOrchestration() async {
        let (session, transfers) = makeSession()
        let items = [
            BatchItemRecord(source: DemoFileSystem.localRoot + "/notes.md", destination: "/home/deploy/notes.md", size: 4_096, isDir: false),
            BatchItemRecord(source: DemoFileSystem.localRoot + "/deploy.tar.gz", destination: "/home/deploy/deploy.tar.gz", size: 18_432_000, isDir: false),
        ]
        injectHandlers(session: session, transfers: transfers, scanItems: items, direction: .upload)

        let tasks = await session.upload(localPaths: [
            DemoFileSystem.localRoot + "/notes.md",
            DemoFileSystem.localRoot + "/deploy.tar.gz",
        ])

        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(transfers.tasks.count, 2)
        XCTAssertTrue(tasks.allSatisfy { $0.direction == .upload })
    }

    func testDownloadViaOrchestration() async {
        let (session, transfers) = makeSession()
        let items = [
            BatchItemRecord(source: "/home/deploy/.bashrc", destination: DemoFileSystem.localRoot + "/.bashrc", size: 3_526, isDir: false),
        ]
        injectHandlers(session: session, transfers: transfers, scanItems: items, direction: .download)

        let tasks = await session.download(remotePaths: ["/home/deploy/.bashrc"])

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.direction, .download)
        XCTAssertEqual(tasks.first?.name, ".bashrc")
        XCTAssertEqual(tasks.first?.size, 3_526)
    }

    func testOrchestrationPassesHostIDAndPasswords() async {
        let (session, transfers) = makeSession()
        session.setConnectionSecrets(password: "pw", passphrase: "pp")
        var capturedHostID: String?
        var capturedPassword: String?
        var capturedPassphrase: String?

        session.scanLocalHandler = { _, _ in
            [BatchItemRecord(source: "/tmp/a", destination: "/remote/a", size: 100, isDir: false)]
        }
        session.orchestrationHandler = { _, items, dir, hostID, destDir, password, passphrase in
            capturedHostID = hostID
            capturedPassword = password
            capturedPassphrase = passphrase
            let id = transfers.add(direction: dir, name: items[0].name, size: items[0].size, source: items[0].source, destination: items[0].destination, hostID: hostID)
            return OrchestrationResultRecord(transferIds: [id.uuidString], batchIds: [])
        }

        _ = await session.upload(localPaths: ["/tmp/a"])

        XCTAssertEqual(capturedHostID, "h-orch")
        XCTAssertEqual(capturedPassword, "pw")
        XCTAssertEqual(capturedPassphrase, "pp")
    }

    // MARK: - 意外流程

    func testOrchestrationErrorReturnsEmpty() async {
        let (session, transfers) = makeSession()
        session.scanLocalHandler = { _, _ in
            [BatchItemRecord(source: "/tmp/x", destination: "/remote/x", size: 10, isDir: false)]
        }
        session.orchestrationHandler = { _, _, _, _, _, _, _ in
            throw TestError()
        }

        let tasks = await session.upload(localPaths: ["/tmp/x"])

        XCTAssertTrue(tasks.isEmpty)
        XCTAssertTrue(transfers.tasks.isEmpty)
    }

    func testOrchestrationEmptyResultReturnsEmpty() async {
        let (session, transfers) = makeSession()
        session.scanLocalHandler = { _, _ in
            [BatchItemRecord(source: "/tmp/x", destination: "/remote/x", size: 10, isDir: false)]
        }
        session.orchestrationHandler = { _, _, _, _, _, _, _ in
            OrchestrationResultRecord(transferIds: [], batchIds: [])
        }

        let tasks = await session.upload(localPaths: ["/tmp/x"])

        XCTAssertTrue(tasks.isEmpty)
        XCTAssertTrue(transfers.tasks.isEmpty)
    }

    // MARK: - 边界条件

    func testEmptyPathsSkipsOrchestration() async {
        let (session, transfers) = makeSession()
        var orchestrationCalled = false
        session.orchestrationHandler = { _, _, _, _, _, _, _ in
            orchestrationCalled = true
            return OrchestrationResultRecord(transferIds: [], batchIds: [])
        }

        let tasks = await session.upload(localPaths: [])

        XCTAssertTrue(tasks.isEmpty)
        XCTAssertFalse(orchestrationCalled)
        XCTAssertTrue(transfers.tasks.isEmpty)
    }

    func testEmptyScanResultSkipsOrchestration() async {
        let (session, transfers) = makeSession()
        session.scanLocalHandler = { _, _ in [] }
        var orchestrationCalled = false
        session.orchestrationHandler = { _, _, _, _, _, _, _ in
            orchestrationCalled = true
            return OrchestrationResultRecord(transferIds: [], batchIds: [])
        }

        let tasks = await session.upload(localPaths: ["/tmp/ghost"])

        XCTAssertTrue(tasks.isEmpty)
        XCTAssertFalse(orchestrationCalled)
    }

    func testTasksPersistAfterOrchestration() async {
        let (session, transfers) = makeSession()
        let items = [
            BatchItemRecord(source: DemoFileSystem.localRoot + "/notes.md", destination: "/home/deploy/notes.md", size: 4_096, isDir: false),
        ]
        injectHandlers(session: session, transfers: transfers, scanItems: items, direction: .upload)

        _ = await session.upload(localPaths: [DemoFileSystem.localRoot + "/notes.md"])

        XCTAssertEqual(transfers.tasks.count, 1)
        XCTAssertEqual(transfers.tasks.first?.status, .running)
    }

    func testDownloadEmptyPathsSkipsOrchestration() async {
        let (session, transfers) = makeSession()
        var orchestrationCalled = false
        session.orchestrationHandler = { _, _, _, _, _, _, _ in
            orchestrationCalled = true
            return OrchestrationResultRecord(transferIds: [], batchIds: [])
        }

        let tasks = await session.download(remotePaths: [])

        XCTAssertTrue(tasks.isEmpty)
        XCTAssertFalse(orchestrationCalled)
        XCTAssertTrue(transfers.tasks.isEmpty)
    }

    func testResolveOrchestratedTasksFiltersCorrectly() async {
        let (session, transfers) = makeSession()
        let id1 = transfers.add(direction: .upload, name: "a", size: 1, source: "/a", destination: "/r/a", hostID: "h")
        let id2 = transfers.add(direction: .upload, name: "b", size: 2, source: "/b", destination: "/r/b", hostID: "h")
        _ = transfers.add(direction: .upload, name: "c", size: 3, source: "/c", destination: "/r/c", hostID: "h")

        let result = OrchestrationResultRecord(transferIds: [id1.uuidString, id2.uuidString], batchIds: [])
        let resolved = session.resolveOrchestratedTasks(result: result, uploadSizes: [:])

        XCTAssertEqual(resolved.count, 2)
        let names = Set(resolved.map { $0.name })
        XCTAssertEqual(names, ["a", "b"])
    }
}
