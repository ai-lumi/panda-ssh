import Foundation

/// 最小 ZIP 打包/解包工具（仅支持 STORE 方法，无压缩）。
/// 满足配置导出/导入场景：少量小文件，速度不是瓶颈，
/// 不引入第三方依赖。
enum ConfigArchiveUtility {

    // MARK: - ZIP 创建

    /// 将 `sources` 中每个文件/目录打包为 ZIP 数据。
    /// - Parameters:
    ///   - sources: 源文件 URL 数组（仅支持文件，不支持递归目录）。
    ///   - directory: 可选的目录前缀（如 "config/"）。
    /// - Returns: ZIP 格式的 Data。
    static func createZip(from sources: [(url: URL, archiveName: String)]) throws -> Data {
        var localHeaders = Data()
        var centralDirectory = Data()
        var offset: UInt32 = 0

        for source in sources {
            let fileData = try Data(contentsOf: source.url)
            let nameData = source.archiveName.data(using: .utf8) ?? Data()
            let crc = crc32(fileData)

            // Local file header
            var local = Data()
            local.append(u32: 0x04034b50)          // Local file header signature
            local.append(u16: 20)                   // Version needed to extract (2.0)
            local.append(u16: 0)                    // General purpose bit flag
            local.append(u16: 0)                    // Compression method (STORE)
            local.append(u16: 0)                    // File last modification time
            local.append(u16: 0)                    // File last modification date
            local.append(u32: crc)                  // CRC-32
            local.append(u32: UInt32(fileData.count)) // Compressed size
            local.append(u32: UInt32(fileData.count)) // Uncompressed size
            local.append(u16: UInt16(nameData.count)) // File name length
            local.append(u16: 0)                    // Extra field length
            local.append(nameData)                  // File name
            local.append(fileData)                  // File data

            localHeaders.append(local)

            // Central directory file header
            var central = Data()
            central.append(u32: 0x02014b50)         // Central directory signature
            central.append(u16: 20)                  // Version made by
            central.append(u16: 20)                  // Version needed to extract
            central.append(u16: 0)                   // General purpose bit flag
            central.append(u16: 0)                   // Compression method (STORE)
            central.append(u16: 0)                   // File last modification time
            central.append(u16: 0)                   // File last modification date
            central.append(u32: crc)                 // CRC-32
            central.append(u32: UInt32(fileData.count)) // Compressed size
            central.append(u32: UInt32(fileData.count)) // Uncompressed size
            central.append(u16: UInt16(nameData.count)) // File name length
            central.append(u16: 0)                   // Extra field length
            central.append(u16: 0)                   // File comment length
            central.append(u16: 0)                   // Disk number start
            central.append(u16: 0)                   // Internal file attributes
            central.append(u32: 0)                   // External file attributes
            central.append(u32: offset)              // Relative offset of local header
            central.append(nameData)                 // File name

            centralDirectory.append(central)

            offset += UInt32(local.count)
        }

        // End of central directory record
        let centralSize = UInt32(centralDirectory.count)
        let centralOffset = UInt32(localHeaders.count)
        var eocd = Data()
        eocd.append(u32: 0x06054b50)               // EOCD signature
        eocd.append(u16: 0)                        // Number of this disk
        eocd.append(u16: 0)                        // Disk with central directory
        eocd.append(u16: UInt16(sources.count))    // Number of entries on this disk
        eocd.append(u16: UInt16(sources.count))    // Total number of entries
        eocd.append(u32: centralSize)              // Size of central directory
        eocd.append(u32: centralOffset)            // Offset of start of central directory
        eocd.append(u16: 0)                        // ZIP file comment length

        var result = Data()
        result.append(localHeaders)
        result.append(centralDirectory)
        result.append(eocd)
        return result
    }

    // MARK: - ZIP 读取

