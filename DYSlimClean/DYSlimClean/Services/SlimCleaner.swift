import Foundation

/// Scan / clean Douyin (Aweme) sandbox against H9-20-土 keep list.
/// Requires TrollStore tipa with toolbox-equivalent entitlements (no-sandbox + AppDataContainers).
/// Dopamine RootHide: app data containers stay under /var/mobile/Containers — no /var/jb path needed.
final class SlimCleaner: @unchecked Sendable {
    struct ScanResult: Sendable {
        var container: URL?
        var total: Int = 0
        var keepHits: Int = 0
        var extras: [URL] = []
        var extraBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var keepBytes: Int64 = 0
        var error: String?
    }

    struct DeleteSummary: Sendable {
        var deleted: Int = 0
        var failed: Int = 0
        var freedBytes: Int64 = 0
    }

    static let awemeBundleID = "com.ss.iphone.ugc.Aweme"

    private static let protectedNames: Set<String> = [
        ".com.apple.mobile_container_manager.metadata.plist"
    ]

    /// Documents 下整夹保留（截图精简结构）；其中 _ttinstall_document 内文件一律不删
    static let documentsKeepFolders: [String] = [
        "Documents/_bdticketguard_document",
        "Documents/_ttinstall_document",
        "Documents/AWEPublishedImages",
        "Documents/com.bytedance.ies",
        "Documents/com.bytedance.ies-effects-cache",
        "Documents/FeedbackRecorder",
        "Documents/IESPlayTimePredictModel",
        "Documents/mmkv",
        "Documents/StudioAudit",
        "Documents/TTAdSplashSimpleCache"
    ]

    /// Documents 根目录需保留的文件
    static let documentsKeepFiles: Set<String> = [
        "Documents/Aweme.db",
        "Documents/Aweme.db-backup",
        "Documents/Aweme.db-shm",
        "Documents/Aweme.db-wal",
        "Documents/db.sqlite3",
        "Documents/hostcache_sync_v1",
        "Documents/hostcache_v1",
        "Documents/lsdata.plist",
        "Documents/server.json",
        "Documents/tt_net_config.config",
        "Documents/ttaccount_token_guard_data.archiver",
        "Documents/ttaccountSDKUserInfo.archiver"
    ]

    /// 移机/粘贴相关：整夹保留，避免恢复后复制粘贴异常
    static let libraryKeepFolders: [String] = [
        "Library/Preferences",
        "Library/SyncedPreferences"
    ]

    let keepList: Set<String>

    init(keepListURL: URL? = nil) {
        if let url = keepListURL ?? Bundle.main.url(forResource: "keep_paths", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            keepList = Set(
                text
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            )
        } else {
            keepList = []
        }
    }

    /// 是否应保留
    func shouldKeep(relativePath rel: String) -> Bool {
        if Self.protectedNames.contains((rel as NSString).lastPathComponent) {
            return true
        }
        // 安装票据目录：永远不删
        if rel == "Documents/_ttinstall_document"
            || rel.hasPrefix("Documents/_ttinstall_document/") {
            return true
        }

        let store = RulesStore.shared
        if store.useCustomRules {
            return store.isKeptByCustom(rel)
        }
        return defaultShouldKeep(relativePath: rel)
    }

    func defaultShouldKeep(relativePath rel: String) -> Bool {
        for folder in Self.documentsKeepFolders {
            if rel == folder || rel.hasPrefix(folder + "/") {
                return true
            }
        }
        for folder in Self.libraryKeepFolders {
            if rel == folder || rel.hasPrefix(folder + "/") {
                return true
            }
        }
        if Self.documentsKeepFiles.contains(rel) {
            return true
        }
        return keepList.contains(rel)
    }

    /// 默认规则勾选项（供规则页展示）
    static func defaultCheckedPaths() -> Set<String> {
        Set(documentsKeepFolders)
            .union(documentsKeepFiles)
            .union(libraryKeepFolders)
    }

    func locateAwemeContainer() -> URL? {
        if let url = locateViaApplicationProxy() { return url }
        if let url = locateViaContainerMetadata() { return url }
        return locateViaMarkers()
    }

