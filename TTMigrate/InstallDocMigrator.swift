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
                "com.phoenix.video",
                "com.phoenix.video.lite",
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

    static let containerRoots = [
        "/var/mobile/Containers/Data/Application",
        "/private/var/mobile/Containers/Data/Application"
    ]

    // MARK: - 通道 1：LSApplicationProxy

    static func locateViaProxy(_ bundleID: String) -> URL? {
        guard let proxyClass = NSClassFromString("LSApplicationProxy") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("applicationProxyForIdentifier:")
        guard proxyClass.responds(to: sel) else { return nil }
        let proxy = proxyClass.perform(sel, with: bundleID)?.takeUnretainedValue() as? NSObject
        guard let proxy else { return nil }
        return dataContainerURL(of: proxy)
    }

    // MARK: - 通道 2：LSApplicationWorkspace（枚举全部已装 App）

    static func locateViaWorkspace(_ bundleID: String) -> URL? {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return nil }
        let wsSel = NSSelectorFromString("defaultWorkspace")
        guard wsClass.responds(to: wsSel),
              let ws = wsClass.perform(wsSel)?.takeUnretainedValue() as? NSObject
        else { return nil }
        let allSel = NSSelectorFromString("allInstalledApplications")
        guard ws.responds(to: allSel),
              let raw = ws.perform(allSel)?.takeUnretainedValue() as? [AnyObject]
        else { return nil }

        for case let proxy as NSObject in raw {
            guard let bid = stringValue(proxy, "bundleIdentifier"),
                  bid.caseInsensitiveCompare(bundleID) == .orderedSame
            else { continue }
            if let url = dataContainerURL(of: proxy) { return url }
        }
        return nil
    }

    // MARK: - 通道 3：容器元数据索引（含多开/克隆包前缀匹配）

    /// bundleID(小写) -> Data 容器目录
    static func containerIndex() -> [String: URL] {
        var index: [String: URL] = [:]
        let fm = FileManager.default
        for rootPath in containerRoots {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for dir in dirs {
                let meta = dir.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                guard
                    let data = try? Data(contentsOf: meta),
                    let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                    let identifier = plist["MCMMetadataIdentifier"] as? String,
                    !identifier.isEmpty
                else { continue }
                let key = identifier.lowercased()
                if index[key] == nil { index[key] = dir }
            }
        }
        return index
    }

    /// 精确 → 前缀（Crane 多开 / 渠道包 bundleID 形如 com.phoenix.video.clone1）
    static func locateViaIndex(_ bundleIDs: [String], index: [String: URL]) -> URL? {
        for bid in bundleIDs {
            if let url = index[bid.lowercased()] { return url }
        }
        for bid in bundleIDs {
            let prefix = bid.lowercased() + "."
            if let hit = index.first(where: { $0.key.hasPrefix(prefix) })?.value { return hit }
        }
        return nil
    }

    // MARK: - 统一入口（三通道依次尝试）

    static func locateContainer(bundleIDs: [String], index: [String: URL]? = nil) -> (bundleID: String, url: URL)? {
        for bid in bundleIDs {
            if let url = locateViaProxy(bid) { return (bid, url) }
        }
        for bid in bundleIDs {
            if let url = locateViaWorkspace(bid) { return (bid, url) }
        }
        let idx = index ?? containerIndex()
        for bid in bundleIDs {
            if let url = idx[bid.lowercased()] { return (bid, url) }
        }
        for bid in bundleIDs {
            let prefix = bid.lowercased() + "."
            if let hit = idx.first(where: { $0.key.hasPrefix(prefix) }) {
                return (hit.key, hit.value)
            }
        }
        return nil
    }

    static func isInstalled(_ app: TargetApp, index: [String: URL]? = nil) -> Bool {
        locateContainer(bundleIDs: app.bundleIDs, index: index) != nil
    }

    // MARK: - 私有工具

    private static func dataContainerURL(of proxy: NSObject) -> URL? {
        let urlSel = NSSelectorFromString("dataContainerURL")
        guard proxy.responds(to: urlSel),
              let url = proxy.perform(urlSel)?.takeUnretainedValue() as? URL,
              !url.path.isEmpty,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    private static func stringValue(_ proxy: NSObject, _ selector: String) -> String? {
        let sel = NSSelectorFromString(selector)
        guard proxy.responds(to: sel) else { return nil }
        return proxy.perform(sel)?.takeUnretainedValue() as? String
    }

    // MARK: - 诊断报告

    static func diagnosisText() -> String {
        var lines: [String] = []
        let fm = FileManager.default
        lines.append("票据迁移 诊断报告 v2.1")
        lines.append(String(repeating: "-", count: 34))

        // 1. 容器根目录可读性（判断 entitlements 是否生效）
        var readableRoot = false
        var containerCount = 0
        for rootPath in containerRoots {
            if let dirs = try? fm.contentsOfDirectory(atPath: rootPath) {
                readableRoot = true
                containerCount = max(containerCount, dirs.count)
                break
            }
        }
        lines.append("1) 容器目录可读: \(readableRoot ? "是（\(containerCount) 个容器）" : "否 → 权限未生效")")

        // 2. 私有 API 可用性
        let proxyOK = NSClassFromString("LSApplicationProxy") != nil
        let wsOK = NSClassFromString("LSApplicationWorkspace") != nil
        lines.append("2) LSApplicationProxy: \(proxyOK ? "可用" : "不可用") · LSApplicationWorkspace: \(wsOK ? "可用" : "不可用")")

        // 3. 容器索引
        let index = containerIndex()
        lines.append("3) 元数据索引: \(index.count) 个 bundleID")

        // 4. 抖音源
        if let src = InstallDocMigrator.locateSourceDetailed() {
            let n = InstallDocMigrator.countItems(at: src.url)
            lines.append("4) 抖音票据目录: \(src.url.path)（\(n) 项）")
        } else {
            lines.append("4) 抖音票据目录: 未找到")
        }

        // 5. 各目标检测结果
        lines.append("5) 目标检测:")
        for app in allTargets {
            if let hit = locateContainer(bundleIDs: app.bundleIDs, index: index) {
                let name = (hit.url.path as NSString).lastPathComponent
                lines.append("   ✔ \(app.title) → \(hit.bundleID) · \(name)")
            } else {
                lines.append("   ✘ \(app.title) → 未安装或检测不到")
            }
        }

        // 6. 索引样本，便于确认 bundleID 是否写错
        let sample = index.keys.sorted().prefix(12).joined(separator: ", ")
        lines.append("6) 已检测 bundleID 样本: \(sample.isEmpty ? "无" : sample)")

        lines.append(String(repeating: "-", count: 34))
        lines.append("判定建议：")
        if !readableRoot {
            lines.append("· 容器读不到 → 用 AltStore/自签安装的包没有沙盒豁免，必须用 TrollStore 安装 ldid 打过 entitlements 的版本。")
        }
        if readableRoot && index.isEmpty {
            lines.append("· 容器可读但索引为空 → 目标 App 从未启动过，逐个打开一次再刷新。")
        }
        if index.count > 0 && index.keys.allSatisfy({ $0.hasPrefix("com.apple.") }) {
            lines.append("· 只看到系统 App → 目标 App 确实未安装。")
        }
        lines.append("· 若样本里出现类似 com.phoenix.video.xxx 的条目，说明是多开/渠道包，已支持前缀匹配。")
        return lines.joined(separator: "\n")
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

    struct SourceHit {
        let url: URL
        let bundleID: String
    }

    /// 定位抖音票据源目录（带命中的 bundleID，便于诊断）
    static func locateSourceDetailed() -> SourceHit? {
        guard let hit = AppContainerLocator.locateContainer(bundleIDs: AppContainerLocator.sourceApp.bundleIDs) else {
            return nil
        }
        for rel in sourceCandidates {
            let url = hit.url.appendingPathComponent(rel, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                return SourceHit(url: url, bundleID: hit.bundleID)
            }
        }
        return nil
    }

    static func locateSource() -> URL? { locateSourceDetailed()?.url }

    /// 当前检测到的已安装目标（用同一个索引，避免重复扫描）
    static func installedTargets() -> [TargetApp] {
        let index = AppContainerLocator.containerIndex()
        return AppContainerLocator.allTargets.filter {
            AppContainerLocator.isInstalled($0, index: index)
        }
    }

    /// 迁移到单个目标
    static func migrate(to target: TargetApp) -> Outcome {
        guard let src = locateSource() else {
            return Outcome(title: target.title, ok: false, detail: "未检测到抖音票据目录")
        }
        guard let dstHit = AppContainerLocator.locateContainer(bundleIDs: target.bundleIDs) else {
            return Outcome(title: target.title, ok: false, detail: "未安装或检测不到容器")
        }

        let fm = FileManager.default
        let dst = dstHit.url
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(dirName, isDirectory: true)

        do {
            try replaceItem(at: src, to: dst)
        } catch {
            return Outcome(title: target.title, ok: false, detail: "写入失败（无权限或空间不足）")
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

    /// 一键迁移：只处理已安装的 App；一个都没检测到时返回空数组，由上层给出诊断
    static func migrateInstalled() -> [Outcome] {
        let targets = installedTargets()
        guard !targets.isEmpty else { return [] }
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
    static func countItems(at url: URL) -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return fm.fileExists(atPath: url.path) ? 1 : 0
        }
        var count = 0
        for _ in walker { count += 1 }
        return count
    }
}
