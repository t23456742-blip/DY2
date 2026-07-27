import Foundation

/// 雷神 Thor 备份索引
/// 优先：`/private/var/mobile/Media/Thor/Backups/backup_index.plist`
/// 字段：name / createdAt / folderPath / sizeBytes / bundleIDs / appNames
enum ThorBackupIndex {
    struct Entry: Identifiable, Sendable {
        var id: String { resolvedPath + "|" + name }
        var name: String          // 备注（常为「抖音号-密码」）
        var createdAt: String
        /// 索引里的原始 folderPath
        var folderPath: String
        /// 实际可访问路径（补 private / Backups 根 / 仅文件夹名）
        var resolvedPath: String
        var bundleIDs: [String]
        var appNames: [String]
        var sizeBytes: Int64
        var indexSource: String

        var sizeText: String {
            sizeBytes > 0 ? ContainerDiskSize.format(sizeBytes) : "—"
        }

        var displayPath: String {
            resolvedPath.isEmpty ? folderPath : resolvedPath
        }
    }

    /// 索引文件候选（**Media/Thor/Backups 优先**，避免误读旧的 /var/mobile/Thor/）
    static let indexCandidates = [
        "/private/var/mobile/Media/Thor/Backups/backup_index.plist",
        "/var/mobile/Media/Thor/Backups/backup_index.plist",
        "/private/var/mobile/Media/Thor/backup_index.plist",
        "/var/mobile/Media/Thor/backup_index.plist",
        "/private/var/mobile/Thor/Backups/backup_index.plist",
        "/var/mobile/Thor/Backups/backup_index.plist",
        "/private/var/mobile/Thor/backup_index.plist",
        "/var/mobile/Thor/backup_index.plist"
    ]

    static let backupRoots = [
        "/private/var/mobile/Media/Thor/Backups",
        "/var/mobile/Media/Thor/Backups",
        "/private/var/mobile/Thor/Backups",
        "/var/mobile/Thor/Backups"
    ]

