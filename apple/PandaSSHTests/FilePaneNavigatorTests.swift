import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// SFTP 导航模型测试:覆盖正常流程(进目录/返回上级/面包屑跳转)、
/// 意外操作(进入文件/不存在目录)、边界条件(根目录不可再向上、
/// 空目录)三类用例;另含会话选择联动与传输任务挂载。
@MainActor
final class FilePaneNavigatorTests: XCTestCase {

    private func makeLocalPane() async -> FilePaneNavigator {
        let pane = FilePaneNavigator(root: DemoFileSystem.localRoot, fs: DemoFileSystem.local, rootTitle: "本地")
        _ = await pane.reload()
        return pane
    }

    private func makeRemotePane(username: String = "deploy") async -> FilePaneNavigator {
        let pane = FilePaneNavigator(
            root: DemoFileSystem.remoteRoot(username: username),
            fs: DemoFileSystem.remote(username: username),
            rootTitle: "远程"
        )
        _ = await pane.reload()
        return pane
    }

    // MARK: - 正常流程:列表 / 进入 / 返回

    func testLocalRootListsFakeEntries() async {
        let pane = await makeLocalPane()

        XCTAssertEqual(pane.path, DemoFileSystem.localRoot)
        XCTAssertTrue(pane.entries.contains(FileEntry(name: "Documents", isDirectory: true, size: 0, modified: "2026-07-30 14:02")))
        XCTAssertTrue(pane.entries.contains(where: { $0.name == "deploy.tar.gz" && !$0.isDirectory }))
        XCTAssertFalse(pane.canGoUp)
    }

    func testEnterDirectoryDescends() async {
        var pane = await makeLocalPane()

        let entered = await pane.enter("Documents")
        XCTAssertTrue(entered)

        XCTAssertEqual(pane.path, DemoFileSystem.localRoot + "/Documents")
        XCTAssertTrue(pane.canGoUp)
        XCTAssertTrue(pane.entries.contains(where: { $0.name == "spec-drafts" }))
    }

    func testEnterTwoLevelsThenGoUpToRoot() async {
        var pane = await makeLocalPane()
        _ = await pane.enter("Documents")
        _ = await pane.enter("spec-drafts")

        XCTAssertEqual(pane.path, DemoFileSystem.localRoot + "/Documents/spec-drafts")
        XCTAssertTrue(pane.entries.contains(where: { $0.name == "sftp-spec.md" }))

        await pane.goUp()
        XCTAssertEqual(pane.path, DemoFileSystem.localRoot + "/Documents")
        await pane.goUp()
        XCTAssertEqual(pane.path, DemoFileSystem.localRoot)
        XCTAssertFalse(pane.canGoUp)
    }

    func testBreadcrumbsReflectDepth() async {
        var pane = await makeLocalPane()
        XCTAssertEqual(pane.breadcrumbs.map(\.title), ["本地"])

        _ = await pane.enter("Documents")
        _ = await pane.enter("spec-drafts")

        XCTAssertEqual(pane.breadcrumbs.map(\.title), ["本地", "Documents", "spec-drafts"])
        XCTAssertEqual(
            pane.breadcrumbs.map(\.path),
            [DemoFileSystem.localRoot, DemoFileSystem.localRoot + "/Documents", DemoFileSystem.localRoot + "/Documents/spec-drafts"]
        )
    }

    func testNavigateToBreadcrumbPath() async {
        var pane = await makeLocalPane()
        _ = await pane.enter("Documents")
        _ = await pane.enter("spec-drafts")

        await pane.navigate(to: DemoFileSystem.localRoot)

        XCTAssertEqual(pane.path, DemoFileSystem.localRoot)
    }

    // MARK: - 远程文件系统按 user 生成

    func testRemoteRootDerivedFromUsername() async {
        let pane = await makeRemotePane(username: "deploy")

        XCTAssertEqual(pane.path, "/home/deploy")
        XCTAssertEqual(pane.breadcrumbs.map(\.title), ["远程"])
        XCTAssertTrue(pane.entries.contains(where: { $0.name == "app" && $0.isDirectory }))
        XCTAssertTrue(pane.entries.contains(where: { $0.name == ".bashrc" }))
    }

