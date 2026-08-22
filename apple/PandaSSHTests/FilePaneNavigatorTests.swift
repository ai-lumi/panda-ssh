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

    // MARK: - 路径导航放宽:任意绝对路径跳转 + 失败回滚(item 7)

    /// 按需抛错的测试数据源:badPaths 中的路径 list 抛错,其余返回占位条目。
    private final class ThrowingOnDemandSource: FilePaneSource {
        let root: String
        let rootTitle: String
        let badPaths: Set<String>
        init(root: String, rootTitle: String, badPaths: Set<String>) {
            self.root = root
            self.rootTitle = rootTitle
            self.badPaths = badPaths
        }
        func list(path: String) async throws -> [FileEntry] {
            if badPaths.contains(path) { throw NSError(domain: "test", code: 1) }
            return [FileEntry(name: "stub", isDirectory: false, size: 0, modified: "")]
        }
    }

    func testNavigateToArbitraryLocalPathSucceedsAndReturnsTrue() async {
        let source = ThrowingOnDemandSource(root: "/local", rootTitle: "本地", badPaths: [])
        let pane = FilePaneNavigator(source: source)
        _ = await pane.reload()

        let ok = await pane.navigate(to: "/local/sub/dir")

        XCTAssertTrue(ok)
        XCTAssertEqual(pane.path, "/local/sub/dir")
        XCTAssertNil(pane.lastError)
    }

    func testNavigateToFailingLocalPathRollsBackAndReturnsFalse() async {
        let source = ThrowingOnDemandSource(root: "/local", rootTitle: "本地", badPaths: ["/local/forbidden"])
        let pane = FilePaneNavigator(source: source)
        _ = await pane.reload()
        let original = pane.path

        let ok = await pane.navigate(to: "/local/forbidden")

        XCTAssertFalse(ok)
        XCTAssertEqual(pane.path, original, "失败时回滚到原路径")
        XCTAssertNotNil(pane.lastError)
    }

    func testNavigateToArbitraryRemotePathSucceedsAndReturnsTrue() async {
        let source = ThrowingOnDemandSource(root: "/home/deploy", rootTitle: "远程", badPaths: [])
        let pane = FilePaneNavigator(source: source)
        _ = await pane.reload()

        let ok = await pane.navigate(to: "/var/log")

        XCTAssertTrue(ok)
        XCTAssertEqual(pane.path, "/var/log")
    }

    func testNavigateToFailingRemotePathRollsBackAndReturnsFalse() async {
        let source = ThrowingOnDemandSource(root: "/home/deploy", rootTitle: "远程", badPaths: ["/root"])
        let pane = FilePaneNavigator(source: source)
        _ = await pane.reload()
        let original = pane.path

        let ok = await pane.navigate(to: "/root")

        XCTAssertFalse(ok)
        XCTAssertEqual(pane.path, original)
        XCTAssertNotNil(pane.lastError)
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

    // MARK: - 后台 home 解析

    /// connect 的 home 解析在后台线程执行：注入 resolver 记录线程，
    /// 断言非主线程、结果用于远程面板根目录。
    func testConnectResolvesHomeDirOffMainThread() async {
        let host = HostEntry(
            id: "h-home", name: "home-host", address: "198.51.100.30", port: 22,
            username: "deploy", groupID: nil, fingerprint: "SHA256:x", demo: nil
        )
        let transfers = TransferStore(failRule: { _ in false }, random: { 0 })
        let session = SftpSessionStore(host: host, transfers: transfers)
        var resolverThreadIsMain: Bool?
        var resolvedHostID: String?
        session.homeDirResolver = { hostID, _, _ in
            resolverThreadIsMain = Thread.isMainThread
            resolvedHostID = hostID
            Thread.sleep(forTimeInterval: 0.3)
            return "/share/homes/deploy"
        }

        await session.connect(password: nil, passphrase: nil)

        XCTAssertEqual(resolverThreadIsMain, false, "home 解析应在非主线程执行")
        XCTAssertEqual(resolvedHostID, "h-home")
        XCTAssertEqual(session.remotePane.root, "/share/homes/deploy", "远程面板根目录应使用解析结果")
    }

    /// home 解析失败回退 `/`（既有语义保持，走后台路径）。
    func testConnectHomeResolveFailureFallsBackToRoot() async {
        let host = HostEntry(
            id: "h-home-fail", name: "home-fail", address: "198.51.100.31", port: 22,
            username: "deploy", groupID: nil, fingerprint: "SHA256:x", demo: nil
        )
        let transfers = TransferStore(failRule: { _ in false }, random: { 0 })
        let session = SftpSessionStore(host: host, transfers: transfers)
        session.homeDirResolver = { _, _, _ in
            throw NSError(domain: "test", code: 1)
        }

        await session.connect(password: nil, passphrase: nil)

        XCTAssertEqual(session.remotePane.root, "/", "解析失败应回退到 /")
    }

    // MARK: - 传输网络操作后台化

    /// 本地目录扫描（scanLocalBatch）在后台线程执行。
    func testScanLocalItemsRunsOffMainThread() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()
        var scanThreadIsMain: Bool?
        session.scanLocalHandler = { _, _ in
            scanThreadIsMain = Thread.isMainThread
            return [BatchItemRecord(source: "/a", destination: "/r/a", size: 1, isDir: false)]
        }
        // 选中目录触发批量扫描路径。
        session.selectLocal("Documents")

        _ = await session.uploadSelected()

        XCTAssertEqual(scanThreadIsMain, false, "本地扫描应在非主线程执行")
    }

    /// 远程目录扫描（scanRemoteBatch）在后台线程执行。
    func testScanRemoteItemsRunsOffMainThread() async {
        let (session, _) = makeSession()
        _ = await session.remotePane.reload()
        var scanThreadIsMain: Bool?
        session.scanRemoteHandler = { _, _ in
            scanThreadIsMain = Thread.isMainThread
            return [BatchItemRecord(source: "/r/a", destination: "/l/a", size: 1, isDir: false)]
        }
        // 选中远程目录触发批量扫描路径。
        session.selectRemote("app")

        _ = await session.downloadSelected()

        XCTAssertEqual(scanThreadIsMain, false, "远程扫描应在非主线程执行")
    }

    /// 远程删除在后台线程执行。
    func testDeleteRemoteRunsOffMainThread() async {
        let (session, _) = makeSession()
        _ = await session.remotePane.reload()
        var deleteThreadIsMain: Bool?
        session.deleteRemoteHandler = { _, _ in
            deleteThreadIsMain = Thread.isMainThread
            return nil
        }

        let result = await session.deleteRemote(name: ".bashrc")

        XCTAssertNil(result)
        XCTAssertEqual(deleteThreadIsMain, false, "远程删除应在非主线程执行")
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

    // MARK: - 双击条目:文件触发传输 / 目录进入(item 6)

    func testDoubleClickLocalFileCreatesSingleUploadTask() async {
        let (session, transfers) = makeSession()
        _ = await session.localPane.reload()
        let fileEntry = session.localPane.entries.first { !$0.isDirectory }!
        let beforeCount = transfers.tasks.count

        await session.doubleClickLocal(entry: fileEntry)

        XCTAssertEqual(transfers.tasks.count - beforeCount, 1, "双击文件恰好创建 1 个上传任务")
        let task = transfers.tasks.last
        XCTAssertEqual(task?.direction, .upload)
    }

    func testDoubleClickRemoteFileCreatesSingleDownloadTask() async {
        let (session, transfers) = makeSession()
        _ = await session.remotePane.reload()
        let fileEntry = session.remotePane.entries.first { !$0.isDirectory }!
        let beforeCount = transfers.tasks.count

        await session.doubleClickRemote(entry: fileEntry)

        XCTAssertEqual(transfers.tasks.count - beforeCount, 1, "双击文件恰好创建 1 个下载任务")
        let task = transfers.tasks.last
        XCTAssertEqual(task?.direction, .download)
    }

    func testDoubleClickLocalDirectoryEntersWithoutTransfer() async {
        let (session, transfers) = makeSession()
        _ = await session.localPane.reload()
        let dirEntry = session.localPane.entries.first { $0.isDirectory }!
        let beforeCount = transfers.tasks.count
        let pathBefore = session.localPath

        await session.doubleClickLocal(entry: dirEntry)

        XCTAssertEqual(transfers.tasks.count, beforeCount, "双击目录不应创建传输任务")
        XCTAssertNotEqual(session.localPath, pathBefore, "双击目录应进入子目录")
    }

    func testDoubleClickRemoteDirectoryEntersWithoutTransfer() async {
        let (session, transfers) = makeSession()
        _ = await session.remotePane.reload()
        let dirEntry = session.remotePane.entries.first { $0.isDirectory }!
        let beforeCount = transfers.tasks.count
        let pathBefore = session.remotePath

        await session.doubleClickRemote(entry: dirEntry)

        XCTAssertEqual(transfers.tasks.count, beforeCount, "双击目录不应创建传输任务")
        XCTAssertNotEqual(session.remotePath, pathBefore, "双击目录应进入子目录")
    }

    // MARK: - 右键菜单 action:多选集合操作 / 未选中置为唯一选中(item 5)

    func testContextUploadOnSelectedEntryUploadsWholeSet() async {
        let (session, transfers) = makeSession()
        _ = await session.localPane.reload()
        session.scanLocalHandler = { paths, destDir in
            paths.map { BatchItemRecord(source: $0, destination: destDir + "/" + ($0 as NSString).lastPathComponent, size: 100, isDir: false) }
        }
        let names = session.localPane.entries.filter { !$0.isDirectory }.prefix(2).map(\.name)
        guard names.count >= 2 else { return XCTFail("演示数据需至少 2 个本地文件") }
        session.isLocalMultiSelect = true
        session.selectedLocalSet = Set(names)
        let entry = session.localPane.entries.first { $0.name == names.first! }!
        let beforeCount = transfers.tasks.count

        await session.contextUpload(entry: entry)

        // action 作用于整个选中集合 → 2 个上传任务
        XCTAssertEqual(transfers.tasks.count - beforeCount, 2)
        XCTAssertTrue(transfers.tasks.allSatisfy { $0.direction == .upload })
        XCTAssertTrue(session.selectedLocalSet == Set(names), "选中集合不变")
    }

    func testContextUploadOnUnselectedEntrySelectsOnlyIt() async {
        let (session, transfers) = makeSession()
        _ = await session.localPane.reload()
        let names = session.localPane.entries.filter { !$0.isDirectory }.prefix(2).map(\.name)
        guard names.count >= 2 else { return XCTFail("演示数据需至少 2 个本地文件") }
        session.isLocalMultiSelect = true
        session.selectedLocalSet = [names[0]]
        let unselectedEntry = session.localPane.entries.first { $0.name == names[1] }!
        let beforeCount = transfers.tasks.count

        await session.contextUpload(entry: unselectedEntry)

        // 右键未选中条目 → 先置为唯一选中 → 上传 1 个
        XCTAssertEqual(session.selectedLocalSet, [names[1]])
        XCTAssertEqual(transfers.tasks.count - beforeCount, 1)
        XCTAssertEqual(transfers.tasks.last?.direction, .upload)
    }

    func testContextDownloadOnSelectedEntryDownloadsWholeSet() async {
        let (session, transfers) = makeSession()
        _ = await session.remotePane.reload()
        session.scanRemoteHandler = { paths, destDir in
            paths.map { BatchItemRecord(source: $0, destination: destDir + "/" + ($0 as NSString).lastPathComponent, size: 100, isDir: false) }
        }
        let names = session.remotePane.entries.filter { !$0.isDirectory }.prefix(2).map(\.name)
        guard names.count >= 2 else { return XCTFail("演示数据需至少 2 个远程文件") }
        session.isRemoteMultiSelect = true
        session.selectedRemoteSet = Set(names)
        let entry = session.remotePane.entries.first { $0.name == names.first! }!
        let beforeCount = transfers.tasks.count

        await session.contextDownload(entry: entry)

        XCTAssertEqual(transfers.tasks.count - beforeCount, 2)
        XCTAssertTrue(transfers.tasks.allSatisfy { $0.direction == .download })
    }

    func testContextDownloadOnUnselectedEntrySelectsOnlyIt() async {
        let (session, transfers) = makeSession()
        _ = await session.remotePane.reload()
        let names = session.remotePane.entries.filter { !$0.isDirectory }.prefix(2).map(\.name)
        guard names.count >= 2 else { return XCTFail("演示数据需至少 2 个远程文件") }
        session.isRemoteMultiSelect = true
        session.selectedRemoteSet = [names[0]]
        let unselectedEntry = session.remotePane.entries.first { $0.name == names[1] }!
        let beforeCount = transfers.tasks.count

        await session.contextDownload(entry: unselectedEntry)

        XCTAssertEqual(session.selectedRemoteSet, [names[1]])
        XCTAssertEqual(transfers.tasks.count - beforeCount, 1)
        XCTAssertEqual(transfers.tasks.last?.direction, .download)
    }

    // MARK: - 右键删除:多选集合操作 / 未选中置为唯一选中(修复:多选删除未处理)

    func testContextDeleteOnSelectedEntryDeletesWholeSet() async {
        let (session, _) = makeSession()
        _ = await session.remotePane.reload()
        var deletedNames: [String] = []
        session.deleteRemoteHandler = { name, _ in
            deletedNames.append(name)
            return nil
        }
        let names = session.remotePane.entries.filter { !$0.isDirectory }.prefix(2).map(\.name)
        guard names.count >= 2 else { return XCTFail("演示数据需至少 2 个远程文件") }
        session.isRemoteMultiSelect = true
        session.selectedRemoteSet = Set(names)
        let entry = session.remotePane.entries.first { $0.name == names.first! }!

        let result = await session.contextDelete(entry: entry, local: false)

        XCTAssertEqual(deletedNames.count, 2, "多选右键删除应作用于整个选中集合")
        XCTAssertEqual(result.deleted, 2)
        XCTAssertTrue(session.selectedRemoteSet == Set(names), "选中集合不变")
    }

    func testContextDeleteOnUnselectedEntrySelectsOnlyIt() async {
        let (session, _) = makeSession()
        _ = await session.remotePane.reload()
        var deletedNames: [String] = []
        session.deleteRemoteHandler = { name, _ in
            deletedNames.append(name)
            return nil
        }
        let names = session.remotePane.entries.filter { !$0.isDirectory }.prefix(2).map(\.name)
        guard names.count >= 2 else { return XCTFail("演示数据需至少 2 个远程文件") }
        session.isRemoteMultiSelect = true
        session.selectedRemoteSet = [names[0]]
        let unselectedEntry = session.remotePane.entries.first { $0.name == names[1] }!

        let result = await session.contextDelete(entry: unselectedEntry, local: false)

        XCTAssertEqual(session.selectedRemoteSet, [names[1]], "右键未选中条目 → 先置为唯一选中")
        XCTAssertEqual(deletedNames.count, 1, "仅删除右键的条目")
        XCTAssertEqual(result.deleted, 1)
    }

    func testContextDeleteSingleSelectDeletesOnlyIt() async {
        let (session, _) = makeSession()
        _ = await session.remotePane.reload()
        var deletedNames: [String] = []
        session.deleteRemoteHandler = { name, _ in
            deletedNames.append(name)
            return nil
        }
        let entry = session.remotePane.entries.first { !$0.isDirectory }!
        session.selectRemote(entry.name)

        let result = await session.contextDelete(entry: entry, local: false)

        XCTAssertEqual(deletedNames, [entry.name])
        XCTAssertEqual(result.deleted, 1)
    }

    // MARK: - Shift 范围选择

    /// 本地条目顺序: Documents, Downloads, deploy.tar.gz, notes.md, id_ed25519.pub

    func testShiftSelectLocalForwardRange() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()
        session.selectLocal("Downloads")

        session.selectLocalRange(from: "Downloads", to: "notes.md")

        XCTAssertEqual(session.selectedLocalSet, ["Downloads", "deploy.tar.gz", "notes.md"])
        XCTAssertTrue(session.isLocalMultiSelect)
        XCTAssertEqual(session.localAnchor, "Downloads")
    }

    func testShiftSelectLocalReverseRange() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()
        session.selectLocal("notes.md")

        session.selectLocalRange(from: "notes.md", to: "Downloads")

        XCTAssertEqual(session.selectedLocalSet, ["Downloads", "deploy.tar.gz", "notes.md"])
        XCTAssertTrue(session.isLocalMultiSelect)
        XCTAssertEqual(session.localAnchor, "notes.md")
    }

    func testCommandShiftAppendLocalRange() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()
        session.selectLocal("Documents")
        session.selectLocal("id_ed25519.pub", append: true)
        XCTAssertEqual(session.selectedLocalSet, ["Documents", "id_ed25519.pub"])

        session.appendLocalRange(from: "Documents", to: "notes.md")

        XCTAssertEqual(session.selectedLocalSet, ["Documents", "Downloads", "deploy.tar.gz", "notes.md", "id_ed25519.pub"])
        XCTAssertTrue(session.isLocalMultiSelect)
    }

    func testShiftSelectWithoutAnchorFallsBackToSingle() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()
        XCTAssertNil(session.localAnchor)

        session.selectLocalRange(from: session.localAnchor ?? "", to: "notes.md")

        XCTAssertEqual(session.selectedLocalSet, ["notes.md"])
        XCTAssertEqual(session.localAnchor, "notes.md")
        XCTAssertTrue(session.isLocalMultiSelect)
    }

    func testShiftSelectWithMissingAnchorFallsBackToSingle() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()
        session.localAnchor = "no-longer-here"

        session.selectLocalRange(from: "no-longer-here", to: "notes.md")

        XCTAssertEqual(session.selectedLocalSet, ["notes.md"])
        XCTAssertEqual(session.localAnchor, "notes.md")
    }

    func testEnterDirectoryClearsAnchor() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()
        session.selectLocal("Documents")
        XCTAssertNotNil(session.localAnchor)

        await session.enterLocal("Documents")

        XCTAssertNil(session.localAnchor)
        XCTAssertTrue(session.selectedLocalSet.isEmpty)
    }

    func testShiftSelectSameAnchorAndTarget() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()
        session.selectLocal("deploy.tar.gz")

        session.selectLocalRange(from: "deploy.tar.gz", to: "deploy.tar.gz")

        XCTAssertEqual(session.selectedLocalSet, ["deploy.tar.gz"])
        XCTAssertTrue(session.isLocalMultiSelect)
    }

    func testExistingCommandClickAndDragBehaviorUnchanged() async {
        let (session, _) = makeSession()
        _ = await session.localPane.reload()

        // ⌘+单击等价于 append=true，应追加并更新 anchor
        session.selectLocal("Documents")
        session.selectLocal("Downloads", append: true)

        XCTAssertEqual(session.selectedLocalSet, ["Documents", "Downloads"])
        XCTAssertEqual(session.localAnchor, "Downloads")
    }

    func testRemoteShiftSelectRange() async {
        let (session, _) = makeSession()
        _ = await session.remotePane.reload()
        // 远程根目录顺序: app, logs, .bashrc, backup-...
        session.selectRemote("app")

        session.selectRemoteRange(from: "app", to: ".bashrc")

        XCTAssertEqual(session.selectedRemoteSet, ["app", "logs", ".bashrc"])
        XCTAssertTrue(session.isRemoteMultiSelect)
        XCTAssertEqual(session.remoteAnchor, "app")
    }
}