    /// 加载全部备份（合并多索引去重，按时间新→旧）
    static func load() -> [Entry] {
        let fm = FileManager.default
        var byKey: [String: Entry] = [:]
        var loadedAnyIndex = false

        for indexPath in indexCandidates where fm.fileExists(atPath: indexPath) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath)),
                  let arr = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [[String: Any]]
            else { continue }
            loadedAnyIndex = true
            for dict in arr {
                guard var entry = parse(dict, indexSource: indexPath) else { continue }
                entry.resolvedPath = resolveFolderPath(entry.folderPath) ?? entry.folderPath
                if entry.sizeBytes <= 0 {
                    entry.sizeBytes = measureSizeIfNeeded(entry.resolvedPath)
                }
                let key = dedupeKey(entry)
                // 优先保留：有体积、路径真实存在、来自 Backups 索引
                if let old = byKey[key] {
                    byKey[key] = prefer(entry, over: old)
                } else {
                    byKey[key] = entry
                }
            }
            // 已读到 Media/Thor/Backups 索引则不再读旧 Thor 根索引（防止脏数据覆盖）
            if indexPath.contains("/Media/Thor/Backups/") {
                break
            }
        }

        if !loadedAnyIndex {
            for entry in scanBackupFolders() {
                let key = dedupeKey(entry)
                if byKey[key] == nil { byKey[key] = entry }
            }
        }

        return byKey.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.name > rhs.name
        }
    }

    private static func prefer(_ a: Entry, over b: Entry) -> Entry {
        let aOK = FileManager.default.fileExists(atPath: a.resolvedPath)
        let bOK = FileManager.default.fileExists(atPath: b.resolvedPath)
        if aOK != bOK { return aOK ? a : b }
        if (a.sizeBytes > 0) != (b.sizeBytes > 0) { return a.sizeBytes > 0 ? a : b }
        if a.indexSource.contains("/Media/Thor/Backups/") != b.indexSource.contains("/Media/Thor/Backups/") {
            return a.indexSource.contains("/Media/Thor/Backups/") ? a : b
        }
        return a.sizeBytes >= b.sizeBytes ? a : b
    }

    private static func dedupeKey(_ e: Entry) -> String {
        let base = URL(fileURLWithPath: e.resolvedPath.isEmpty ? e.folderPath : e.resolvedPath).lastPathComponent
        if !base.isEmpty { return base.lowercased() }
        return e.name.lowercased()
    }

    private static func parse(_ dict: [String: Any], indexSource: String) -> Entry? {
        let name = stringValue(dict["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folder = stringValue(dict["folderPath"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? stringValue(dict["path"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? stringValue(dict["folder"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        // 过滤明显坏路径（仅 /var/mobile 这种）
        guard !folder.isEmpty else { return nil }
        let trimmed = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed == "var/mobile" || trimmed == "private/var/mobile" || folder == "/var/mobile" || folder == "/private/var/mobile" {
            return nil
        }

        let created = stringValue(dict["createdAt"]) ?? stringValue(dict["createAt"]) ?? ""
        let bundles = stringArray(dict["bundleIDs"]) ?? stringArray(dict["bundleIds"]) ?? []
        let apps = stringArray(dict["appNames"]) ?? []
        let size = int64Value(dict["sizeBytes"])
            ?? int64Value(dict["size"])
            ?? int64Value(dict["totalSize"])
            ?? int64Value(dict["folderSize"])
            ?? 0

        let stamp = URL(fileURLWithPath: folder).lastPathComponent
        return Entry(
            name: name.isEmpty ? stamp : name,
            createdAt: created,
            folderPath: folder,
            resolvedPath: folder,
            bundleIDs: bundles,
            appNames: apps,
            sizeBytes: size,
            indexSource: indexSource
        )
    }

    /// 把索引里的 folderPath 解析成真实可访问目录
    static func resolveFolderPath(_ raw: String) -> String? {
        let fm = FileManager.default
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        var candidates: [String] = [path]
        if path.hasPrefix("/private/") {
            candidates.append(String(path.dropFirst("/private".count)))
        } else if path.hasPrefix("/") {
            candidates.append("/private" + path)
        }

        let stamp = URL(fileURLWithPath: path).lastPathComponent
        if !stamp.isEmpty, stamp != path, !stamp.contains("/") {
            for root in backupRoots {
                candidates.append((root as NSString).appendingPathComponent(stamp))
            }
        }

        // 若只有时间戳文件夹名
        if !path.contains("/") {
            for root in backupRoots {
                candidates.append((root as NSString).appendingPathComponent(path))
            }
        }

        // jbroot 常见前缀
        let jbPrefixes = [
            "/var/containers/Bundle/Application/.jbroot",
            "/private/var/containers/Bundle/Application/.jbroot"
        ]
        var more: [String] = []
        for c in candidates {
            for pre in jbPrefixes {
                if c.hasPrefix("/") {
                    more.append(pre + c)
                }
            }
        }
        candidates.append(contentsOf: more)

        for c in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c, isDirectory: &isDir), isDir.boolValue {
                return c
            }
        }
        // 找不到也返回 private 规范化路径，便于日志
        if path.hasPrefix("/var/") { return "/private" + path }
        return path
    }

    private static func measureSizeIfNeeded(_ path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return 0 }
        // 只量备份包体积；大目录可能慢，限制枚举预算
        return ContainerDiskSize.byteSize(of: URL(fileURLWithPath: path), budget: 50_000)
    }

    private static func scanBackupFolders() -> [Entry] {
        let fm = FileManager.default
        var out: [Entry] = []
        var seen = Set<String>()
        for root in backupRoots {
            guard let kids = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in kids {
                if name == "backup_index.plist" || name.hasPrefix(".") { continue }
                let path = (root as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                let key = name.lowercased()
                if seen.contains(key) { continue }
                seen.insert(key)
                let size = ContainerDiskSize.byteSize(of: URL(fileURLWithPath: path), budget: 50_000)
                out.append(Entry(
                    name: name,
                    createdAt: "",
                    folderPath: path,
                    resolvedPath: path,
                    bundleIDs: [],
                    appNames: [],
                    sizeBytes: size,
                    indexSource: root
                ))
            }
        }
        return out
    }

    /// 在备份包内找抖音数据根：`{backup}/com.ss.iphone.ugc.Aweme`
    static func findAwemeDataRoot(inBackup folderPath: String) -> URL? {
        let fm = FileManager.default
        let resolved = resolveFolderPath(folderPath) ?? folderPath
        let root = URL(fileURLWithPath: resolved, isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return nil }

        let preferred = [
            root.appendingPathComponent("com.ss.iphone.ugc.Aweme"),
            root.appendingPathComponent("com.ss.iphone.ugc.aweme")
        ]
        for u in preferred {
            if looksLikeAwemeContainer(u) || hasSandboxShape(u) {
                return u
            }
        }

        if looksLikeAwemeContainer(root) || hasSandboxShape(root) {
            return root
        }

        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        var budget = 6000
        while let u = en.nextObject() as? URL {
            budget -= 1
            if budget <= 0 { break }
            let name = u.lastPathComponent
            if name.caseInsensitiveCompare("com.ss.iphone.ugc.Aweme") == .orderedSame {
                if looksLikeAwemeContainer(u) || hasSandboxShape(u) { return u }
            }
            if name == "Aweme.db" || name == "com.ss.iphone.ugc.Aweme.plist" {
                let container = u.deletingLastPathComponent().deletingLastPathComponent()
                if looksLikeAwemeContainer(container) || hasSandboxShape(container) { return container }
            }
        }
        return nil
    }

    private static func hasSandboxShape(_ url: URL) -> Bool {
        let fm = FileManager.default
        let docs = url.appendingPathComponent("Documents").path
        let lib = url.appendingPathComponent("Library").path
        return fm.fileExists(atPath: docs) && fm.fileExists(atPath: lib)
    }

    private static func looksLikeAwemeContainer(_ url: URL) -> Bool {
        let fm = FileManager.default
        let checks = [
            "Documents/Aweme.db",
            "Documents/mmkv",
            "Documents/_ttinstall_document",
            "Library/Preferences/com.ss.iphone.ugc.Aweme.plist"
        ]
        return checks.contains { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    // MARK: - Plist value helpers

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func stringArray(_ any: Any?) -> [String]? {
        if let a = any as? [String] { return a }
        if let a = any as? [Any] { return a.compactMap { stringValue($0) } }
        return nil
    }

    private static func int64Value(_ any: Any?) -> Int64? {
        if let n = any as? NSNumber { return n.int64Value }
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        if let i = any as? UInt64 { return Int64(clamping: i) }
        if let d = any as? Double { return Int64(d) }
        if let s = any as? String, let v = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return v }
        return nil
    }
}
