import XCTest

#if os(macOS)
@testable import PandaSSH_macOS
#else
@testable import PandaSSH_iOS
#endif

/// ConfigSync 测试:覆盖快照编解码、push/pull、last-write-wins 冲突、
/// key_path 本机保留、回环抑制、快照不含密钥材料等场景。
@MainActor
final class ConfigSyncTests: XCTestCase {

    private var kv: FakeConfigKVStore!
    private var dir: URL!
    private var sync: ConfigSync!

    override func setUp() {
        super.setUp()
        kv = FakeConfigKVStore()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sync = ConfigSync(
            kv: kv,
            hostsURL: dir.appendingPathComponent("hosts.toml"),
            groupsURL: dir.appendingPathComponent("groups.toml")
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - 正常流程

    func testPushThenPullReturnsSameSnapshot() throws {
        try makeLocalHosts().write(to: sync.hostsURL, atomically: true, encoding: .utf8)
        try makeLocalGroups().write(to: sync.groupsURL, atomically: true, encoding: .utf8)

        sync.push()
        let pulled = sync.pullSnapshot()

        XCTAssertNotNil(pulled)
        XCTAssertEqual(pulled?.hosts, makeLocalHosts())
        XCTAssertEqual(pulled?.groups, makeLocalGroups())
        XCTAssertEqual(pulled?.version, ConfigSnapshot.currentVersion)
    }

    func testApplyRemoteSnapshotOverwritesLocalFiles() throws {
        try makeLocalHosts().write(to: sync.hostsURL, atomically: true, encoding: .utf8)
        try makeLocalGroups().write(to: sync.groupsURL, atomically: true, encoding: .utf8)

        let remote = ConfigSnapshot(
            version: ConfigSnapshot.currentVersion,
            updatedAt: Date().timeIntervalSince1970 + 10,
            hosts: makeRemoteHosts(),
            groups: makeRemoteGroups()
        )
        XCTAssertTrue(sync.apply(snapshot: remote))

        let localHosts = try String(contentsOf: sync.hostsURL, encoding: .utf8)
        let localGroups = try String(contentsOf: sync.groupsURL, encoding: .utf8)
        XCTAssertEqual(localHosts, makeRemoteHosts())
        XCTAssertEqual(localGroups, makeRemoteGroups())
    }

    // MARK: - 冲突:last-write-wins

    func testOlderRemoteSnapshotIsRejected() throws {
        try makeLocalHosts().write(to: sync.hostsURL, atomically: true, encoding: .utf8)
        try Thread.sleep(forTimeInterval: 0.01)

        let remote = ConfigSnapshot(
            version: ConfigSnapshot.currentVersion,
            updatedAt: Date().timeIntervalSince1970 - 10,
            hosts: makeRemoteHosts(),
            groups: makeRemoteGroups()
        )
        XCTAssertFalse(sync.apply(snapshot: remote))

        let localHosts = try String(contentsOf: sync.hostsURL, encoding: .utf8)
        XCTAssertEqual(localHosts, makeLocalHosts())
    }

    func testEqualTimestampKeepsLocal() throws {
        let now = Date().timeIntervalSince1970
        try makeLocalHosts().write(to: sync.hostsURL, atomically: true, encoding: .utf8)

        let remote = ConfigSnapshot(
            version: ConfigSnapshot.currentVersion,
            updatedAt: now,
            hosts: makeRemoteHosts(),
            groups: makeRemoteGroups()
        )
        XCTAssertFalse(sync.apply(snapshot: remote))
    }

    // MARK: - key_path 保留

    func testApplyRemotePreservesLocalKeyPath() throws {
        let local = """
        [[host]]
        id = "h1"
        name = "deploy"
        host = "10.0.0.2"
        port = 22
        username = "root"

        [host.auth]
        type = "public_key"
        key_path = "/local/id_ed25519"
        """
        let remote = """
        [[host]]
        id = "h1"
        name = "deploy"
        host = "10.0.0.2"
        port = 22
        username = "root"

        [host.auth]
        type = "public_key"
        key_path = "/other-machine/id_ed25519"
        """
        try local.write(to: sync.hostsURL, atomically: true, encoding: .utf8)

        let snapshot = ConfigSnapshot(
            version: ConfigSnapshot.currentVersion,
            updatedAt: Date().timeIntervalSince1970 + 10,
            hosts: remote,
            groups: ""
        )
        XCTAssertTrue(sync.apply(snapshot: snapshot))

        let result = try String(contentsOf: sync.hostsURL, encoding: .utf8)
        XCTAssertTrue(result.contains("key_path = \"/local/id_ed25519\""))
        XCTAssertFalse(result.contains("/other-machine/id_ed25519"))
    }

    // MARK: - 回环抑制

    func testApplyRemoteDoesNotTriggerPush() throws {
        try makeLocalHosts().write(to: sync.hostsURL, atomically: true, encoding: .utf8)
        kv.clear()

        let remote = ConfigSnapshot(
            version: ConfigSnapshot.currentVersion,
            updatedAt: Date().timeIntervalSince1970 + 10,
            hosts: makeRemoteHosts(),
            groups: ""
        )
        _ = sync.apply(snapshot: remote)

        XCTAssertNil(kv.data(forKey: ConfigSnapshot.kvKey))
    }

    // MARK: - 密钥材料边界

    func testSnapshotDoesNotContainPlaintextPassword() throws {
        let hosts = """
        [[host]]
        id = "h1"
        name = "box"
        host = "example.com"
        port = 22
        username = "panda"

        [host.auth]
        type = "password"
        password_ref = "kc://h1.password"
        """
        try hosts.write(to: sync.hostsURL, atomically: true, encoding: .utf8)

        sync.push()

        guard let data = kv.data(forKey: ConfigSnapshot.kvKey),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("snapshot not found"); return
        }
        XCTAssertTrue(text.contains("password_ref"))
        XCTAssertFalse(text.contains("secret-password"))
    }

    func testKnownHostsFileIsNotSynced() throws {
        try makeLocalHosts().write(to: sync.hostsURL, atomically: true, encoding: .utf8)
        let knownHosts = dir.appendingPathComponent("known_hosts")
        try "fake fingerprint".write(to: knownHosts, atomically: true, encoding: .utf8)

        sync.push()

        guard let data = kv.data(forKey: ConfigSnapshot.kvKey),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("snapshot not found"); return
        }
        XCTAssertFalse(text.contains("fake fingerprint"))
    }

