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

    /// 迁移目标（不含抖音本体）
    static let migrateTargets: [TargetApp] = [
        TargetApp(
            id: "lite",
            title: "抖音极速版",
            bundleIDs: [
                "com.ss.iphone.ugc.Aweme.lite",
                "com.ss.iphone.ugc.AwemeLite",
                "com.ss.iphone.ugc.live.lite"
            ]
        ),
        TargetApp(
            id: "hotsoon",
            title: "抖音火山版",
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
        )
    ]

    static func locateContainer(bundleIDs: [String]) -> (bundleID: String, url: URL)? {
        for bid in bundleIDs {
            if let url = locateViaProxy(bid) { return (bid, url) }
        }
        for bid in bundleIDs {
            if let url = locateViaMetadata(bid) { return (bid, url) }
        }
        return nil
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
        let roots = [
            "/var/mobile/Containers/Data/Application",
            "/private/var/mobile/Containers/Data/Application"
        ]
        let fm = FileManager.default
        for rootPath in roots {
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
            return Outcome(ok: false, message: "失败")
        }
        let srcDir = srcHit.url.appendingPathComponent(relativeDir, isDirectory: true)
        guard FileManager.default.fileExists(atPath: srcDir.path) else {
            return Outcome(ok: false, message: "失败")
        }

        guard let dstHit = AppContainerLocator.locateContainer(bundleIDs: target.bundleIDs) else {
            return Outcome(ok: false, message: "失败")
        }

        let fm = FileManager.default
        let dstDir = dstHit.url.appendingPathComponent(relativeDir, isDirectory: true)
        do {
            if fm.fileExists(atPath: dstDir.path) {
                try fm.removeItem(at: dstDir)
            }
            try fm.createDirectory(at: dstDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: srcDir, to: dstDir)
            return Outcome(ok: true, message: "成功")
        } catch {
            return Outcome(ok: false, message: "失败")
        }
    }

    static func migrateAll() -> Outcome {
        var okCount = 0
        for t in AppContainerLocator.migrateTargets {
            if migrate(to: t).ok { okCount += 1 }
        }
        if okCount == 0 {
            return Outcome(ok: false, message: "失败")
        }
        return Outcome(ok: true, message: "成功")
    }
}
