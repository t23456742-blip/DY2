import Foundation
import zlib

/// 按 H9 精简白名单：从扫描结果导出「精简缓存包」，或注入回抖音容器。
enum DouyinSlimCachePack {
    static let outDirCandidates = [
        "/private/var/mobile/Media/dyhc",
        "/var/mobile/Media/dyhc",
        "/private/var/mobile/Media/dybf",
        "/var/mobile/Media/dybf"
    ]

    struct ExportResult: Sendable {
        var ok: Bool
        var path: String
        var fileCount: Int
        var bytes: Int64
        var message: String
    }

    struct ImportResult: Sendable {
        var ok: Bool
        var written: Int
        var skipped: Int
        var message: String
    }

    /// 只打包 shouldKeep 的文件（对齐 H9 可用备份）
    static func exportKeepCache(container: URL, cleaner: SlimCleaner) -> ExportResult {
        let fm = FileManager.default
        guard let outDir = firstWritableDir() else {
            return .init(ok: false, path: "", fileCount: 0, bytes: 0, message: "无法创建 dyhc 目录")
        }

        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: Date())
        }()
        let zipURL = outDir.appendingPathComponent("\(stamp)_slimcache.zip")
        let entryPrefix = "\(stamp)/com.ss.iphone.ugc.Aweme"

        guard let enumerator = fm.enumerator(
            at: container,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: []
        ) else {
            return .init(ok: false, path: "", fileCount: 0, bytes: 0, message: "无法枚举抖音容器")
        }

        let rootPath = container.standardizedFileURL.path
        var pairs: [(entry: String, file: URL)] = []
        var totalBytes: Int64 = 0

        while let item = enumerator.nextObject() as? URL {
            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if vals?.isDirectory == true { continue }
            guard vals?.isRegularFile == true else { continue }
            let full = item.standardizedFileURL.path
            guard full.hasPrefix(rootPath) else { continue }
            var rel = String(full.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            rel = rel.replacingOccurrences(of: "\\", with: "/")
            if SlimCleaner.protectedNames.contains(item.lastPathComponent) { continue }
            guard cleaner.shouldKeep(relativePath: rel) else { continue }
            pairs.append(("\(entryPrefix)/\(rel)", item))
            totalBytes += Int64(vals?.fileSize ?? 0)
        }

        guard !pairs.isEmpty else {
            return .init(ok: false, path: "", fileCount: 0, bytes: 0, message: "没有可导出的保留文件（请先扫描）")
        }

        do {
            let n = try ZipMaxWriter.writeFileList(pairs, to: zipURL)
            return .init(
                ok: true,
                path: zipURL.path,
                fileCount: n,
                bytes: totalBytes,
                message: "已导出精简缓存 \(n) 个文件 → \(zipURL.path)"
            )
        } catch {
            return .init(ok: false, path: "", fileCount: 0, bytes: 0, message: "导出失败：\(error.localizedDescription)")
        }
    }

    /// 把精简缓存包写进当前抖音容器（覆盖同名路径）
    static func importKeepCache(into container: URL, zipPath: String? = nil) -> ImportResult {
        let fm = FileManager.default
        let zipURL: URL
        if let zipPath, fm.fileExists(atPath: zipPath) {
            zipURL = URL(fileURLWithPath: zipPath)
        } else if let latest = latestSlimZip() {
            zipURL = latest
        } else {
            return .init(ok: false, written: 0, skipped: 0, message: "未找到精简缓存包（请先点「导出精简缓存」，或把 zip 放到 Media/dyhc）")
        }

        do {
            let entries = try ZipSimpleReader.readEntries(zipURL)
            let cleaner = SlimCleaner()
            var written = 0
            var skipped = 0
            for e in entries {
                guard let rel = normalizeEntryToContainerRel(e.name) else {
                    skipped += 1
                    continue
                }
                if !cleaner.shouldKeep(relativePath: rel) && !isH9StyleRel(rel) {
                    skipped += 1
                    continue
                }
                let dest = container.appendingPathComponent(rel)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try e.data.write(to: dest, options: .atomic)
                written += 1
            }
            let tip = "已注入 \(written) 个文件（跳过 \(skipped)）← \(zipURL.lastPathComponent)\n请划掉抖音后重开"
            return .init(ok: written > 0, written: written, skipped: skipped, message: tip)
        } catch {
            return .init(ok: false, written: 0, skipped: 0, message: "注入失败：\(error.localizedDescription)")
        }
    }

    private static func isH9StyleRel(_ rel: String) -> Bool {
        let r = rel.replacingOccurrences(of: "\\", with: "/")
        if r.hasPrefix("Documents/mmkv") { return true }
        if r.hasPrefix("Documents/_ttinstall_document") { return true }
        if r.hasPrefix("Documents/com.bytedance.ies") { return true }
        if r.hasPrefix("Library/AWEStorage") { return true }
        if r.hasPrefix("Library/AWEIMRoot") { return true }
        if r.hasPrefix("Library/Application Support/gurd_cache") { return true }
        if r.hasPrefix("Library/Preferences") { return true }
        if r.hasPrefix("Library/HTTPStorages") { return true }
        if SlimCleaner.documentsKeepFiles.contains(r) { return true }
        if SlimCleaner.libraryKeepFiles.contains(r) { return true }
        return false
    }

    private static func normalizeEntryToContainerRel(_ name: String) -> String? {
        var n = name.replacingOccurrences(of: "\\", with: "/")
        if n.hasSuffix("/") { return nil }
        if let r = n.range(of: "com.ss.iphone.ugc.Aweme/", options: .caseInsensitive) {
            n = String(n[r.upperBound...])
        }
        if n.hasPrefix("Documents/") || n.hasPrefix("Library/") || n.hasPrefix("tmp/") {
            return n
        }
        if let r = n.range(of: "Documents/") { return String(n[r.lowerBound...]) }
        if let r = n.range(of: "Library/") { return String(n[r.lowerBound...]) }
        if let r = n.range(of: "tmp/") { return String(n[r.lowerBound...]) }
        return nil
    }

    private static func firstWritableDir() -> URL? {
        let fm = FileManager.default
        for path in outDirCandidates {
            let u = URL(fileURLWithPath: path, isDirectory: true)
            do {
                try fm.createDirectory(at: u, withIntermediateDirectories: true)
                return u
            } catch { continue }
        }
        return nil
    }

    static func latestSlimZip() -> URL? {
        let fm = FileManager.default
        var zips: [URL] = []
        for path in outDirCandidates {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for u in items where u.pathExtension.lowercased() == "zip" {
                let name = u.lastPathComponent.lowercased()
                if path.contains("dyhc") || name.contains("slim") || name.contains("cache") {
                    zips.append(u)
                }
            }
        }
        return zips.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }.first
    }
}