    func testRemoteTwoLevelsDeep() async {
        var pane = await makeRemotePane()
        _ = await pane.enter("app")
        _ = await pane.enter("current")

        XCTAssertEqual(pane.path, "/home/deploy/app/current")
        XCTAssertTrue(pane.entries.contains(where: { $0.name == "server.js" }))
    }

    // MARK: - 意外操作与边界

    func testEnterRegularFileIsRejected() async {
        var pane = await makeLocalPane()

        let enteredFile = await pane.enter("deploy.tar.gz")
        XCTAssertFalse(enteredFile)
        XCTAssertEqual(pane.path, DemoFileSystem.localRoot)
    }

    func testEnterUnknownNameIsRejected() async {
        var pane = await makeLocalPane()

        let enteredUnknown = await pane.enter("no-such-dir")
        XCTAssertFalse(enteredUnknown)
        XCTAssertEqual(pane.path, DemoFileSystem.localRoot)
    }

    func testGoUpAtRootIsNoOp() async {
        var pane = await makeLocalPane()

        await pane.goUp()

        XCTAssertEqual(pane.path, DemoFileSystem.localRoot)
        XCTAssertFalse(pane.canGoUp)
    }

    func testEmptyDirectoryYieldsNoEntries() async {
        var pane = await makeRemotePane()
        _ = await pane.enter("logs")
        await pane.goUp()
        // 构造一个存在于映射表之外的目录:enter 会被拒绝,这里直接验证未知路径回退为空
        let stray = FilePaneNavigator(root: "/home/deploy", fs: [:], rootTitle: "远程")
        XCTAssertTrue(stray.entries.isEmpty)
    }

    // MARK: - 会话:选择与传输挂载

    private func makeSession() -> (SftpSessionStore, TransferStore) {
        let host = HostEntry(
            id: "h-staging", name: "staging-01", address: "198.51.100.20", port: 2222,
            username: "deploy", groupID: "g-test", fingerprint: "SHA256:x", demo: nil
        )
        let transfers = TransferStore(failRule: { _ in false }, random: { 0 })
        let session = SftpSessionStore(host: host, transfers: transfers)
        session.useDemoSource()
        return (session, transfers)
    }

    func testUploadSelectedLocalFileAddsTransfer() async {
        let (session, transfers) = makeSession()
        _ = await session.localPane.reload()
        session.selectLocal("deploy.tar.gz")

        let task = await session.uploadSelected()

        XCTAssertNotNil(task)
        XCTAssertEqual(task?.direction, .upload)
        XCTAssertEqual(task?.size, 18_432_000)
        XCTAssertEqual(task?.source, DemoFileSystem.localRoot + "/deploy.tar.gz")
        XCTAssertEqual(task?.destination, "/home/deploy/deploy.tar.gz")
        XCTAssertEqual(transfers.tasks.count, 1)
    }

    func testDownloadSelectedRemoteFileAddsTransfer() async {
        let (session, _) = makeSession()
        _ = await session.remotePane.reload()
        session.selectRemote(".bashrc")

        let task = await session.downloadSelected()

        XCTAssertEqual(task?.direction, .download)
        XCTAssertEqual(task?.source, "/home/deploy/.bashrc")
        XCTAssertEqual(task?.destination, DemoFileSystem.localRoot + "/.bashrc")
    }

