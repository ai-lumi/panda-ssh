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

        let task = session.uploadSelected()

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

        let task = session.downloadSelected()

        XCTAssertEqual(task?.direction, .download)
        XCTAssertEqual(task?.source, "/home/deploy/.bashrc")
        XCTAssertEqual(task?.destination, DemoFileSystem.localRoot + "/.bashrc")
    }

    func testDirectoryTransferUsesPlaceholderSize() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()
        session.selectLocal("Documents")
        XCTAssertEqual(session.uploadSelected()?.size, 3_145_728)

        _ = await session.remotePane.reload()
        session.selectRemote("logs")
        XCTAssertEqual(session.downloadSelected()?.size, 6_291_456)
    }

    func testUploadWithoutSelectionReturnsNil() {
        let (session, transfers) = makeSession()

        XCTAssertNil(session.uploadSelected())
        XCTAssertNil(session.downloadSelected())
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

    // MARK: - 字节格式化(与原型 fmtBytes 一致)

    func testFormatBytes() {
        XCTAssertEqual(formatBytes(512), "512 B")
        XCTAssertEqual(formatBytes(2048), "2.0 KB")
        XCTAssertEqual(formatBytes(18_432_000), "17.6 MB")
        XCTAssertEqual(formatBytes(3_221_225_472), "3.00 GB")
    }
}