// MARK: - 简易 ZIP 读取（store / deflate）

enum ZipSimpleReader {
    struct Entry {
        var name: String
        var data: Data
    }

    static func readEntries(_ url: URL) throws -> [Entry] {
        let data = try Data(contentsOf: url)
        var entries: [Entry] = []
        var offset = 0
        while offset + 30 <= data.count {
            let sig: UInt32 = readU32(data, offset)
            if sig == 0x02014b50 || sig == 0x06054b50 { break }
            guard sig == 0x04034b50 else { break }
            let method = Int(readU16(data, offset + 8))
            let compSize = Int(readU32(data, offset + 18))
            let uncompSize = Int(readU32(data, offset + 22))
            let nameLen = Int(readU16(data, offset + 26))
            let extraLen = Int(readU16(data, offset + 28))
            let nameStart = offset + 30
            let nameEnd = nameStart + nameLen
            guard nameEnd + extraLen + compSize <= data.count else { break }
            let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8) ?? ""
            let payloadStart = nameEnd + extraLen
            let payload = data.subdata(in: payloadStart..<(payloadStart + compSize))
            let raw: Data
            if method == 0 {
                raw = payload
            } else if method == 8 {
                raw = try inflateRaw(payload, expected: uncompSize)
            } else {
                offset = payloadStart + compSize
                continue
            }
            if !name.hasSuffix("/") {
                entries.append(Entry(name: name, data: raw))
            }
            offset = payloadStart + compSize
        }
        return entries
    }

    private static func readU16(_ data: Data, _ o: Int) -> UInt16 {
        UInt16(data[o]) | (UInt16(data[o + 1]) << 8)
    }

    private static func readU32(_ data: Data, _ o: Int) -> UInt32 {
        UInt32(data[o]) | (UInt32(data[o + 1]) << 8) | (UInt32(data[o + 2]) << 16) | (UInt32(data[o + 3]) << 24)
    }

    private static func inflateRaw(_ data: Data, expected: Int) throws -> Data {
        if data.isEmpty { return Data() }
        var stream = z_stream()
        var status = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw NSError(domain: "ZipSimpleReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "解压初始化失败"])
        }
        defer { _ = inflateEnd(&stream) }

        var output = Data()
        output.reserveCapacity(max(expected, data.count))
        let chunk = 64 * 1024
        var outBuffer = [UInt8](repeating: 0, count: chunk)

        try data.withUnsafeBytes { inBuf in
            guard let base = inBuf.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)
            repeat {
                let wrote: Int = outBuffer.withUnsafeMutableBytes { outBuf in
                    stream.next_out = outBuf.bindMemory(to: Bytef.self).baseAddress!
                    stream.avail_out = uInt(chunk)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return chunk - Int(stream.avail_out)
                }
                if wrote > 0 { output.append(contentsOf: outBuffer.prefix(wrote)) }
            } while status == Z_OK
            if status != Z_STREAM_END {
                throw NSError(domain: "ZipSimpleReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "解压失败"])
            }
        }
        return output
    }
}
