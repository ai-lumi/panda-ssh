import XCTest

#if os(macOS)
@testable import PandaSSH_macOS

/// 配置导出/导入测试：覆盖正常导出、导入校验、版本不匹配、
/// 文件损坏、空配置、边界条件等场景。
final class ConfigExportImportTests: XCTestCase {

    private var tempDir: URL!
    private var configDir: URL!
    private var fm: FileManager!

    override func setUp() {
        super.setUp()
        fm = FileManager.default
        tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configDir = tempDir.appendingPathComponent("config")
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeHostsToml() -> Data {
        """
        [[host]]
        id = "h1"
        name = "web-prod"
        host = "203.0.113.10"
        port = 22
        username = "root"

        [host.auth]
        type = "password"
        password_ref = "host.h1.password"
        """.data(using: .utf8)!
    }

    private func makeGroupsToml() -> Data {
        """
        [[group]]
        id = "g1"
        name = "生产环境"
        """.data(using: .utf8)!
    }

    private func makeKnownHosts() -> Data {
        "203.0.113.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGateTest\n".data(using: .utf8)!
    }

    private func setupConfigFiles(includeSnippets: Bool = true) throws {
        try makeHostsToml().write(to: configDir.appendingPathComponent("hosts.toml"))
        try makeGroupsToml().write(to: configDir.appendingPathComponent("groups.toml"))
        try makeKnownHosts().write(to: configDir.appendingPathComponent("known_hosts"))

        if includeSnippets {
            let snippetsDir = configDir.appendingPathComponent("snippets")
            try fm.createDirectory(at: snippetsDir, withIntermediateDirectories: true)
            let snippetContent = "# Snippet\n\ndu -ah . | sort -rh | head -n 10".data(using: .utf8)!
            try snippetContent.write(to: snippetsDir.appendingPathComponent("snippet1.md"))
        }
    }

    // MARK: - 1.1 导出打包测试

    func testExportContainsRequiredFiles() throws {
        try setupConfigFiles()

        let data = try ConfigExporter.export(configDir: configDir)
        let entries = ConfigArchiveUtility.listEntries(in: data)

        XCTAssertTrue(entries.contains("config/hosts.toml"))
        XCTAssertTrue(entries.contains("config/groups.toml"))
        XCTAssertTrue(entries.contains("config/known_hosts"))
        XCTAssertTrue(entries.contains("manifest.json"))
    }

    func testExportContainsSnippets() throws {
        try setupConfigFiles()

        let data = try ConfigExporter.export(configDir: configDir)
        let entries = ConfigArchiveUtility.listEntries(in: data)

        XCTAssertTrue(entries.contains("snippets/snippet1.md"))
    }

    func testExportDoesNotContainPlaintextPassword() throws {
        try setupConfigFiles()

        let data = try ConfigExporter.export(configDir: configDir)
        guard let hostsData = ConfigArchiveUtility.extractEntry(named: "config/hosts.toml", from: data),
              let hostsText = String(data: hostsData, encoding: .utf8) else {
            XCTFail("hosts.toml not found in archive"); return
        }

        XCTAssertTrue(hostsText.contains("password_ref"))
        XCTAssertFalse(hostsText.contains("secret-password"))
    }

    func testExportManifestHasVersionAndTimestamp() throws {
        try setupConfigFiles()

        let data = try ConfigExporter.export(configDir: configDir)
        guard let manifestData = ConfigArchiveUtility.extractEntry(named: "manifest.json", from: data),
              let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            XCTFail("manifest.json not found or invalid"); return
        }

        XCTAssertEqual(manifest["version"] as? Int, 1)
        XCTAssertNotNil(manifest["exportedAt"])
        XCTAssertNotNil(manifest["device"])
    }

    // MARK: - 1.2 导入校验测试

    func testImportValidArchiveOverwritesAndBacksUp() throws {
        try setupConfigFiles()
        let exportData = try ConfigExporter.export(configDir: configDir)

        // 修改本地文件以验证覆盖
        let newHosts = "[[host]]\nid = \"h2\"\n".data(using: .utf8)!
        try newHosts.write(to: configDir.appendingPathComponent("hosts.toml"))

        let result = try ConfigImporter.import(pandasshData: exportData, configDir: configDir)

        // 验证旧文件被备份
        XCTAssertTrue(result.backedUpFiles.contains(where: { $0.hasPrefix("hosts.toml.backup.") }))

        // 验证文件被恢复
        let restoredHosts = try String(contentsOf: configDir.appendingPathComponent("hosts.toml"), encoding: .utf8)
        XCTAssertTrue(restoredHosts.contains("h1"))
    }

