import Foundation
import zlib

/// 清理前整包备份：整个抖音容器 → /private/var/mobile/Media/dybf/*.zip（zlib 最高压缩）
/// 说明：iOS SDK 下 Swift 不可用 system/popen，故使用内置 ZIP，不依赖越狱命令行工具。
enum ContainerArchiveBackup {
    static let backupDirCandidates = [
        "/private/var/mobile/Media/dybf",
        "/var/mobile/Media/dybf"
    ]

    struct Result: Sendable {
        var ok: Bool
        var archivePath: String
        var fileCount: Int
        var error: String?
    }

    static func backupEntireContainer(_ container: URL) -> Result {
        let fm = FileManager.default
        var dirURL: URL?
        for path in backupDirCandidates {
            let u = URL(fileURLWithPath: path, isDirectory: true)
            do {
                try fm.createDirectory(at: u, withIntermediateDirectories: true)
                dirURL = u
                break
            } catch {
                continue
            }
        }
        guard let outDir = dirURL else {
            return Result(ok: false, archivePath: "", fileCount: 0, error: "无法创建 dybf 目录")
        }

        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd_HHmmss"
            return f.string(from: Date())
        }()

        let outURL = outDir.appendingPathComponent("DY_\(stamp).zip")
        do {
            let n = try ZipMaxWriter.writeDirectory(container, to: outURL)
            return Result(ok: true, archivePath: outURL.path, fileCount: n, error: nil)
        } catch {
            return Result(ok: false, archivePath: "", fileCount: 0, error: error.localizedDescription)
        }
    }
}

// MARK: - 内置最大压缩 ZIP（raw deflate via zlib）

