import Foundation

struct TargetApp: Identifiable {
    let id: String          // primary bundle id
    let title: String       // UI 名
    let bundleIDs: [String] // 兼容多种包名
}

enum AppContainerLocator {
    static let douyin = TargetApp(
        id: "com.ss.iphone.ugc.Aweme",
        title: "抖音",
        bundleIDs: ["com.ss.iphone.ugc.Aweme"]
    )

    /// 应用详情「改机四项」可选列表：抖音 + 迁移目标
    static var identityTargets: [TargetApp] {
        [douyin] + migrateTargets
    }

    /// 迁移目标（不含抖音本体）
    static let migrateTargets: [TargetApp] = [
        TargetApp(
            id: "lite",
            title: "极速版",
            bundleIDs: [
                "com.ss.iphone.ugc.Aweme.lite",
                "com.ss.iphone.ugc.AwemeLite",
                "com.ss.iphone.ugc.live.lite"
            ]
        ),
        TargetApp(
            id: "hotsoon",
            title: "火山版",
            bundleIDs: [
                "com.ss.iphone.ugc.live",
                "com.ss.iphone.ugc.Aweme.hotsoon",
                "com.ss.iphone.ugc.Aweme.Live"
            ]
        ),
        TargetApp(
            id: "mall",
            title: "抖音商城",
            bundleIDs: [
                "com.ss.android.ugc.live.shop",
                "com.ss.iphone.ugc.aweme.mall",
                "com.ss.iphone.ugc.Aweme.mall"
            ]
        ),
        TargetApp(
            id: "dss",
            title: "抖省省",
            bundleIDs: [
                "com.ss.android.ugc.lifeservices",
                "com.ss.iphone.ugc.Aweme.dss",
                "com.ss.iphone.ugc.aweme.dss"
            ]
        ),
        TargetApp(
            id: "news",
            title: "头条",
            bundleIDs: [
                "com.ss.iphone.article.News",
                "com.ss.iphone.article.News.lite",
                "com.ss.iphone.article.NewsLite"
            ]
        ),
        TargetApp(
            id: "duoshan",
            title: "多闪",
            bundleIDs: [
                "com.ss.iphone.ugc.Duoshan",
                "com.ss.iphone.ugc.duoshan",
                "com.bytedance.ies.ugc.duoshan"
            ]
        ),
        TargetApp(
            id: "fanqie",
            title: "番茄小说",
            bundleIDs: [
                "com.dragon.read",
                "com.bytedance.novel",
                "com.ss.iphone.article.novel"
            ]
        ),
        TargetApp(
            id: "com.ss.iphone.spark",
            title: "随变",
            bundleIDs: ["com.ss.iphone.spark"]
        ),
        TargetApp(
            id: "com.ss.iphone.yumme.video",
            title: "抖音精选",
            bundleIDs: ["com.ss.iphone.yumme.video"]
        ),
        TargetApp(
            id: "com.ss.iphone.luna.music",
            title: "汽水音乐",
            bundleIDs: ["com.ss.iphone.luna.music"]
        ),
        TargetApp(
            id: "com.ss.iphone.article.video",
            title: "西瓜视频",
            bundleIDs: ["com.ss.iphone.article.video"]
        ),
        TargetApp(
            id: "com.ss.iphone.ugc.aweme.hubble",
            title: "AI抖音",
            bundleIDs: ["com.ss.iphone.ugc.aweme.hubble"]
        )
    ]

    static func locateContainer(bundleIDs: [String]) -> (bundleID: String, url: URL)? {
        // 有数据的优先，避免半刷新后的空壳
        for bid in bundleIDs {
            if let url = locateViaMetadata(bid), containerLooksPopulated(url) { return (bid, url) }
        }
        for bid in bundleIDs {
            if let url = locateViaMarkers(bid), containerLooksPopulated(url) { return (bid, url) }
        }
        for bid in bundleIDs {
            if let url = locateViaProxy(bid), containerLooksPopulated(url) { return (bid, url) }
        }
        for bid in bundleIDs {
            if let url = locateViaProxy(bid) { return (bid, url) }
        }
        for bid in bundleIDs {
            if let url = locateViaMetadata(bid) { return (bid, url) }
        }
        for bid in bundleIDs {
            if let url = locateViaMarkers(bid) { return (bid, url) }
        }
        return nil
    }

    /// 本机 Application 容器根（含 private / jbroot）
    static func applicationDataRoots() -> [String] {
        var roots = [
            "/var/mobile/Containers/Data/Application",
            "/private/var/mobile/Containers/Data/Application"
        ]
        for jb in [
            "/var/jb",
            "/private/var/jb",
            "/var/containers/Bundle/Application/.jbroot",
            FileManager.default.currentDirectoryPath
        ] {
            let p = (jb as NSString).appendingPathComponent("var/mobile/Containers/Data/Application")
            if FileManager.default.fileExists(atPath: p), !roots.contains(p) {
                roots.append(p)
            }
        }
        // RootHide：若环境变量 / 常见 symlink
        if let env = ProcessInfo.processInfo.environment["JBROOT"], !env.isEmpty {
            let p = (env as NSString).appendingPathComponent("var/mobile/Containers/Data/Application")
            if FileManager.default.fileExists(atPath: p), !roots.contains(p) {
                roots.append(p)
            }
        }
        return roots
    }