    func testImportVersionMismatchThrows() throws {
        // 构造一个版本过高的 manifest
        let manifest: [String: Any] = ["version": 999, "exportedAt": "2026-01-01", "device": "test"]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL)

        let hostsData = makeHostsToml()
        let hostsURL = tempDir.appendingPathComponent("hosts.toml")
        try hostsData.write(to: hostsURL)

        let zipData = try ConfigArchiveUtility.createZip(from: [
            (url: hostsURL, archiveName: "config/hosts.toml"),
            (url: manifestURL, archiveName: "manifest.json"),
        ])

        XCTAssertThrowsError(try ConfigImporter.import(pandasshData: zipData, configDir: configDir)) { error in
            guard case ConfigImporter.ImportError.versionMismatch(let v) = error else {
                XCTFail("Expected versionMismatch, got \(error)"); return
            }
            XCTAssertEqual(v, 999)
        }
    }

    func testImportMissingManifestThrows() throws {
        let hostsData = makeHostsToml()
        let hostsURL = tempDir.appendingPathComponent("hosts.toml")
        try hostsData.write(to: hostsURL)

        let zipData = try ConfigArchiveUtility.createZip(from: [
            (url: hostsURL, archiveName: "config/hosts.toml"),
        ])

        XCTAssertThrowsError(try ConfigImporter.import(pandasshData: zipData, configDir: configDir)) { error in
            guard case ConfigImporter.ImportError.missingManifest = error else {
                XCTFail("Expected missingManifest, got \(error)"); return
            }
        }
    }

    func testImportMissingRequiredFileThrows() throws {
        // manifest 存在但缺少 groups.toml
        let manifest: [String: Any] = ["version": 1, "exportedAt": "2026-01-01", "device": "test"]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL)

        let hostsData = makeHostsToml()
        let hostsURL = tempDir.appendingPathComponent("hosts.toml")
        try hostsData.write(to: hostsURL)

        let zipData = try ConfigArchiveUtility.createZip(from: [
            (url: hostsURL, archiveName: "config/hosts.toml"),
            (url: manifestURL, archiveName: "manifest.json"),
        ])

        XCTAssertThrowsError(try ConfigImporter.import(pandasshData: zipData, configDir: configDir)) { error in
            guard case ConfigImporter.ImportError.missingRequiredFile(let name) = error else {
                XCTFail("Expected missingRequiredFile, got \(error)"); return
            }
            XCTAssertEqual(name, "config/groups.toml")
        }
    }

    func testImportCorruptedArchiveThrows() throws {
        let badData = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertThrowsError(try ConfigImporter.import(pandasshData: badData, configDir: configDir)) { error in
            guard case ConfigImporter.ImportError.invalidArchive = error else {
                XCTFail("Expected invalidArchive, got \(error)"); return
            }
        }
    }

    // MARK: - 1.3 边界测试

    func testExportEmptyConfigStillValid() throws {
        // 空配置：目录存在但无文件
        let data = try ConfigExporter.export(configDir: configDir)
        let entries = ConfigArchiveUtility.listEntries(in: data)

        XCTAssertTrue(entries.contains("manifest.json"))
        // hosts.toml 等可选文件不存在时不包含
        XCTAssertFalse(entries.contains("config/hosts.toml"))
    }

    func testExportEmptySnippetsDir() throws {
        try setupConfigFiles(includeSnippets: false)
        let snippetsDir = configDir.appendingPathComponent("snippets")
        try fm.createDirectory(at: snippetsDir, withIntermediateDirectories: true)

        let data = try ConfigExporter.export(configDir: configDir)
        let entries = ConfigArchiveUtility.listEntries(in: data)

        XCTAssertTrue(entries.contains("config/hosts.toml"))
        // snippets 目录为空，不应包含任何 snippets/ 条目
        XCTAssertFalse(entries.contains(where: { $0.hasPrefix("snippets/") && $0 != "snippets/" }))
    }

    func testImportRestoresPasswordRef() throws {
        try setupConfigFiles()
        let exportData = try ConfigExporter.export(configDir: configDir)

        let freshDir = tempDir.appendingPathComponent("fresh")
        try fm.createDirectory(at: freshDir, withIntermediateDirectories: true)

        let result = try ConfigImporter.import(pandasshData: exportData, configDir: freshDir)
        XCTAssertTrue(result.backedUpFiles.isEmpty)

        let hostsText = try String(contentsOf: freshDir.appendingPathComponent("hosts.toml"), encoding: .utf8)
        XCTAssertTrue(hostsText.contains("password_ref"))
    }
}
#endif
