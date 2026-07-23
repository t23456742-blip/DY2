import Foundation
import zlib
import Darwin

/// 清理前整包备份：整个抖音容器 → /private/var/mobile/Media/dybf/*.7z|*.zip（尽量最小）
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

        // 1) 优先 7z（通常最小）
        if let seven = findBinary(["7z", "7za", "7zr"]) {
            let out = outDir.appendingPathComponent("DY_\(stamp).7z").path
            let outQ = shellQuote(out)
            let cmd = "\(shellQuote(seven)) a -t7z -mx=9 -mmt=on \(outQ) \(shellQuote(container.path))"
            if shell(cmd) == 0, fm.fileExists(atPath: out),
               (try? fm.attributesOfItem(atPath: out)[.size] as? NSNumber)?.int64Value ?? 0 > 0 {
                let n = countFiles(under: container)
                return Result(ok: true, archivePath: out, fileCount: n, error: nil)
            }
            try? fm.removeItem(atPath: out)
        }

        // 2) zip -9
        if let zipBin = findBinary(["zip"]) {
            let out = outDir.appendingPathComponent("DY_\(stamp).zip").path
            let parent = container.deletingLastPathComponent().path
            let name = container.lastPathComponent
            let cmd = "cd \(shellQuote(parent)) && \(shellQuote(zipBin)) -r -9 -q \(shellQuote(out)) \(shellQuote(name))"
            if shell(cmd) == 0, fm.fileExists(atPath: out),
               (try? fm.attributesOfItem(atPath: out)[.size] as? NSNumber)?.int64Value ?? 0 > 0 {
                let n = countFiles(under: container)
                return Result(ok: true, archivePath: out, fileCount: n, error: nil)
            }
            try? fm.removeItem(atPath: out)
        }

        // 3) tar + gzip（无 zip/7z 时）
        if let tar = findBinary(["tar"]) {
            let out = outDir.appendingPathComponent("DY_\(stamp).tar.gz").path
            let parent = container.deletingLastPathComponent().path
            let name = container.lastPathComponent
            let cmd = "cd \(shellQuote(parent)) && \(shellQuote(tar)) -czf \(shellQuote(out)) \(shellQuote(name))"
            if shell(cmd) == 0, fm.fileExists(atPath: out),
               (try? fm.attributesOfItem(atPath: out)[.size] as? NSNumber)?.int64Value ?? 0 > 0 {
                let n = countFiles(under: container)
                return Result(ok: true, archivePath: out, fileCount: n, error: nil)
            }
            try? fm.removeItem(atPath: out)
        }

        // 4) 内置 ZIP（zlib 最高压缩）——不依赖越狱工具
        let outURL = outDir.appendingPathComponent("DY_\(stamp).zip")
        do {
            let n = try ZipMaxWriter.writeDirectory(container, to: outURL)
            return Result(ok: true, archivePath: outURL.path, fileCount: n, error: nil)
        } catch {
            return Result(ok: false, archivePath: "", fileCount: 0, error: error.localizedDescription)
        }
    }

    private static func countFiles(under root: URL) -> Int {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var n = 0
        while let u = en.nextObject() as? URL {
            let isFile = (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isFile { n += 1 }
        }
        return n
    }

    private static func findBinary(_ names: [String]) -> String? {
        var roots = [
            "/usr/bin", "/usr/local/bin", "/bin",
            "/var/jb/usr/bin", "/var/jb/bin",
            "/usr/libexec"
        ]
        // RootHide / 部分越狱：扫描常见前缀下的 usr/bin
        for prefix in ["/var/jb", "/var/LIB", "/var/containers/Bundle/Application"] {
            if let kids = try? FileManager.default.contentsOfDirectory(atPath: prefix) {
                for k in kids.prefix(30) {
                    roots.append("\(prefix)/\(k)/usr/bin")
                }
            }
        }
        for name in names {
            if let via = popenWhich(name) { return via }
            for r in roots {
                let p = "\(r)/\(name)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    private static func popenWhich(_ name: String) -> String? {
        let cmd = "command -v \(name) 2>/dev/null"
        guard let pipe = popen(cmd, "r") else { return nil }
        defer { _ = pclose(pipe) }
        var buf = [CChar](repeating: 0, count: 512)
        if fgets(&buf, Int32(buf.count), pipe) != nil {
            let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return nil
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func shell(_ cmd: String) -> Int32 {
        system(cmd)
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
        var offsets: [UInt32] = []
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
            // ZIP 内带顶层文件夹名，便于解压
            let entryName = root.lastPathComponent + "/" + rel

            let localOffset = UInt32(handle.offsetInFile)
            let fileData = try Data(contentsOf: item, options: [.mappedIfSafe])
            let crc = crc32(0, fileData)
            let compressed = try deflateRaw(fileData)
            let useStore = compressed.count >= fileData.count
            let payload = useStore ? fileData : compressed
            let method: UInt16 = useStore ? 0 : 8

            let nameData = Data(entryName.utf8)
            var local = Data()
            local.appendUInt32(0x04034b50) // local header
            local.appendUInt16(20) // version needed
            local.appendUInt16(0) // flags
            local.appendUInt16(method)
            local.appendUInt16(0) // time
            local.appendUInt16(0) // date
            local.appendUInt32(crc)
            local.appendUInt32(UInt32(payload.count))
            local.appendUInt32(UInt32(fileData.count))
            local.appendUInt16(UInt16(nameData.count))
            local.appendUInt16(0) // extra
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
            offsets.append(localOffset)
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

    private static func crc32(_ seed: uLong, _ data: Data) -> UInt32 {
        data.withUnsafeBytes { buf -> UInt32 in
            let ptr = buf.bindMemory(to: Bytef.self).baseAddress
            return UInt32(zlib.crc32(seed, ptr, uInt(data.count)))
        }
    }

    private static func deflateRaw(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        var stream = z_stream()
        var status = deflateInit2_(
            &stream,
            Z_BEST_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS, // raw deflate for ZIP
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
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inBuf.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in = uInt(inSize)

                repeat {
                    let wrote: Int = outBuffer.withUnsafeMutableBytes { outBuf in
                        stream.next_out = outBuf.bindMemory(to: Bytef.self).baseAddress!
                        stream.avail_out = uInt(chunk)
                        status = deflate(&stream, flush)
                        let produced = chunk - Int(stream.avail_out)
                        return produced
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