    /// 从 ZIP 数据中列出所有文件名。
    static func listEntries(in zipData: Data) -> [String] {
        guard zipData.count >= 22 else { return [] }

        // Find EOCD signature (0x06054b50) from end
        var eocdOffset = zipData.count - 22
        while eocdOffset >= 0 {
            if zipData.scanUInt32(at: eocdOffset) == 0x06054b50 {
                break
            }
            eocdOffset -= 1
        }
        guard eocdOffset >= 0 else { return [] }

        let centralOffset = Int(zipData.scanUInt32(at: eocdOffset + 16))
        let totalEntries = Int(zipData.scanUInt16(at: eocdOffset + 10))

        var entries: [String] = []
        var offset = centralOffset

        for _ in 0..<totalEntries {
            guard offset + 46 <= zipData.count,
                  zipData.scanUInt32(at: offset) == 0x02014b50 else { break }

            let nameLen = Int(zipData.scanUInt16(at: offset + 28))
            let extraLen = Int(zipData.scanUInt16(at: offset + 30))
            let commentLen = Int(zipData.scanUInt16(at: offset + 32))

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLen
            if let name = String(data: zipData.subdata(in: nameStart..<nameEnd), encoding: .utf8) {
                entries.append(name)
            }

            offset = nameEnd + extraLen + commentLen
        }

        return entries
    }

    /// 从 ZIP 数据中提取指定文件的内容。
    static func extractEntry(named targetName: String, from zipData: Data) -> Data? {
        guard zipData.count >= 22 else { return nil }

        // Find EOCD
        var eocdOffset = zipData.count - 22
        while eocdOffset >= 0 {
            if zipData.scanUInt32(at: eocdOffset) == 0x06054b50 {
                break
            }
            eocdOffset -= 1
        }
        guard eocdOffset >= 0 else { return nil }

        let centralOffset = Int(zipData.scanUInt32(at: eocdOffset + 16))
        let totalEntries = Int(zipData.scanUInt16(at: eocdOffset + 10))

        var offset = centralOffset
        for _ in 0..<totalEntries {
            guard offset + 46 <= zipData.count,
                  zipData.scanUInt32(at: offset) == 0x02014b50 else { break }

            let nameLen = Int(zipData.scanUInt16(at: offset + 28))
            let extraLen = Int(zipData.scanUInt16(at: offset + 30))
            let commentLen = Int(zipData.scanUInt16(at: offset + 32))
            let localHeaderOffset = Int(zipData.scanUInt32(at: offset + 42))

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLen
            if let name = String(data: zipData.subdata(in: nameStart..<nameEnd), encoding: .utf8),
               name == targetName {
                // Found: go to local header
                guard localHeaderOffset + 30 <= zipData.count,
                      zipData.scanUInt32(at: localHeaderOffset) == 0x04034b50 else { return nil }

                let localNameLen = Int(zipData.scanUInt16(at: localHeaderOffset + 26))
                let localExtraLen = Int(zipData.scanUInt16(at: localHeaderOffset + 28))
                let compressedSize = Int(zipData.scanUInt32(at: localHeaderOffset + 18))
                let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen
                let dataEnd = dataStart + compressedSize

                guard dataEnd <= zipData.count else { return nil }
                return zipData.subdata(in: dataStart..<dataEnd)
            }

            offset = nameEnd + extraLen + commentLen
        }

        return nil
    }

    // MARK: - CRC32

    private static func crc32(_ data: Data) -> UInt32 {
        let table: [UInt32] = (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func append(u16 value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append($0.bindMemory(to: UInt8.self)) }
    }

    mutating func append(u32 value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append($0.bindMemory(to: UInt8.self)) }
    }

    func scanUInt16(at offset: Int) -> UInt16 {
        let sub = self.subdata(in: offset..<offset+2)
        return sub.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    }

    func scanUInt32(at offset: Int) -> UInt32 {
        let sub = self.subdata(in: offset..<offset+4)
        return sub.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }
}
