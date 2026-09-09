import Foundation

/// 配置导入器：读取 `.pandassh` 文件并恢复到本地配置目录。
enum ConfigImporter {
    /// 当前支持的最大导入格式版本。
    static let supportedVersion = 1

    /// 导入错误。
    enum ImportError: Error, Equatable {
        case invalidArchive
        case missingManifest
        case versionMismatch(Int)
        case missingRequiredFile(String)
        case writeFailed
    }

    /// 导入结果。
    struct ImportResult {
        let backedUpFiles: [String]
    }

    /// 执行导入。
    /// - Parameters:
    ///   - pandasshData: `.pandassh` 文件的 ZIP 数据。
    ///   - configDir: 目标配置目录（通常为 `AppPaths.configDirectory`）。
    /// - Returns: 导入结果，包含被备份的文件名列表。
    static func `import`(pandasshData: Data, configDir: URL) throws -> ImportResult {
        // 1. 校验 ZIP 基本结构
        let entries = ConfigArchiveUtility.listEntries(in: pandasshData)
        guard !entries.isEmpty else {
            throw ImportError.invalidArchive
        }

        // 2. 读取并校验 manifest
        guard let manifestData = ConfigArchiveUtility.extractEntry(named: "manifest.json", from: pandasshData),
              let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let version = manifest["version"] as? Int else {
            throw ImportError.missingManifest
        }
        guard version <= supportedVersion else {
            throw ImportError.versionMismatch(version)
        }

        // 3. 校验必要文件存在
        let requiredFiles = ["config/hosts.toml", "config/groups.toml"]
        for required in requiredFiles {
            guard entries.contains(required) else {
                throw ImportError.missingRequiredFile(required)
            }
        }

        // 4. 覆盖前备份旧文件
        let fm = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        var backedUp: [String] = []

        let filesToRestore: [(entryName: String, destPath: String)] = [
            ("config/hosts.toml", "hosts.toml"),
            ("config/groups.toml", "groups.toml"),
            ("config/known_hosts", "known_hosts"),
        ]

        for (_, destName) in filesToRestore {
            let destURL = configDir.appendingPathComponent(destName)
            if fm.fileExists(atPath: destURL.path) {
                let backupName = "\(destName).backup.\(timestamp)"
                let backupURL = configDir.appendingPathComponent(backupName)
                try? fm.copyItem(at: destURL, to: backupURL)
                backedUp.append(backupName)
            }
        }

        // 5. 写入配置文件
        for (entryName, destName) in filesToRestore {
            guard let data = ConfigArchiveUtility.extractEntry(named: entryName, from: pandasshData) else { continue }
            let destURL = configDir.appendingPathComponent(destName)
            try data.write(to: destURL, options: .atomic)
        }

        // 6. 恢复 snippets
        let snippetsDestDir = configDir.appendingPathComponent("snippets")
        // 先清空现有 snippets（保留目录本身）
        if fm.fileExists(atPath: snippetsDestDir.path) {
            let items = try? fm.contentsOfDirectory(at: snippetsDestDir, includingPropertiesForKeys: nil)
            for item in items ?? [] {
                try? fm.removeItem(at: item)
            }
        } else {
            try fm.createDirectory(at: snippetsDestDir, withIntermediateDirectories: true)
        }

        for entry in entries where entry.hasPrefix("snippets/") && entry != "snippets/" {
            guard let data = ConfigArchiveUtility.extractEntry(named: entry, from: pandasshData) else { continue }
            let relativePath = String(entry.dropFirst("snippets/".count))
            let destURL = snippetsDestDir.appendingPathComponent(relativePath)
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destURL, options: .atomic)
        }

        return ImportResult(backedUpFiles: backedUp)
    }
}
