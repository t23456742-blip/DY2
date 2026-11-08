import Foundation

/// 迁移目标 App
struct TargetApp: Identifiable, Hashable {
    let id: String
    let title: String
    /// 同一 App 的多个可能 Bundle ID（按优先级排列）
    let bundleIDs: [String]
    /// 角标，例如「新」
    let badge: String?

    init(id: String, title: String, bundleIDs: [String], badge: String? = nil) {
        self.id = id
        self.title = title
        self.bundleIDs = bundleIDs
        self.badge = badge
    }
}

enum AppContainerLocator {
    /// 票据来源：抖音
    static let sourceApp = TargetApp(
        id: "douyin",
        title: "抖音",
        bundleIDs: ["com.ss.iphone.ugc.Aweme"]
    )

    /// 全部迁移目标（红果排第一，作为主推）
    static let allTargets: [TargetApp] = [
        TargetApp(
            id: "hongguo",
            title: "红果免费短剧",
            bundleIDs: [
                "com.phoenix.read",
                "com.phoenix.read.ios",
                "com.phoenix.read.lite"
            ],
            badge: "新"
        ),
        TargetApp(
            id: "tomato",
            title: "番茄小说",
            bundleIDs: [
                "com.dragon.read",
                "com.dragon.read.lite"
            ]
        ),
        TargetApp(
            id: "news",
            title: "今日头条",
            bundleIDs: [
                "com.ss.iphone.article.News",
                "com.ss.iphone.article.News.lite",
                "com.ss.iphone.article.NewsLite"
            ]
        ),
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
            id: "duoshan",
            title: "多闪",
            bundleIDs: [
                "com.ss.iphone.ugc.Duoshan",
                "com.ss.iphone.ugc.duoshan",
                "com.bytedance.ies.ugc.duoshan"
            ]
        )
    ]

    /// 找到目标 App 的 Data 容器目录
    static func locateContainer(bundleIDs: [String]) -> (bundleID: String, url: URL)? {
        for bid in bundleIDs {
            if let url = locateViaProxy(bid) { return (bid, url) }
        }
        for bid in bundleIDs {
            if let url = locateViaMetadata(bid) { return (bid, url) }
        }
        return nil
    }

    static func isInstalled(_ app: TargetApp) -> Bool {
        locateContainer(bundleIDs: app.bundleIDs) != nil
    }

    /// 私有 API：LSApplicationProxy
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

    /// 兜底：扫描容器元数据 plist
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

/// 票据目录迁移器：抖音 Documents/_ttinstall_document → 目标 App 同名目录
enum InstallDocMigrator {
    /// 票据目录名（各 App 一致）
    static let dirName = "_ttinstall_document"

    /// 来源相对路径候选（部分版本可能落在 Library 下）
    static let sourceCandidates = [
        "Documents/_ttinstall_document",
        "Library/_ttinstall_document",
        "Library/Caches/_ttinstall_document"
    ]

    struct Outcome: Identifiable {
        let id = UUID()
        let title: String
        let ok: Bool
        let detail: String
    }

    /// 定位抖音票据源目录
    static func locateSource() -> URL? {
        guard let hit = AppContainerLocator.locateContainer(bundleIDs: AppContainerLocator.sourceApp.bundleIDs) else {
            return nil
        }
        for rel in sourceCandidates {
            let url = hit.url.appendingPathComponent(rel, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 是否已安装（供 UI 显示）
    static func installedTargets() -> [TargetApp] {
        AppContainerLocator.allTargets.filter { AppContainerLocator.isInstalled($0) }
    }

    /// 迁移到单个目标
    static func migrate(to target: TargetApp) -> Outcome {
        guard let src = locateSource() else {
            return Outcome(title: target.title, ok: false, detail: "未检测到抖音票据目录")
        }
        guard let dstHit = AppContainerLocator.locateContainer(bundleIDs: target.bundleIDs) else {
            return Outcome(title: target.title, ok: false, detail: "未安装")
        }

        let fm = FileManager.default
        let dst = dstHit.url
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(dirName, isDirectory: true)

        do {
            try replaceItem(at: src, to: dst)
        } catch {
            return Outcome(title: target.title, ok: false, detail: "写入失败")
        }

        // 若目标 App 已存在 Library 下的同名目录，一并覆盖（兼容不同落盘位置，如红果部分版本）
        for rel in ["Library/_ttinstall_document", "Library/Caches/_ttinstall_document"] {
            let extra = dstHit.url.appendingPathComponent(rel, isDirectory: true)
            if fm.fileExists(atPath: extra.path) {
                try? replaceItem(at: src, to: extra)
            }
        }

        let count = countItems(at: dst)
        guard count > 0 else {
            return Outcome(title: target.title, ok: false, detail: "写入后为空")
        }
        return Outcome(title: target.title, ok: true, detail: "成功 · \(count) 个文件")
    }

    /// 一键迁移：只处理已安装的 App，跳过未安装的
    static func migrateInstalled() -> [Outcome] {
        let targets = installedTargets()
        guard !targets.isEmpty else {
            return [Outcome(title: "全部", ok: false, detail: "未检测到已安装的目标 App")]
        }
        return targets.map { migrate(to: $0) }
    }

    // MARK: - 文件操作

    /// 原子替换：先删旧目录，再复制；失败时退回逐项复制
    private static func replaceItem(at src: URL, to dst: URL) throws {
        let fm = FileManager.default
        let parent = dst.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)

        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }

        do {
            try fm.copyItem(at: src, to: dst)
        } catch {
            // 兜底：逐个文件复制（遇到扩展属性 / 权限异常时更稳）
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let items = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                let to = dst.appendingPathComponent(item.lastPathComponent)
                try? fm.removeItem(at: to)
                try? fm.copyItem(at: item, to: to)
            }
            let remaining = (try? fm.contentsOfDirectory(atPath: dst.path)) ?? []
            if remaining.isEmpty { throw error }
        }
    }

    /// 递归统计文件/目录数量
    private static func countItems(at url: URL) -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return fm.fileExists(atPath: url.path) ? 1 : 0
        }
        var count = 0
        for _ in walker { count += 1 }
        return count
    }
}