    // MARK: - 迁移

    func testLegacyHostsTomlKeyMigratesToVersionedSnapshot() throws {
        let legacy = "legacy hosts content"
        kv.set(legacy.data(using: .utf8), forKey: ConfigSnapshot.legacyKey)

        _ = sync.pullSnapshot()

        guard let data = kv.data(forKey: ConfigSnapshot.kvKey),
              let snapshot = try? JSONDecoder().decode(ConfigSnapshot.self, from: data) else {
            XCTFail("migration failed"); return
        }
        XCTAssertEqual(snapshot.hosts, legacy)
        XCTAssertEqual(snapshot.groups, "")
        XCTAssertNil(kv.data(forKey: ConfigSnapshot.legacyKey))
    }

    // MARK: - 边界条件

    func testApplyWrongVersionSnapshotIsNoOp() throws {
        try makeLocalHosts().write(to: sync.hostsURL, atomically: true, encoding: .utf8)
        let remote = ConfigSnapshot(
            version: 999,
            updatedAt: Date().timeIntervalSince1970 + 10,
            hosts: makeRemoteHosts(),
            groups: ""
        )
        XCTAssertFalse(sync.apply(snapshot: remote))
    }

    func testPushWithEmptyFilesCreatesSnapshot() {
        sync.push()
        XCTAssertNotNil(kv.data(forKey: ConfigSnapshot.kvKey))
    }

    // MARK: - helpers

    private func makeLocalHosts() -> String {
        """
        [[host]]
        id = "local-id"
        name = "local"
        host = "local.example.com"
        port = 22
        username = "panda"

        [host.auth]
        type = "password"
        password_ref = "kc://local"
        """
    }

    private func makeLocalGroups() -> String {
        """
        [[group]]
        id = "g1"
        name = "本地分组"
        """
    }

    private func makeRemoteHosts() -> String {
        """
        [[host]]
        id = "remote-id"
        name = "remote"
        host = "remote.example.com"
        port = 22
        username = "panda"

        [host.auth]
        type = "password"
        password_ref = "kc://remote"
        """
    }

    private func makeRemoteGroups() -> String {
        """
        [[group]]
        id = "g2"
        name = "远端分组"
        """
    }
}

/// 内存 KVStore,供测试注入。
@MainActor
final class FakeConfigKVStore: ConfigKVStore {
    private var storage: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        storage[key]
    }

    func set(_ value: Any?, forKey key: String) {
        if let data = value as? Data {
            storage[key] = data
        } else {
            storage.removeValue(forKey: key)
        }
    }

    @discardableResult
    func synchronize() -> Bool { true }

    func clear() {
        storage.removeAll()
    }
}
