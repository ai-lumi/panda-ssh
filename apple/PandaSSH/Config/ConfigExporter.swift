import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 配置导出器：将本地配置打包为 `.pandassh` 文件。

private func deviceName() -> String {
    #if os(macOS)
    return Host.current().localizedName ?? "Unknown"
    #else
    return UIDevice.current.name
    #endif
}
enum ConfigExporter {
    /// 当前支持的导出格式版本。
    static let currentVersion = 1

    /// 导出错误。
    enum ExportError: Error, Equatable {
        case fileNotFound(URL)
        case archiveCreationFailed
    }

    /// 执行导出，返回 ZIP 格式的 `.pandassh` 文件数据。
    /// - Parameter configDir: 配置目录 URL（通常为 `AppPaths.configDirectory`）。
    /// - Returns: 导出的 ZIP 数据。
    static func export(configDir: URL) throws -> Data {
        let fm = FileManager.default
        var sources: [(url: URL, archiveName: String)] = []

        // 必须包含的配置文件
        let requiredFiles = [
            ("hosts.toml", "config/hosts.toml"),
            ("groups.toml", "config/groups.toml"),
            ("known_hosts", "config/known_hosts"),
        ]
        for (fileName, archiveName) in requiredFiles {
            let url = configDir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: url.path) {
                sources.append((url: url, archiveName: archiveName))
            }
        }

        // snippets 目录下的全部文件
        let snippetsDir = configDir.appendingPathComponent("snippets")
        if fm.fileExists(atPath: snippetsDir.path) {
            // 使用标准化路径做前缀匹配：/var 是指向 /private/var 的符号链接，
            // 枚举器返回的 URL 可能已解析符号链接，直接字符串替换会失效。
            let snippetsRoot = snippetsDir.standardizedFileURL.path
            let enumerator = fm.enumerator(at: snippetsDir, includingPropertiesForKeys: nil)
            while let itemURL = enumerator?.nextObject() as? URL {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: itemURL.path, isDirectory: &isDir), !isDir.boolValue {
                    let absolute = itemURL.standardizedFileURL.path
                    let relativePath = absolute.hasPrefix(snippetsRoot + "/")
                        ? "snippets/" + absolute.dropFirst(snippetsRoot.count + 1)
                        : itemURL.lastPathComponent
                    sources.append((url: itemURL, archiveName: relativePath))
                }
            }
        }

        // manifest.json
        let manifest: [String: Any] = [
            "version": currentVersion,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "device": deviceName(),
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("manifest_\(UUID().uuidString).json")
        try manifestData.write(to: manifestURL)
        sources.append((url: manifestURL, archiveName: "manifest.json"))

        let zipData = try ConfigArchiveUtility.createZip(from: sources)

        // 清理临时 manifest 文件
        try? fm.removeItem(at: manifestURL)

        guard !zipData.isEmpty else {
            throw ExportError.archiveCreationFailed
        }
        return zipData
    }
}
