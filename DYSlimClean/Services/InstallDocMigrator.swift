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
                "my.maya.iphone",
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
            id: "hongguo",
            title: "红果",
            bundleIDs: [
                "com.phoenix.read.iphone",
                "com.phoenix.read"
            ]
        ),
        TargetApp(
            id: "pipixia",
            title: "皮皮虾",
            bundleIDs: [
                "com.sup.iphone.superb",
                "com.sup.android.superb"
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

    /// 抖音源容器：必须有 Aweme 实质数据，避免半刷新空壳（仅有 Library/Preferences）抢先命中
    static func containerLooksLikeAweme(_ url: URL) -> Bool {
        let fm = FileManager.default
        let markers = [
            "Documents/Aweme.db",
            "Documents/mmkv",
            "Documents/_ttinstall_document",
            "Library/Preferences/com.ss.iphone.ugc.Aweme.plist",
            "Documents/tt_net_config.config"
        ]
        return markers.contains { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    /// 非抖音目标：有非空 Documents / Library 即可（不要用 Aweme 指纹，避免指回抖音容器）
    static func containerLooksPopulated(_ url: URL) -> Bool {
        if containerLooksLikeAweme(url) { return true }
        let fm = FileManager.default
        for rel in ["Documents", "Library", "Library/Preferences", "Library/Caches"] {
            let p = url.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let kids = try? fm.contentsOfDirectory(atPath: p.path), !kids.isEmpty { return true }
        }
        return false
    }

    /// 定位抖音源：优先带 _ttinstall 的真实容器
    static func locateDouyinSource() -> (bundleID: String, url: URL)? {
        let bids = douyin.bundleIDs
        // 1) metadata + Aweme 指纹
        for bid in bids {
            if let url = locateViaMetadata(bid), containerLooksLikeAweme(url) { return (bid, url) }
        }
        // 2) 指纹扫盘（仅 Aweme）
        if let url = locateViaMarkers(nil), containerLooksLikeAweme(url) {
            return (awemeBundleID(from: url) ?? "com.ss.iphone.ugc.Aweme", url)
        }
        for bid in bids {
            if let url = locateViaMarkers(bid), containerLooksLikeAweme(url) { return (bid, url) }
        }
        // 3) proxy，但仍要求 Aweme 指纹（拒绝空壳）
        for bid in bids {
            if let url = locateViaProxy(bid), containerLooksLikeAweme(url) { return (bid, url) }
        }
        // 4) 退而求其次：任意能找到且带 _ttinstall 的
        for bid in bids {
            if let hit = locateContainer(bundleIDs: [bid]) {
                let tt = hit.url.appendingPathComponent("Documents/_ttinstall_document")
                if FileManager.default.fileExists(atPath: tt.path) { return hit }
            }
        }
        return locateContainer(bundleIDs: bids)
    }

    private static func awemeBundleID(from url: URL) -> String? {
        let meta = url.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        guard let data = try? Data(contentsOf: meta),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let id = plist["MCMMetadataIdentifier"] as? String
        else { return nil }
        return id
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

    /// 指纹定位：仅用于抖音（Aweme）。非 Aweme 目标禁止用 Aweme 指纹，以免指回抖音容器并删源 _ttinstall
    static func locateViaMarkers(_ bundleID: String? = nil) -> URL? {
        let fm = FileManager.default
        let wantAweme = bundleID == nil
            || (bundleID?.caseInsensitiveCompare("com.ss.iphone.ugc.Aweme") == .orderedSame)
        // 非抖音：只走 metadata / proxy，不用 Aweme 指纹
        guard wantAweme else { return nil }

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
                        continue
                    }
                }
                let hits = [
                    "Documents/Aweme.db",
                    "Documents/mmkv",
                    "Documents/_ttinstall_document",
                    "Library/Preferences/com.ss.iphone.ugc.Aweme.plist",
                    "Documents/tt_net_config.config"
                ]
                if hits.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
                    return dir
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
        guard let srcHit = AppContainerLocator.locateDouyinSource() else {
            return Outcome(ok: false, message: "\(target.title)失败（未找到抖音）")
        }
        let srcDir = srcHit.url.appendingPathComponent(relativeDir, isDirectory: true)
        guard FileManager.default.fileExists(atPath: srcDir.path) else {
            return Outcome(ok: false, message: "\(target.title)失败（抖音无_ttinstall）")
        }

        guard let dstHit = AppContainerLocator.locateContainer(bundleIDs: target.bundleIDs) else {
            let ids = target.bundleIDs.prefix(2).joined(separator: "/")
            return Outcome(ok: false, message: "\(target.title)失败（未安装或找不到容器 \(ids)）")
        }

        // 防止目标误指回抖音：先删后拷会毁掉源 _ttinstall，导致后续全部失败
        if dstHit.url.standardizedFileURL.path.caseInsensitiveCompare(srcHit.url.standardizedFileURL.path) == .orderedSame {
            return Outcome(ok: false, message: "\(target.title)失败（目标与抖音容器相同，跳过）")
        }

        let fm = FileManager.default
        let dstDocs = dstHit.url.appendingPathComponent("Documents", isDirectory: true)
        let dstDir = dstHit.url.appendingPathComponent(relativeDir, isDirectory: true)

        // 先用 /bin/cp /bin/rm（工具箱 RootHelper 同路）。NSFileManager 跨容器常报「无 Documents 权限」
        let shell = shellMigrate(from: srcDir.path, to: dstDir.path, dstDocuments: dstDocs.path)
        if shell.ok, fm.fileExists(atPath: dstDir.path) {
            return Outcome(ok: true, message: "\(target.title)成功")
        }

        // 回退：POSIX 解锁 + 中转 Media 再拷
        do {
            try forceReplaceDirectory(from: srcDir, to: dstDir)
            return Outcome(ok: true, message: "\(target.title)成功")
        } catch {
            let tip = shell.ok ? error.localizedDescription : (shell.output.isEmpty ? shell.message : shell.output)
            return Outcome(
                ok: false,
                message: "\(target.title)失败（\(tip)）\n源：\(srcDir.path)\n目标：\(dstDir.path)"
            )
        }
    }

    /// /bin/chmod + rm + cp，绕过 NSFileManager 容器权限检查
    private static func shellMigrate(from src: String, to dst: String, dstDocuments: String) -> ShellScriptRunner.Result {
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let stageRoot = "/private/var/mobile/Media/dyclean_migrate"
        let stage = stageRoot + "/_ttinstall_document"
        let script = """
        SRC=\(q(src))
        DST=\(q(dst))
        DOCS=\(q(dstDocuments))
        STAGE_ROOT=\(q(stageRoot))
        STAGE=\(q(stage))

        mkdir -p "$STAGE_ROOT" 2>/dev/null || true
        rm -rf "$STAGE" 2>/dev/null || true
        # 先拷到 Media（通常可写），再进目标 Documents
        /bin/cp -R "$SRC" "$STAGE" || cp -R "$SRC" "$STAGE"

        # 尽量放开目标 Documents
        /bin/chmod -R u+rwx "$DOCS" 2>/dev/null || chmod -R u+rwx "$DOCS" 2>/dev/null || true
        /bin/chmod -R 777 "$DOCS" 2>/dev/null || true
        /usr/bin/chflags -R nouchg,noschg "$DOCS" 2>/dev/null || true
        /usr/bin/chflags -R nouchg,noschg "$DST" 2>/dev/null || true

        /bin/rm -rf "$DST" 2>/dev/null || rm -rf "$DST" 2>/dev/null || true
        mkdir -p "$(/usr/bin/dirname "$DST")" 2>/dev/null || mkdir -p "$(dirname "$DST")"

        /bin/cp -R "$STAGE" "$DST" || cp -R "$STAGE" "$DST"
        /bin/chmod -R u+rwX "$DST" 2>/dev/null || true

        # 校验
        if [ ! -d "$DST" ]; then
          echo "DST missing after cp: $DST"
          ls -la "$DOCS" 2>/dev/null || true
          exit 2
        fi
        echo "OK $DST"
        """
        return ShellScriptRunner.executeInline(script)
    }

    /// 清权限/不可变标志后替换目录；删不掉就改名旁路再拷
    private static func forceReplaceDirectory(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        let parent = dst.deletingLastPathComponent()
        unlockTree(parent)
        // 中转到 Media 再进目标，减少直接碰 Documents 的权限拦截
        let stageParent = URL(fileURLWithPath: "/private/var/mobile/Media/dyclean_migrate", isDirectory: true)
        let stage = stageParent.appendingPathComponent("_ttinstall_document", isDirectory: true)
        try fm.createDirectory(at: stageParent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: stage.path) {
            unlockTree(stage)
            try? fm.removeItem(at: stage)
        }
        try fm.copyItem(at: src, to: stage)

        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) {
            unlockTree(dst)
            try? fm.removeItem(at: dst)
            if fm.fileExists(atPath: dst.path) {
                // 不 move 到 Documents 旁（会再触发权限）；直接 merge 覆盖
                try mergeCopy(from: stage, to: dst)
                return
            }
        }
        do {
            try fm.copyItem(at: stage, to: dst)
        } catch {
            try mergeCopy(from: stage, to: dst)
        }
        unlockTree(dst)
    }

    private static func mergeCopy(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        guard let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: []) else {
            throw NSError(domain: "InstallDocMigrator", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法枚举源 _ttinstall"])
        }
        let srcRoot = src.standardizedFileURL.path
        while let item = en.nextObject() as? URL {
            let full = item.standardizedFileURL.path
            guard full.hasPrefix(srcRoot) else { continue }
            var rel = String(full.dropFirst(srcRoot.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            if rel.isEmpty { continue }
            let target = dst.appendingPathComponent(rel)
            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if vals?.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                unlockTree(target)
                try? fm.removeItem(at: target)
            }
            try fm.copyItem(at: item, to: target)
        }
    }

    private static func unlockTree(_ url: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        func unlockOne(_ p: String) {
            try? fm.setAttributes([
                .posixPermissions: 0o777,
                .immutable: false,
                .appendOnly: false
            ], ofItemAtPath: p)
            // 清 uchg / schg（不可变）
            var attrs = (try? fm.attributesOfItem(atPath: p)) ?? [:]
            attrs[.immutable] = false
            attrs[.appendOnly] = false
            try? fm.setAttributes(attrs, ofItemAtPath: p)
        }
        unlockOne(url.path)
        guard isDir.boolValue,
              let en = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: []) else { return }
        var budget = 50_000
        while let item = en.nextObject() as? URL {
            budget -= 1
            if budget <= 0 { break }
            unlockOne(item.path)
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
