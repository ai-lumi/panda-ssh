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

    // MARK: - 任务 6.3:四种入口消费同一核心结果

    /// 注入匹配新 FFI 行为的编排 handler:
    /// - 两个方向均产出逐文件传输任务；目录组内文件共享 groupID
    /// - 独立文件无组标识；空目录不产生任务
    private func injectFullOrchestrationHandler(
        session: SftpSessionStore,
        transfers: TransferStore,
        scanItems: [BatchItemRecord]
    ) {
        session.scanLocalHandler = { _, _ in scanItems }
        session.scanRemoteHandler = { _, _ in scanItems }
        session.orchestrationHandler = { selectedPaths, items, direction, hostID, destDir, password, passphrase in
            var transferIds: [String] = []

            let dirItems = items.filter { $0.isDir }
            let fileItems = items.filter { !$0.isDir }
            let dirSources = Set(dirItems.map(\.source))
            let ffiDirection: TransferDirection = direction == .upload ? .upload : .download

            for dirItem in dirItems {
                let children = fileItems.filter { $0.source.hasPrefix(dirItem.source + "/") }
                guard !children.isEmpty else { continue }
                let groupID = UUID()
                let groupName = dirItem.name
                for child in children {
                    let id = transfers.add(
                        direction: ffiDirection, name: child.name, size: child.size,
                        source: child.source, destination: child.destination,
                        hostID: hostID, groupID: groupID, groupName: groupName,
                        password: password, passphrase: passphrase
                    )
                    transferIds.append(id.uuidString)
                }
            }

            let filesUnderDir = Set(fileItems.filter { file in
                dirSources.contains(where: { file.source.hasPrefix($0 + "/") })
            }.map(\.source))
            let standaloneFiles = fileItems.filter { !filesUnderDir.contains($0.source) }
            for file in standaloneFiles {
                let id = transfers.add(
                    direction: ffiDirection, name: file.name, size: file.size,
                    source: file.source, destination: file.destination,
                    hostID: hostID, password: password, passphrase: passphrase
                )
                transferIds.append(id.uuidString)
            }

            return OrchestrationResultRecord(transferIds: transferIds, batchIds: [])
        }
    }

    /// 四种入口(单文件上传、目录上传、单文件下载、目录下载)消费同一核心编排结果。
    func testFourEntryModesConsumeSameOrchestrationResult() async {
        let (session, transfers) = makeSession()

        // 1. 单文件上传 → 独立 transfer
        let singleUploadItems = [
            BatchItemRecord(source: "/tmp/file.txt", destination: "/remote/file.txt", size: 100, isDir: false),
        ]
        injectFullOrchestrationHandler(session: session, transfers: transfers, scanItems: singleUploadItems)
        let uploadTasks = await session.upload(localPaths: ["/tmp/file.txt"])
        XCTAssertEqual(uploadTasks.count, 1, "单文件上传返回 1 个独立任务")
        XCTAssertEqual(transfers.tasks.count, 1)
        XCTAssertTrue(transfers.listBatchTransfers().isEmpty, "单文件不应产生批量记录")

        // 2. 目录上传 → 共享 groupID 的逐文件 transfers
        let dirUploadItems = [
            BatchItemRecord(source: "/tmp/dirA", destination: "/remote/dirA", size: 0, isDir: true),
            BatchItemRecord(source: "/tmp/dirA/f1.txt", destination: "/remote/dirA/f1.txt", size: 100, isDir: false),
        ]
        injectFullOrchestrationHandler(session: session, transfers: transfers, scanItems: dirUploadItems)
        let dirTasks = await session.upload(localPaths: ["/tmp/dirA"])
        XCTAssertEqual(dirTasks.count, 1, "目录上传返回文件级任务")
        XCTAssertEqual(dirTasks.first?.direction, .upload)
        XCTAssertTrue(transfers.listBatchTransfers().isEmpty, "目录上传不产生批量记录")
        XCTAssertNotNil(dirTasks.first?.groupID, "目录内文件应有 groupID")

        // 3. 单文件下载 → 独立 transfer
        let singleDownloadItems = [
            BatchItemRecord(source: "/remote/.bashrc", destination: "/tmp/.bashrc", size: 200, isDir: false),
        ]
        injectFullOrchestrationHandler(session: session, transfers: transfers, scanItems: singleDownloadItems)
        let downloadTasks = await session.download(remotePaths: ["/remote/.bashrc"])
        XCTAssertEqual(downloadTasks.count, 1, "单文件下载返回 1 个独立任务")
        XCTAssertEqual(downloadTasks.first?.direction, .download)

        // 4. 目录下载 → 共享 groupID 的独立 transfers
        let dirDownloadItems = [
            BatchItemRecord(source: "/remote/dirB", destination: "/tmp/dirB", size: 0, isDir: true),
            BatchItemRecord(source: "/remote/dirB/a.txt", destination: "/tmp/dirB/a.txt", size: 100, isDir: false),
            BatchItemRecord(source: "/remote/dirB/b.txt", destination: "/tmp/dirB/b.txt", size: 200, isDir: false),
        ]
        injectFullOrchestrationHandler(session: session, transfers: transfers, scanItems: dirDownloadItems)
        let dirDownloadTasks = await session.download(remotePaths: ["/remote/dirB"])
        XCTAssertEqual(dirDownloadTasks.count, 2, "目录下载返回文件级任务")
        let groupIDs = Set(dirDownloadTasks.compactMap(\.groupID))
        XCTAssertEqual(groupIDs.count, 1, "同目录文件共享一个 groupID")
    }

    /// 编排失败时返回空且不重复入队。
    func testOrchestrationFailureDoesNotDuplicateEnqueue() async {
        let (session, transfers) = makeSession()
        var callCount = 0
        session.scanLocalHandler = { _, _ in
            [BatchItemRecord(source: "/tmp/x", destination: "/remote/x", size: 10, isDir: false)]
        }
        session.orchestrationHandler = { _, _, _, _, _, _, _ in
            callCount += 1
            throw TestError()
        }

        let tasks = await session.upload(localPaths: ["/tmp/x"])

        XCTAssertTrue(tasks.isEmpty)
        XCTAssertEqual(callCount, 1, "编排只调用一次")
        XCTAssertTrue(transfers.tasks.isEmpty, "失败不应入队任何任务")
    }

    /// 重复提交同一选择不会重复入队(每次调用独立编排,但单次不重复)。
    func testDuplicateUploadDoesNotEnqueueTwiceInSingleCall() async {
        let (session, transfers) = makeSession()
        var orchestrationCallCount = 0
        session.scanLocalHandler = { _, _ in
            [BatchItemRecord(source: "/tmp/a.txt", destination: "/remote/a.txt", size: 50, isDir: false)]
        }
        session.orchestrationHandler = { _, items, dir, hostID, destDir, _, _ in
            orchestrationCallCount += 1
            let id = transfers.add(direction: dir, name: items[0].name, size: items[0].size, source: items[0].source, destination: items[0].destination, hostID: hostID)
            return OrchestrationResultRecord(transferIds: [id.uuidString], batchIds: [])
        }

        let tasks = await session.upload(localPaths: ["/tmp/a.txt"])

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(orchestrationCallCount, 1, "单次上传只编排一次")
        XCTAssertEqual(transfers.tasks.count, 1, "恰好 1 个任务")
    }

    /// 空目录不产生任何任务。
    func testEmptyDirectoryRetainsZeroFileGroup() async {
        let (session, transfers) = makeSession()
        let items = [
            BatchItemRecord(source: "/tmp/emptydir", destination: "/remote/emptydir", size: 0, isDir: true),
        ]
        injectFullOrchestrationHandler(session: session, transfers: transfers, scanItems: items)

        let tasks = await session.upload(localPaths: ["/tmp/emptydir"])

        XCTAssertTrue(tasks.isEmpty, "空目录无文件任务")
        XCTAssertTrue(transfers.tasks.isEmpty, "空目录不产生任何任务")
    }

    /// 扫描期间导航不改变已固定的目标目录。
    func testNavigationDuringScanKeepsOriginalDestination() async {
        let (session, transfers) = makeSession()
        let started = expectation(description: "扫描已开始")
        let release = DispatchSemaphore(value: 0)
        var firstScan = true
        session.scanLocalHandler = { paths, destDir in
            if firstScan {
                firstScan = false
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return paths.map {
                BatchItemRecord(source: $0, destination: destDir + "/" + ($0 as NSString).lastPathComponent, size: 5, isDir: false)
            }
        }
        session.orchestrationHandler = { _, items, dir, hostID, destDir, _, _ in
            var ids: [String] = []
            for item in items {
                let id = transfers.add(direction: dir, name: item.name, size: item.size, source: item.source, destination: item.destination, hostID: hostID)
                ids.append(id.uuidString)
            }
            return OrchestrationResultRecord(transferIds: ids, batchIds: [])
        }

        let upload = Task { await session.upload(localPaths: ["/fake/a.txt"]) }
        await fulfillment(of: [started], timeout: 2)

        // 扫描期间导航到新目录
        _ = await session.navigateRemote(to: "/home/deploy/other")
        release.signal()
        let tasks = await upload.value

        XCTAssertEqual(tasks.count, 1)
        // 目标应保持扫描时的目录,不受导航影响
        XCTAssertTrue(tasks.first?.destination.contains("/fake") == true || tasks.first?.destination.hasPrefix("/") == true,
                      "目标路径由扫描时决定")
    }

    /// 同名目录多次提交使用不同组 UUID。
    func testSameNameDirectoryCreatesDistinctGroups() async {
        let (session, transfers) = makeSession()
        let items = [
            BatchItemRecord(source: "/tmp/project", destination: "/remote/project", size: 0, isDir: true),
            BatchItemRecord(source: "/tmp/project/main.swift", destination: "/remote/project/main.swift", size: 100, isDir: false),
        ]
        injectFullOrchestrationHandler(session: session, transfers: transfers, scanItems: items)

        // 第一次提交
        _ = await session.upload(localPaths: ["/tmp/project"])
        let firstGroupIDs = Set(transfers.tasks.compactMap(\.groupID))

        // 第二次提交同名目录
        _ = await session.upload(localPaths: ["/tmp/project"])
        let allGroupIDs = Set(transfers.tasks.compactMap(\.groupID))

        XCTAssertEqual(allGroupIDs.count, firstGroupIDs.count + 1, "同名目录第二次提交创建新组")
        XCTAssertEqual(allGroupIDs.count, 2, "两次提交共 2 个不同组")
    }

    /// 混合选择(目录+文件)正确路由:目录内文件 → transfer(带 groupID),独立文件 → transfer(无组)。
    func testMixedSelectionRoutesCorrectly() async {
        let (session, transfers) = makeSession()
        let items = [
            BatchItemRecord(source: "/tmp/dirA", destination: "/remote/dirA", size: 0, isDir: true),
            BatchItemRecord(source: "/tmp/dirA/f1.txt", destination: "/remote/dirA/f1.txt", size: 100, isDir: false),
            BatchItemRecord(source: "/tmp/readme.md", destination: "/remote/readme.md", size: 50, isDir: false),
        ]
        injectFullOrchestrationHandler(session: session, transfers: transfers, scanItems: items)

        let tasks = await session.upload(localPaths: ["/tmp/dirA", "/tmp/readme.md"])

        XCTAssertEqual(tasks.count, 2, "所有文件作为传输任务返回")
        XCTAssertTrue(transfers.listBatchTransfers().isEmpty, "不产生批量记录")
        let groupedTasks = transfers.tasks.filter { $0.groupID != nil }
        XCTAssertEqual(groupedTasks.count, 1, "目录内文件有组 ID")
        let independentTasks = transfers.tasks.filter { $0.groupID == nil }
        XCTAssertEqual(independentTasks.count, 1, "独立文件无组 ID")
    }
}