enum ZipMaxWriter {
    static func writeDirectory(_ root: URL, to zipURL: URL) throws -> Int {
        let fm = FileManager.default
        if fm.fileExists(atPath: zipURL.path) {
            try fm.removeItem(at: zipURL)
        }
        fm.createFile(atPath: zipURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: zipURL) else {
            throw NSError(domain: "ZipMaxWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法写入压缩包"])
        }
        defer { try? handle.close() }

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: []
        ) else {
            throw NSError(domain: "ZipMaxWriter", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法枚举容器"])
        }

        let rootPath = root.standardizedFileURL.path
        var centrals: [Data] = []
        var count = 0

        while let item = enumerator.nextObject() as? URL {
            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if vals?.isDirectory == true { continue }
            guard vals?.isRegularFile == true else { continue }

            let full = item.standardizedFileURL.path
            guard full.hasPrefix(rootPath) else { continue }
            var rel = String(full.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            rel = rel.replacingOccurrences(of: "\\", with: "/")
            let entryName = root.lastPathComponent + "/" + rel

            let localOffset = UInt32(handle.offsetInFile)
            let fileData = try Data(contentsOf: item, options: [.mappedIfSafe])
            let crc = crc32Value(fileData)
            let compressed = try deflateRaw(fileData)
            let useStore = compressed.count >= fileData.count
            let payload = useStore ? fileData : compressed
            let method: UInt16 = useStore ? 0 : 8

            let nameData = Data(entryName.utf8)
            var local = Data()
            local.appendUInt32(0x04034b50)
            local.appendUInt16(20)
            local.appendUInt16(0)
            local.appendUInt16(method)
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt32(crc)
            local.appendUInt32(UInt32(payload.count))
            local.appendUInt32(UInt32(fileData.count))
            local.appendUInt16(UInt16(nameData.count))
            local.appendUInt16(0)
            local.append(nameData)
            local.append(payload)
            try handle.write(contentsOf: local)

            var central = Data()
            central.appendUInt32(0x02014b50)
            central.appendUInt16(20)
            central.appendUInt16(20)
            central.appendUInt16(0)
            central.appendUInt16(method)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(crc)
            central.appendUInt32(UInt32(payload.count))
            central.appendUInt32(UInt32(fileData.count))
            central.appendUInt16(UInt16(nameData.count))
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(0)
            central.appendUInt32(localOffset)
            central.append(nameData)
            centrals.append(central)
            count += 1
        }

        let centralStart = UInt32(handle.offsetInFile)
        for c in centrals {
            try handle.write(contentsOf: c)
        }
        let centralSize = UInt32(handle.offsetInFile) - centralStart

        var end = Data()
        end.appendUInt32(0x06054b50)
        end.appendUInt16(0)
        end.appendUInt16(0)
        end.appendUInt16(UInt16(centrals.count))
        end.appendUInt16(UInt16(centrals.count))
        end.appendUInt32(centralSize)
        end.appendUInt32(centralStart)
        end.appendUInt16(0)
        try handle.write(contentsOf: end)
        return count
    }

    /// 按「入口名 + 文件」列表打包（精简缓存导出用）
    static func writeFileList(_ files: [(entry: String, file: URL)], to zipURL: URL) throws -> Int {
        let fm = FileManager.default
        if fm.fileExists(atPath: zipURL.path) {
            try fm.removeItem(at: zipURL)
        }
        fm.createFile(atPath: zipURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: zipURL) else {
            throw NSError(domain: "ZipMaxWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法写入压缩包"])
        }
        defer { try? handle.close() }

        var centrals: [Data] = []
        var count = 0
        for pair in files {
            let fileData = try Data(contentsOf: pair.file, options: [.mappedIfSafe])
            let crc = crc32Value(fileData)
            let compressed = try deflateRaw(fileData)
            let useStore = compressed.count >= fileData.count
            let payload = useStore ? fileData : compressed
            let method: UInt16 = useStore ? 0 : 8
            let nameData = Data(pair.entry.utf8)
            let localOffset = UInt32(handle.offsetInFile)

            var local = Data()
            local.appendUInt32(0x04034b50)
            local.appendUInt16(20)
            local.appendUInt16(0)
            local.appendUInt16(method)
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt32(crc)
            local.appendUInt32(UInt32(payload.count))
            local.appendUInt32(UInt32(fileData.count))
            local.appendUInt16(UInt16(nameData.count))
            local.appendUInt16(0)
            local.append(nameData)
            local.append(payload)
            try handle.write(contentsOf: local)

            var central = Data()
            central.appendUInt32(0x02014b50)
            central.appendUInt16(20)
            central.appendUInt16(20)
            central.appendUInt16(0)
            central.appendUInt16(method)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(crc)
            central.appendUInt32(UInt32(payload.count))
            central.appendUInt32(UInt32(fileData.count))
            central.appendUInt16(UInt16(nameData.count))
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(0)
            central.appendUInt32(localOffset)
            central.append(nameData)
            centrals.append(central)
            count += 1
        }

        let centralStart = UInt32(handle.offsetInFile)
        for c in centrals {
            try handle.write(contentsOf: c)
        }
        let centralSize = UInt32(handle.offsetInFile) - centralStart

        var end = Data()
        end.appendUInt32(0x06054b50)
        end.appendUInt16(0)
        end.appendUInt16(0)
        end.appendUInt16(UInt16(centrals.count))
        end.appendUInt16(UInt16(centrals.count))
        end.appendUInt32(centralSize)
        end.appendUInt32(centralStart)
        end.appendUInt16(0)
        try handle.write(contentsOf: end)
        return count
    }

    private static func crc32Value(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buf -> UInt32 in
            let ptr = buf.bindMemory(to: Bytef.self).baseAddress
            return UInt32(zlib.crc32(0, ptr, uInt(data.count)))
        }
    }

    private static func deflateRaw(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        var stream = z_stream()
        var status = deflateInit2_(
            &stream,
            Z_BEST_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw NSError(domain: "ZipMaxWriter", code: 3, userInfo: [NSLocalizedDescriptionKey: "压缩初始化失败"])
        }
        defer { _ = deflateEnd(&stream) }

        var output = Data()
        let chunk = 64 * 1024
        var inputOffset = 0
        var outBuffer = [UInt8](repeating: 0, count: chunk)

        while inputOffset < data.count {
            let remain = data.count - inputOffset
            let inSize = min(chunk, remain)
            let flush = (inputOffset + inSize >= data.count) ? Z_FINISH : Z_NO_FLUSH
            let sub = data.subdata(in: inputOffset..<(inputOffset + inSize))
            inputOffset += inSize

            try sub.withUnsafeBytes { inBuf in
                guard let base = inBuf.bindMemory(to: Bytef.self).baseAddress else { return }
                stream.next_in = UnsafeMutablePointer(mutating: base)
                stream.avail_in = uInt(inSize)

                repeat {
                    let wrote: Int = outBuffer.withUnsafeMutableBytes { outBuf in
                        stream.next_out = outBuf.bindMemory(to: Bytef.self).baseAddress!
                        stream.avail_out = uInt(chunk)
                        status = deflate(&stream, flush)
                        return chunk - Int(stream.avail_out)
                    }
                    if wrote > 0 {
                        output.append(contentsOf: outBuffer.prefix(wrote))
                    }
                } while status == Z_OK && stream.avail_out == 0

                if status == Z_STREAM_END { return }
                if status != Z_OK && flush != Z_FINISH {
                    throw NSError(domain: "ZipMaxWriter", code: 4, userInfo: [NSLocalizedDescriptionKey: "压缩失败"])
                }
            }
        }

        while status != Z_STREAM_END {
            let wrote: Int = outBuffer.withUnsafeMutableBytes { outBuf in
                stream.next_out = outBuf.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(chunk)
                status = deflate(&stream, Z_FINISH)
                return chunk - Int(stream.avail_out)
            }
            if wrote > 0 {
                output.append(contentsOf: outBuffer.prefix(wrote))
            }
            if status != Z_OK && status != Z_STREAM_END {
                throw NSError(domain: "ZipMaxWriter", code: 5, userInfo: [NSLocalizedDescriptionKey: "压缩结束失败"])
            }
        }
        return output
    }
}

private extension Data {
    mutating func appendUInt16(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