    /// Same SPI the toolbox uses: LSApplicationProxy.dataContainerURL
    private func locateViaApplicationProxy() -> URL? {
        guard let proxyClass = NSClassFromString("LSApplicationProxy") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("applicationProxyForIdentifier:")
        guard proxyClass.responds(to: sel) else { return nil }

        let proxy = proxyClass.perform(sel, with: Self.awemeBundleID)?.takeUnretainedValue() as? NSObject
        guard let proxy else { return nil }

        let urlSel = NSSelectorFromString("dataContainerURL")
        guard proxy.responds(to: urlSel),
              let url = proxy.perform(urlSel)?.takeUnretainedValue() as? URL,
              !url.path.isEmpty,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    private func locateViaContainerMetadata() -> URL? {
        let roots = [
            "/var/mobile/Containers/Data/Application",
            "/private/var/mobile/Containers/Data/Application"
        ]
        let fm = FileManager.default
        for rootPath in roots {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard let dirs = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }

            for dir in dirs {
                let meta = dir.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                guard
                    let data = try? Data(contentsOf: meta),
                    let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                    let identifier = plist["MCMMetadataIdentifier"] as? String,
                    identifier == Self.awemeBundleID
                else { continue }
                return dir
            }
        }
        return nil
    }

    /// Last resort: Aweme.db / mmkv fingerprints inside data containers.
    private func locateViaMarkers() -> URL? {
        let roots = [
            "/var/mobile/Containers/Data/Application",
            "/private/var/mobile/Containers/Data/Application"
        ]
        let fm = FileManager.default
        for rootPath in roots {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: []) else { continue }
            for dir in dirs {
                let awemeDB = dir.appendingPathComponent("Documents/Aweme.db")
                let mmkv = dir.appendingPathComponent("Documents/mmkv")
                if fm.fileExists(atPath: awemeDB.path) || fm.fileExists(atPath: mmkv.path) {
                    return dir
                }
            }
        }
        return nil
    }

    func scan() -> ScanResult {
        var result = ScanResult()
        if keepList.isEmpty {
            result.error = "白名单文件未打进软件包，请重新编译安装"
            return result
        }
        guard let container = locateAwemeContainer() else {
            result.error = "未找到抖音数据容器（须用巨魔安装本软件，且手机已安装抖音）"
            return result
        }
        result.container = container

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: container,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            result.error = "无法读取抖音容器（权限不足，请确认已用巨魔安装）"
            return result
        }

        let containerPath = container.standardizedFileURL.path
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values?.isDirectory == true { continue }
            if Self.protectedNames.contains(item.lastPathComponent) { continue }

            let full = item.standardizedFileURL.path
            guard full.hasPrefix(containerPath) else { continue }
            var rel = String(full.dropFirst(containerPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            rel = rel.replacingOccurrences(of: "\\", with: "/")

            result.total += 1
            let size = Int64(values?.fileSize ?? 0)
            result.totalBytes += size
            if shouldKeep(relativePath: rel) {
                result.keepHits += 1
                result.keepBytes += size
            } else {
                result.extras.append(item)
                result.extraBytes += size
            }
        }
        return result
    }

    func delete(urls: [URL]) -> DeleteSummary {
        var summary = DeleteSummary()
        let fm = FileManager.default
        for url in urls {
            if Self.protectedNames.contains(url.lastPathComponent) {
                summary.failed += 1
                continue
            }
            // 双重保险：删除前再判一次保留规则
            if let container = locateAwemeContainer() {
                let containerPath = container.standardizedFileURL.path
                let full = url.standardizedFileURL.path
                if full.hasPrefix(containerPath) {
                    var rel = String(full.dropFirst(containerPath.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    rel = rel.replacingOccurrences(of: "\\", with: "/")
                    if shouldKeep(relativePath: rel) {
                        summary.failed += 1
                        continue
                    }
                }
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            // Ensure writable then remove (RootHide / sandbox leftovers)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            do {
                try fm.removeItem(at: url)
                summary.deleted += 1
                summary.freedBytes += size
            } catch {
                // Retry after clearing immutable if present
                var attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
                if let num = attrs[.immutable] as? NSNumber, num.boolValue {
                    attrs[.immutable] = false
                    try? fm.setAttributes(attrs, ofItemAtPath: url.path)
                }
                do {
                    try fm.removeItem(at: url)
                    summary.deleted += 1
                    summary.freedBytes += size
                } catch {
                    summary.failed += 1
                }
            }
        }
        // Prune empty directories under Documents/Library/tmp (not in keep list as files)
        if let container = locateAwemeContainer() {
            pruneEmptyDirectories(under: container)
        }
        return summary
    }

    private func pruneEmptyDirectories(under root: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return }

        var dirs: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { dirs.append(item) }
        }
        // Deepest first
        dirs.sort { $0.pathComponents.count > $1.pathComponents.count }
        for dir in dirs {
            if Self.protectedNames.contains(dir.lastPathComponent) { continue }
            if let kids = try? fm.contentsOfDirectory(atPath: dir.path), kids.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
    }
}