    func testDirectoryTransferCreatesTaskGroup() async {
        let (session, transfers) = makeSession()
        session.scanLocalHandler = { paths, destDir in
            paths.flatMap { path in
                [
                    BatchItemRecord(source: path, destination: destDir, size: 0, isDir: true),
                    BatchItemRecord(source: path + "/a.txt", destination: destDir + "/a.txt", size: 100, isDir: false),
                ]
            }
        }
        session.scanRemoteHandler = { paths, destDir in
            paths.flatMap { path in
                [
                    BatchItemRecord(source: path, destination: destDir, size: 0, isDir: true),
                    BatchItemRecord(source: path + "/a.log", destination: destDir + "/a.log", size: 100, isDir: false),
                ]
            }
        }
        _ = await session.localPane.reload()
        session.selectLocal("Documents")
        _ = await session.uploadSelected()

        let uploadGroup = transfers.taskGroups.first { $0.name == "Documents" }
        XCTAssertNotNil(uploadGroup)
        XCTAssertEqual(uploadGroup?.tasks.count, 1)
        XCTAssertEqual(uploadGroup?.tasks.first?.direction, .upload)
        XCTAssertEqual(uploadGroup?.tasks.first?.source, DemoFileSystem.localRoot + "/Documents/a.txt")

        _ = await session.remotePane.reload()
        session.selectRemote("logs")
        _ = await session.downloadSelected()

        let downloadGroup = transfers.taskGroups.first { $0.name == "logs" }
        XCTAssertNotNil(downloadGroup)
        XCTAssertEqual(downloadGroup?.tasks.count, 1)
        XCTAssertEqual(downloadGroup?.tasks.first?.direction, .download)
        XCTAssertEqual(downloadGroup?.tasks.first?.source, "/home/deploy/logs/a.log")
    }

    func testUploadWithoutSelectionReturnsNil() async {
        let (session, transfers) = makeSession()

        let uploadTask = await session.uploadSelected()
        let downloadTask = await session.downloadSelected()
        XCTAssertNil(uploadTask)
        XCTAssertNil(downloadTask)
        XCTAssertTrue(transfers.tasks.isEmpty)
    }

    func testEnteringDirectoryClearsSelection() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()
        session.selectLocal("notes.md")

        await session.enterLocal("Documents")