    static func containerLooksPopulated(_ url: URL) -> Bool {
        let fm = FileManager.default
        let markers = [
            "Documents/Aweme.db",
            "Documents/mmkv",
            "Documents/_ttinstall_document",
            "Library/Preferences/com.ss.iphone.ugc.Aweme.plist",
            "Library/Preferences",
            "Library/Caches"
        ]
        for rel in markers {
            let p = url.appendingPathComponent(rel)
            if fm.fileExists(atPath: p.path) {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        if let kids = try? fm.contentsOfDirectory(atPath: p.path), !kids.isEmpty { return true }
                    } else {
                        return true
                    }
                }
            }
        }
        return false
    }

    static func locateViaProxy(_ bundleID: String) -> URL? {
        guard let proxyClass = NSClassFromString("LSApplicationProxy") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("applicationProxyForIdentifier:")
        guard proxyClass.responds(to: sel) else { return nil }
        let proxy = proxyClass.perform(sel, with: bundleID)?.takeUnretainedValue() as? NSObject
        guard let proxy else { return nil }
        let urlSel = NSSelectorFromString("dataContainerURL")
        guard proxy.responds(to: urlSel),
              let url = proxy.perform(urlSel)?.takeUnretainedValue() as? URL,
              !url.path.isEmpty,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    static func locateViaMetadata(_ bundleID: String) -> URL? {
        let fm = FileManager.default
        for rootPath in applicationDataRoots() {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for dir in dirs {
                let meta = dir.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                guard
                    let data = try? Data(contentsOf: meta),
                    let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                    let identifier = plist["MCMMetadataIdentifier"] as? String,
                    identifier.caseInsensitiveCompare(bundleID) == .orderedSame
                else { continue }
                return dir
            }
        }
        return nil
    }

    /// 指纹定位（Aweme.db / mmkv / Aweme.plist）
    static func locateViaMarkers(_ bundleID: String? = nil) -> URL? {
        let fm = FileManager.default
        let wantAweme = bundleID == nil
            || (bundleID?.caseInsensitiveCompare("com.ss.iphone.ugc.Aweme") == .orderedSame)
        for rootPath in applicationDataRoots() {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for dir in dirs {
                if let bundleID {
                    let meta = dir.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                    if let data = try? Data(contentsOf: meta),
                       let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                       let id = plist["MCMMetadataIdentifier"] as? String,
                       id.caseInsensitiveCompare(bundleID) != .orderedSame {
                        // 有 metadata 且不是目标 bundle → 跳过；无 metadata 时仍可用指纹（仅抖音）
                        if !wantAweme { continue }
                        continue
                    }
                }
                let hits = [
                    "Documents/Aweme.db",
                    "Documents/mmkv",
                    "Documents/_ttinstall_document",
                    "Library/Preferences/com.ss.iphone.ugc.Aweme.plist"
                ]
                for rel in hits where fm.fileExists(atPath: dir.appendingPathComponent(rel).path) {
                    if wantAweme || bundleID != nil { return dir }
                }
            }
        }
        return nil
    }

    /// 定位诊断：扫过的 root 与目录数（写日志用）
    static func locateDiagnostics(bundleIDs: [String]) -> String {
        let fm = FileManager.default
        var lines: [String] = []
        for root in applicationDataRoots() {
            let exists = fm.fileExists(atPath: root)
            let count = (try? fm.contentsOfDirectory(atPath: root))?.count ?? -1
            lines.append("\(root) exists=\(exists) dirs=\(count)")
        }
        if let hit = locateContainer(bundleIDs: bundleIDs) {
            lines.append("hit=\(hit.bundleID) path=\(hit.url.path)")
        } else {
            lines.append("hit=nil bundles=\(bundleIDs.joined(separator: ","))")
        }
        return lines.joined(separator: "\n")
    }
}

/// 把抖音 Documents/_ttinstall_document 拷到目标 App 同名目录
enum InstallDocMigrator {
    static let relativeDir = "Documents/_ttinstall_document"

    struct Outcome {
        var ok: Bool
        var message: String
    }

    static func migrate(to target: TargetApp) -> Outcome {
        guard let srcHit = AppContainerLocator.locateContainer(bundleIDs: AppContainerLocator.douyin.bundleIDs) else {
            return Outcome(ok: false, message: "\(target.title)失败")
        }
        let srcDir = srcHit.url.appendingPathComponent(relativeDir, isDirectory: true)
        guard FileManager.default.fileExists(atPath: srcDir.path) else {
            return Outcome(ok: false, message: "\(target.title)失败")
        }

        guard let dstHit = AppContainerLocator.locateContainer(bundleIDs: target.bundleIDs) else {
            return Outcome(ok: false, message: "\(target.title)失败")
        }

        let fm = FileManager.default
        let dstDir = dstHit.url.appendingPathComponent(relativeDir, isDirectory: true)
        do {
            if fm.fileExists(atPath: dstDir.path) {
                try fm.removeItem(at: dstDir)
            }
            try fm.createDirectory(at: dstDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: srcDir, to: dstDir)
            return Outcome(ok: true, message: "\(target.title)成功")
        } catch {
            return Outcome(ok: false, message: "\(target.title)失败")
        }
    }

    static func migrateAll() -> Outcome {
        var okTitles: [String] = []
        var failTitles: [String] = []
        for t in AppContainerLocator.migrateTargets {
            if migrate(to: t).ok {
                okTitles.append(t.title)
            } else {
                failTitles.append(t.title)
            }
        }
        if failTitles.isEmpty && !okTitles.isEmpty {
            return Outcome(ok: true, message: "所有APP成功")
        }
        if okTitles.isEmpty {
            return Outcome(ok: false, message: "所有APP失败")
        }
        let okPart = okTitles.map { "\($0)成功" }.joined(separator: "\n")
        let failPart = failTitles.map { "\($0)失败" }.joined(separator: "\n")
        return Outcome(ok: false, message: "\(okPart)\n\(failPart)")
    }
}
