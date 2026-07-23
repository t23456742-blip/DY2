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

    struct BackupSummary: Sendable {
        var ok: Bool = false
        var copied: Int = 0
        var failed: Int = 0
        var backupRoot: String = ""
        var error: String?
    }

    static let awemeBundleID = "com.ss.iphone.ugc.Aweme"

    private static let protectedNames: Set<String> = [
        ".com.apple.mobile_container_manager.metadata.plist"
    ]

    /// Documents 下整夹保留（截图精简结构 + 参考包目录）；其中 _ttinstall_document 内文件一律不删
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

    /// 移机/粘贴相关：整夹保留
    static let libraryKeepFolders: [String] = [
        "Library/Preferences",
        "Library/SyncedPreferences"
    ]

    /// 抖音商城 + 搜索：强制整夹保留（比精简包更宽，保证商城可用）
    static let mallSearchKeepFolders: [String] = [
        "Library/Pitaya",                 // 商城/搜索前端包、策略模型
        "Library/WebKit",                 // 商城 H5 / 搜索 WebView
        "Library/BDXBridgeAuthConfig",    // 杂交/Lynx 桥鉴权
        "Library/AWEFileKit",             // 资源通道元数据
        "Library/Application Support",    // gurd：ecommerce / gecko / morphling_ecom / lynx
        "Library/HTTPStorages",
        "Library/Cookies",
        "Library/Preferences",
        "Library/SyncedPreferences",
        "Documents/mmkv",
        "Documents/com.bytedance.ies",
        "Documents/_ttinstall_document"
    ]

    let keepList: Set<String>
    /// 从 keep_paths 推导的整夹前缀（Documents/X、Library/X、tmp/X）
    /// 解决参考包里 hash 路径与手机不一致时被误删的问题
    let keepDirPrefixes: Set<String>

    init(keepListURL: URL? = nil) {
        if let url = keepListURL ?? Bundle.main.url(forResource: "keep_paths", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            keepList = Set(
                text
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/") }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            )
        } else {
            keepList = []
        }
        keepDirPrefixes = Self.buildKeepDirPrefixes(from: keepList)
    }

    /// 从白名单文件路径提取「二级目录」整夹保留，例如 Library/AWEIMRoot、Library/Application Support
    private static func buildKeepDirPrefixes(from keepList: Set<String>) -> Set<String> {
        var dirs = Set<String>()
        dirs.formUnion(documentsKeepFolders)
        dirs.formUnion(libraryKeepFolders)
        dirs.formUnion(mallSearchKeepFolders)
        for p in keepList {
            let parts = p.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { continue }
            let root = parts[0]
            guard root == "Documents" || root == "Library" || root == "tmp" else { continue }
            // Documents/Aweme.db 这类根文件不当作目录前缀
            if parts.count == 2, root == "Documents", documentsKeepFiles.contains(p) {
                continue
            }
            if parts.count == 2, root == "Library", p.hasSuffix(".dat") {
                continue
            }
            dirs.insert(root + "/" + parts[1])
        }
        return dirs
    }

    /// 商城/搜索相关路径：任意规则模式下强制保留
    static func isMallSearchProtected(_ rel: String) -> Bool {
        let rel = rel.replacingOccurrences(of: "\\", with: "/")
        for folder in mallSearchKeepFolders {
            if rel == folder || rel.hasPrefix(folder + "/") {
                return true
            }
        }
        let lower = rel.lowercased()
        // Caches 不全留，只留商城/搜索必要子树
        if lower.hasPrefix("library/caches/aweecom") { return true }
        if lower.hasPrefix("library/caches/webkit") { return true }
        if lower.contains("/ecommerce") || lower.contains("ecommerce_") { return true }
        if lower.contains("morphling_ecom") { return true }
        if lower.contains("gecko_core") || lower.contains("/gecko/") { return true }
        if lower.contains("ecom_search")
            || lower.contains("aweme_ecom_search")
            || lower.contains("general_search")
            || lower.contains("mall_search")
            || lower.contains("ecom_mall") {
            return true
        }
        if lower.contains("/lynx") || lower.contains("lynx-") || lower.contains("annie") {
            // 仅限商城资源相关根目录，避免误留无关临时文件
            if lower.hasPrefix("library/application support/")
                || lower.hasPrefix("library/pitaya/")
                || lower.hasPrefix("library/caches/") {
                return true
            }
        }
        return false
    }

    /// 是否应保留
    func shouldKeep(relativePath rel: String) -> Bool {
        let rel = rel.replacingOccurrences(of: "\\", with: "/")
        if Self.protectedNames.contains((rel as NSString).lastPathComponent) {
            return true
        }
        // 安装票据目录：永远不删
        if rel == "Documents/_ttinstall_document"
            || rel.hasPrefix("Documents/_ttinstall_document/") {
            return true
        }
        // 抖音商城 + 搜索：永远不删
        if Self.isMallSearchProtected(rel) {
            return true
        }

        let store = RulesStore.shared
        return store.isKeptByActiveRules(rel) { self.defaultShouldKeep(relativePath: $0) }
    }

    func defaultShouldKeep(relativePath rel: String) -> Bool {
        let rel = rel.replacingOccurrences(of: "\\", with: "/")
        if Self.isMallSearchProtected(rel) {
            return true
        }
        // 1) 参考包推导的整夹 + 内置整夹
        for folder in keepDirPrefixes {
            if rel == folder || rel.hasPrefix(folder + "/") {
                return true
            }
        }
        // 2) Documents 根文件
        if Self.documentsKeepFiles.contains(rel) {
            return true
        }
        // 3) 白名单精确路径
        if keepList.contains(rel) {
            return true
        }
        return false
    }

    /// 默认规则勾选项（供规则页展示）
    static func defaultCheckedPaths() -> Set<String> {
        Set(documentsKeepFolders)
            .union(documentsKeepFiles)
            .union(libraryKeepFolders)
            .union(mallSearchKeepFolders)
    }

    /// 含 keep_paths 目录前缀的完整默认勾选
    func defaultCheckedPathsFull() -> Set<String> {
        Self.defaultCheckedPaths().union(keepDirPrefixes).union(Self.mallSearchKeepFolders)
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
            pruneEmptyDirs(under: container)
        }
        return summary
    }

    /// 清理前备份：整包抖音容器 → /private/var/mobile/Media/dybf（7z/zip，尽量最小）
    func backupFullContainer(_ container: URL) -> BackupSummary {
        let r = ContainerArchiveBackup.backupEntireContainer(container)
        var summary = BackupSummary()
        summary.ok = r.ok
        summary.copied = r.fileCount
        summary.backupRoot = r.archivePath
        summary.error = r.error
        return summary
    }

    private func pruneEmptyDirs(under container: URL) {
        pruneEmptyDirectories(under: container)
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