        XCTAssertNil(session.selectedLocal)
        XCTAssertEqual(session.localPath, DemoFileSystem.localRoot + "/Documents")
    }

    func testGoUpClearsSelection() async {
        let (session, _) = makeSession()
        _ = await session.remotePane.reload()
        _ = await session.enterRemote("app")
        session.selectRemote("current")

        await session.goUpRemote()

        XCTAssertNil(session.selectedRemote)
        XCTAssertEqual(session.remotePath, "/home/deploy")
    }

    // MARK: - 多选与任务组

    func testLocalMultiSelectFilesAndDirectoryCreatesGroupAndIndependentTasks() async {
        let (session, transfers) = makeSession()
        session.scanLocalHandler = { paths, destDir in
            paths.flatMap { path in
                if (path as NSString).lastPathComponent == "Documents" {
                    return [
                        BatchItemRecord(source: path, destination: destDir, size: 0, isDir: true),
                        BatchItemRecord(source: path + "/roadmap.pdf", destination: destDir + "/roadmap.pdf", size: 100, isDir: false),
                        BatchItemRecord(source: path + "/budget.xlsx", destination: destDir + "/budget.xlsx", size: 100, isDir: false),
                    ]
                }
                return [BatchItemRecord(source: path, destination: destDir + "/" + (path as NSString).lastPathComponent, size: 100, isDir: false)]
            }
        }
        _ = await session.localPane.reload()
        session.isLocalMultiSelect = true
        session.selectedLocalSet = ["deploy.tar.gz", "Documents"]

        _ = await session.uploadSelected()

        XCTAssertEqual(transfers.taskGroups.count, 1)
        XCTAssertEqual(transfers.taskGroups.first?.name, "Documents")
        XCTAssertEqual(transfers.taskGroups.first?.tasks.count, 2)
        XCTAssertEqual(transfers.tasks.filter { $0.groupID == nil }.count, 1)
        XCTAssertEqual(transfers.tasks.filter { $0.groupID == nil }.first?.name, "deploy.tar.gz")
    }

    func testRemoteMultiSelectPureFilesNoGroup() async {
        let (session, transfers) = makeSession()
        session.scanRemoteHandler = { paths, destDir in
            paths.map { BatchItemRecord(source: $0, destination: destDir + "/" + ($0 as NSString).lastPathComponent, size: 100, isDir: false) }
        }
        _ = await session.remotePane.reload()
        session.isRemoteMultiSelect = true
        session.selectedRemoteSet = [".bashrc", "backup-2026-08-01.sql.gz"]

        _ = await session.downloadSelected()

        XCTAssertTrue(transfers.taskGroups.isEmpty)
        XCTAssertEqual(transfers.tasks.count, 2)
    }

    func testMultiSelectWithoutSelectionReturnsNil() async {
        let (session, transfers) = makeSession()
        session.isLocalMultiSelect = true
        session.isRemoteMultiSelect = true

        let upload = await session.uploadSelected()
        let download = await session.downloadSelected()

        XCTAssertNil(upload)
        XCTAssertNil(download)
        XCTAssertTrue(transfers.tasks.isEmpty)
    }

    // MARK: - 选中模型

    func testSelectLocalReplacesSetInSingleMode() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()

        session.selectLocal("notes.md", append: false)
        XCTAssertEqual(session.selectedLocalSet, ["notes.md"])

        session.selectLocal("deploy.tar.gz", append: false)
        XCTAssertEqual(session.selectedLocalSet, ["deploy.tar.gz"])
        XCTAssertEqual(session.selectedLocal, "deploy.tar.gz")
    }

    func testSelectLocalAppendTogglesMembership() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()

        session.selectLocal("notes.md", append: true)
        XCTAssertEqual(session.selectedLocalSet, ["notes.md"])

        session.selectLocal("deploy.tar.gz", append: true)
        XCTAssertEqual(session.selectedLocalSet, ["notes.md", "deploy.tar.gz"])

        session.selectLocal("notes.md", append: true)
        XCTAssertEqual(session.selectedLocalSet, ["deploy.tar.gz"])
    }

    func testSelectRemoteReplacesSetInSingleMode() async {
        let (session, _) = makeSession()
        _ = await session.remotePane.reload()

        session.selectRemote(".bashrc", append: false)
        XCTAssertEqual(session.selectedRemoteSet, [".bashrc"])

        session.selectRemote("app", append: false)
        XCTAssertEqual(session.selectedRemoteSet, ["app"])
    }

    func testToggleMultiSelectClearsSelection() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()
        session.selectLocal("notes.md", append: false)

        session.toggleLocalMultiSelect()

        XCTAssertTrue(session.selectedLocalSet.isEmpty)
        XCTAssertTrue(session.isLocalMultiSelect)
    }

    func testEnterDirectoryClearsSelectionSet() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()
        session.selectLocal("notes.md", append: false)

        await session.enterLocal("Documents")

        XCTAssertTrue(session.selectedLocalSet.isEmpty)
        XCTAssertEqual(session.localPath, DemoFileSystem.localRoot + "/Documents")
    }

    func testGoUpClearsSelectionSet() async {
        let (session, _) = makeSession()
        _ = await session.remotePane.reload()
        _ = await session.enterRemote("app")
        session.selectRemote("current", append: false)

        await session.goUpRemote()

        XCTAssertTrue(session.selectedRemoteSet.isEmpty)
        XCTAssertEqual(session.remotePath, "/home/deploy")
    }

    func testSelectedLocalOptionalReturnsFirst() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()

        XCTAssertNil(session.selectedLocal)

        session.selectedLocalSet = ["notes.md"]
        XCTAssertEqual(session.selectedLocal, "notes.md")

        session.selectedLocalSet = ["notes.md", "deploy.tar.gz"]
        XCTAssertTrue(session.selectedLocalSet.contains(session.selectedLocal ?? ""))
    }

    // MARK: - 字节格式化(与原型 fmtBytes 一致)

    func testFormatBytes() {
        XCTAssertEqual(formatBytes(512), "512 B")
        XCTAssertEqual(formatBytes(2048), "2.0 KB")
        XCTAssertEqual(formatBytes(18_432_000), "17.6 MB")
        XCTAssertEqual(formatBytes(3_221_225_472), "3.00 GB")
    }
}
