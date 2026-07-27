import Foundation
import Security
import SQLite3

/// 对照 Fuck 工具箱「应用详情」四项：按 Bundle 单独执行，也可一键四项。
///
/// 1. 刷新容器  → refreshId（该 App 的 Data 容器 UUID）
/// 2. 清钥匙串  → cleanKeychainForBundleId:
/// 3. 刷新标识符 → Vendors / IDFV（lsdidentifiers，只动该 Bundle）
/// 4. 刷新广告符 → Advertisers / IDFA
enum DouyinOneTapReset {
    static let awemeBundleID = SlimCleaner.awemeBundleID

    enum Action: String, CaseIterable, Identifiable {
        case container = "刷新容器"
        case keychain = "清钥匙串"
        case vendor = "刷新标识符"
        case advertiser = "刷新广告符"
        var id: String { rawValue }
    }

    struct StepResult: Sendable {
        var name: String
        var ok: Bool
        var detail: String
    }

    struct Result: Sendable {
        var ok: Bool
        var steps: [StepResult]
        var message: String
        var newContainerPath: String?
    }

    /// 当前四项标识（界面展示用）
    struct IdentitySnapshot: Sendable {
        var containerUUID: String = "—"
        var keychainCount: Int = 0
        var vendorID: String = "—"
        var advertiserID: String = "—"

        var containerText: String { containerUUID }
        var keychainText: String { "\(keychainCount) 项" }
        var vendorText: String { vendorID }
        var advertiserText: String { advertiserID }
    }

    /// 读取当前四项标识（不改任何东西）
    static func readCurrentIdentity(bundleID: String, containerPath: String?) -> IdentitySnapshot {
        var snap = IdentitySnapshot()
        if let path = containerPath, !path.isEmpty {
            snap.containerUUID = URL(fileURLWithPath: path).lastPathComponent
        } else if let hit = AppContainerLocator.locateContainer(bundleIDs: [bundleID]) {
            snap.containerUUID = hit.url.lastPathComponent
        }

        snap.keychainCount = countKeychainItems(bundleID: bundleID)

        let needles = vendorNeedles(bundleID: bundleID)
        if let dict = loadLSIdentifiersDict() {
            let vendors = (dict["Vendors"] as? [String: Any]) ?? [:]
            if let v = firstUUID(in: vendors, preferKeysMatching: needles) ?? firstAnyUUID(in: vendors) {
                snap.vendorID = v
            } else if let root = dict["Vendor"] as? String, looksLikeUUID(root) {
                snap.vendorID = root
            }

            let ads = (dict["Advertisers"] as? [String: Any]) ?? [:]
            if let a = firstUUID(in: ads, preferKeysMatching: [bundleID])
                ?? firstAnyUUID(in: ads)
                ?? (dict["Advertiser"] as? String).flatMap({ looksLikeUUID($0) ? $0 : nil }) {
                snap.advertiserID = a
            }
        }
        return snap
    }

    /// 兼容旧调用：默认抖音一键四项
    static func run(cleaner: SlimCleaner) -> Result {
        runAll(bundleIDs: [awemeBundleID], displayName: "抖音", cleaner: cleaner)
    }

    /// 一键：容器 → 钥匙串 → 标识符 → 广告符（+ 网络权限回写）
    static func runAll(bundleIDs: [String], displayName: String, cleaner: SlimCleaner) -> Result {
        guard let hit = AppContainerLocator.locateContainer(bundleIDs: bundleIDs) else {
            return Result(
                ok: false,
                steps: [.init(name: "定位应用", ok: false, detail: "未找到 \(displayName) 数据容器")],
                message: "未找到 \(displayName)",
                newContainerPath: nil
            )
        }
        let bid = hit.bundleID
        _ = terminateApp(bundleID: bid)

        var steps: [StepResult] = []
        var newPath: String?

        let c = refreshContainer(bundleID: bid, containerURL: hit.url)
        steps.append(c.step)
        if let p = c.newPath { newPath = p }

        steps.append(clearKeychain(bundleID: bid))
        steps.append(refreshVendorIdentifier(bundleID: bid))
        steps.append(refreshAdvertisingIdentifier(bundleID: bid))
        steps.append(restoreAwemeNetworkTCC(bundleID: bid))

        let allOK = steps.prefix(4).allSatisfy(\.ok)
        let lines = steps.map { "\($0.ok ? "✓" : "✗") \($0.name)：\($0.detail)" }
        let tip = """
        \(displayName) · \(allOK ? "一键四项成功" : "一键四项部分失败")

        \(lines.joined(separator: "\n"))

        请划掉该 App 后重开。账号数据通常仍在（不是清理数据）。
        """
        return Result(ok: allOK, steps: steps, message: tip.trimmingCharacters(in: .whitespacesAndNewlines), newContainerPath: newPath)
    }

    /// 单项（工具箱应用详情同款）
    static func runAction(_ action: Action, bundleIDs: [String], displayName: String, cleaner: SlimCleaner) -> Result {
        _ = cleaner
        guard let hit = AppContainerLocator.locateContainer(bundleIDs: bundleIDs) else {
            return Result(
                ok: false,
                steps: [.init(name: action.rawValue, ok: false, detail: "未找到 \(displayName) 容器")],
                message: "未找到 \(displayName)",
                newContainerPath: nil
            )
        }
        let bid = hit.bundleID
        _ = terminateApp(bundleID: bid)

        let step: StepResult
        var newPath: String?
        switch action {
        case .container:
            let c = refreshContainer(bundleID: bid, containerURL: hit.url)
            step = c.step
            newPath = c.newPath
        case .keychain:
            step = clearKeychain(bundleID: bid)
        case .vendor:
            step = refreshVendorIdentifier(bundleID: bid)
        case .advertiser:
            step = refreshAdvertisingIdentifier(bundleID: bid)
        }
        // 容器/标识变更后尽量回写网络权限，减少弹窗
        if action == .container || action == .vendor || action == .advertiser {
            _ = restoreAwemeNetworkTCC(bundleID: bid)
        }
        let tip = """
        \(displayName) · \(action.rawValue)
        \(step.ok ? "✓" : "✗") \(step.detail)
        """
        return Result(ok: step.ok, steps: [step], message: tip.trimmingCharacters(in: .whitespacesAndNewlines), newContainerPath: newPath)
    }

    /// 半刷新修复：系统空壳 ← 孤儿有数据目录（只改 MCM 指向，不搬文件）
    @discardableResult
    static func relinkContainerIfPossible(bundleID: String, fromEmpty emptyURL: URL, toFat fatURL: URL) -> Bool {
        let oldUUID = emptyURL.lastPathComponent
        let newUUID = fatURL.lastPathComponent
        // 空壳 UUID 可能已是系统当前登记；要把库里的 uuid/path 改成 fat 的
        // 这里 old=空壳登记值，new=fat 目录名
        let ok = updateMCMDatabase(
            bundleID: bundleID,
            oldUUID: oldUUID,
            newUUID: newUUID,
            newPath: fatURL.path
        )
        if ok {
            _ = updateMetadataPlist(at: fatURL, newUUID: newUUID, bundleID: bundleID)
            _ = reregisterContainer(bundleID: bundleID, containerPath: fatURL.path)
        }
        return ok
    }

    // MARK: - 1 刷新容器

    private struct ContainerRefresh {
        var step: StepResult
        var newPath: String?
    }

    /// 工具箱 refreshId：目录改名 + metadata + MCM 必须都成功，否则回滚。
    /// 以前 MCM 失败仍报成功 → 系统按旧 UUID 找不到目录，会给抖音建「空容器」，
    /// 扫描/爱思就看到没数据（真数据还在孤儿目录里）。
    private static func refreshContainer(bundleID: String, containerURL oldURL: URL) -> ContainerRefresh {
        let name = "刷新容器"
        let fm = FileManager.default
        let oldUUID = oldURL.lastPathComponent
        let newUUID = UUID().uuidString.uppercased()
        let parent = oldURL.deletingLastPathComponent()
        let newURL = parent.appendingPathComponent(newUUID, isDirectory: true)

        do {
            if fm.fileExists(atPath: newURL.path) {
                return .init(step: .init(name: name, ok: false, detail: "新 UUID 目录已存在，请重试"), newPath: nil)
            }
            try fm.moveItem(at: oldURL, to: newURL)

            let metaOK = updateMetadataPlist(at: newURL, newUUID: newUUID, bundleID: bundleID)
            if !metaOK {
                try? fm.moveItem(at: newURL, to: oldURL)
                return .init(step: .init(name: name, ok: false, detail: "metadata 写入失败，已回滚"), newPath: nil)
            }

            // MCM sqlite 必须成功；失败立刻回滚（禁止半刷新空壳）
            let mcmOK = updateMCMDatabase(
                bundleID: bundleID,
                oldUUID: oldUUID,
                newUUID: newUUID,
                newPath: newURL.path
            )
            if !mcmOK {
                try? fm.moveItem(at: newURL, to: oldURL)
                _ = updateMetadataPlist(at: oldURL, newUUID: oldUUID, bundleID: bundleID)
                let diag = mcmDiagnostics()
                return .init(
                    step: .init(
                        name: name,
                        ok: false,
                        detail: "MCM 未更新（已回滚，数据未丢）。\(diag)"
                    ),
                    newPath: nil
                )
            }

            _ = reregisterContainer(bundleID: bundleID, containerPath: newURL.path)
            _ = pokeContainerManager(bundleID: bundleID)

            let linked = verifyContainerLink(bundleID: bundleID, expectPath: newURL.path)
            var detail = "\(oldUUID.prefix(8))… → \(newUUID.prefix(8))… · MCM已更新"
            if linked { detail += " · 系统已指向新容器" }
            else { detail += " · 请划掉抖音重开" }

            return .init(step: .init(name: name, ok: true, detail: detail), newPath: newURL.path)
        } catch {
            return .init(
                step: .init(name: name, ok: false, detail: "重命名失败：\(error.localizedDescription)"),
                newPath: nil
            )
        }
    }

    private static func pokeContainerManager(bundleID: String) -> Bool {
        if let proxyClass = NSClassFromString("LSApplicationProxy") as? NSObject.Type {
            let sel = NSSelectorFromString("applicationProxyForIdentifier:")
            if proxyClass.responds(to: sel) {
                _ = proxyClass.perform(sel, with: bundleID)
            }
        }
        return true
    }

    private static func verifyContainerLink(bundleID: String, expectPath: String) -> Bool {
        guard let url = AppContainerLocator.locateViaProxy(bundleID) else { return false }
        return url.path == expectPath
            || url.lastPathComponent.caseInsensitiveCompare(URL(fileURLWithPath: expectPath).lastPathComponent) == .orderedSame
    }

    private static func updateMetadataPlist(at container: URL, newUUID: String, bundleID: String) -> Bool {
        let meta = container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        guard var dict = readPlist(meta) else {
            let fresh: [String: Any] = [
                "MCMMetadataIdentifier": bundleID,
                "MCMMetadataUUID": newUUID,
                "MCMMetadataInfo": [:] as [String: Any]
            ]
            return writePlist(fresh, to: meta)
        }
        dict["MCMMetadataIdentifier"] = bundleID
        dict["MCMMetadataUUID"] = newUUID
        return writePlist(dict, to: meta)
    }

    /// 宽搜 MCM sqlite + 按表结构动态 UPDATE（RootHide 路径各异）
    private static func updateMCMDatabase(bundleID: String, oldUUID: String, newUUID: String, newPath: String) -> Bool {
        // 先试私有 SPI（若系统/工具链暴露）
        if patchMCMViaPrivateAPI(bundleID: bundleID, oldUUID: oldUUID, newUUID: newUUID, newPath: newPath) {
            return true
        }

        var candidates: [String] = [
            "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile_container_manager.shared/Library/Caches/com.apple.containermanagerd/containers.sqlite",
            "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile_container_manager.shared/Library/Caches/com.apple.containermanagerd/containers.sqlite",
            "/private/var/root/Library/MobileContainerManager/containers.sqlite",
            "/var/root/Library/MobileContainerManager/containers.sqlite",
            "/private/var/db/MobileContainerManager/containers.sqlite",
            "/var/db/MobileContainerManager/containers.sqlite",
            "/var/mobile/Library/MobileContainerManager/containers.sqlite",
            "/private/var/mobile/Library/MobileContainerManager/containers.sqlite"
        ]
        let fm = FileManager.default
        let scanRoots = [
            "/private/var/containers/Shared/SystemGroup",
            "/var/containers/Shared/SystemGroup",
            "/var/jb/var/containers/Shared/SystemGroup",
            "/private/var/jb/var/containers/Shared/SystemGroup",
            "/var/containers",
            "/private/var/containers",
            "/var/root/Library",
            "/private/var/root/Library",
            "/var/db",
            "/private/var/db"
        ]
        for root in scanRoots where fm.fileExists(atPath: root) {
            if let more = findFiles(namedHints: ["containers.sqlite", "containermanager"], under: root, maxDepth: 7) {
                candidates.append(contentsOf: more.filter {
                    let l = $0.lowercased()
                    return l.hasSuffix(".sqlite") || l.hasSuffix(".db") || l.contains("containers.sqlite")
                })
            }
        }

        var touched = false
        var lastError = ""
        for path in Set(candidates) where fm.fileExists(atPath: path) {
            unlockFile(path)
            unlockFile(path + "-wal")
            unlockFile(path + "-shm")
            let r = patchSQLiteReplace(path: path, oldUUID: oldUUID, newUUID: newUUID, newPath: newPath, bundleID: bundleID)
            if r.ok { touched = true }
            else if !r.error.isEmpty { lastError = r.error }
        }
        _ = lastError
        return touched
    }

    /// 尝试调用系统/私有 Container Manager（工具箱同类思路）
    private static func patchMCMViaPrivateAPI(bundleID: String, oldUUID: String, newUUID: String, newPath: String) -> Bool {
        // 1) 自研/工具箱可能挂的 helper 类
        let helperNames = [
            "AppManagerHelper",
            "MCMContainerManager",
            "_TtC4code16AppManagerHelper"
        ]
        for name in helperNames {
            guard let cls = NSClassFromString(name) as? NSObject.Type else { continue }
            let sels = [
                "updateMCMDatabaseForIdentifier:oldUUID:newUUID:newPath:",
                "replaceContainerUUIDForBundleId:oldUUID:newUUID:",
                "renameBundleContainerForBundleId:newUUID:"
            ]
            for selName in sels {
                let sel = NSSelectorFromString(selName)
                guard cls.responds(to: sel) || (cls as AnyObject).responds(to: sel) else { continue }
                // 静态/共享实例难以稳定调用；有 shared 再试
                let sharedSel = NSSelectorFromString("shared")
                let shared2 = NSSelectorFromString("sharedHelper")
                var target: NSObject?
                if cls.responds(to: sharedSel) {
                    target = cls.perform(sharedSel)?.takeUnretainedValue() as? NSObject
                } else if cls.responds(to: shared2) {
                    target = cls.perform(shared2)?.takeUnretainedValue() as? NSObject
                }
                guard let obj = target, obj.responds(to: sel) else { continue }
                // 多参 perform 受限，跳过，走 sqlite
                _ = (bundleID, oldUUID, newUUID, newPath, obj, sel)
            }
        }
        return false
    }

    private static func unlockFile(_ path: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        try? fm.setAttributes([
            .posixPermissions: 0o666,
            .immutable: false,
            .appendOnly: false
        ], ofItemAtPath: path)
    }

    /// MCM 失败诊断：库是否存在 / 能否打开
    private static func mcmDiagnostics() -> String {
        let fm = FileManager.default
        let hints = [
            "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile_container_manager.shared/Library/Caches/com.apple.containermanagerd/containers.sqlite",
            "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile_container_manager.shared/Library/Caches/com.apple.containermanagerd/containers.sqlite"
        ]
        var found: [String] = []
        for p in hints where fm.fileExists(atPath: p) { found.append(p) }
        if found.isEmpty {
            // 宽搜一个
            for root in ["/private/var/containers/Shared/SystemGroup", "/var/containers/Shared/SystemGroup"] {
                if let more = findFiles(namedHints: ["containers.sqlite"], under: root, maxDepth: 6), let first = more.first {
                    found.append(first)
                    break
                }
            }
        }
        if found.isEmpty {
            return "未找到 containers.sqlite（无权限或 RootHide 路径不同）。请确认已用巨魔重装本 App（含新 entitlements）"
        }
        let p = found[0]
        unlockFile(p)
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(p, &db, SQLITE_OPEN_READONLY, nil)
        defer { if db != nil { sqlite3_close(db) } }
        if rc != SQLITE_OK {
            return "找到库但打不开(rc=\(rc))：\(p)"
        }
        return "已找到库但 0 行匹配 UUID。系统库未挂上新 UUID 会变空容器。库：\(p)"
    }

    private struct SQLitePatchResult {
        var ok: Bool
        var error: String
    }

    private static func patchSQLiteReplace(path: String, oldUUID: String, newUUID: String, newPath: String, bundleID: String) -> SQLitePatchResult {
        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openRC = sqlite3_open_v2(path, &db, openFlags, nil)
        guard openRC == SQLITE_OK, let db else {
            return .init(ok: false, error: "open失败 \(openRC) \(path)")
        }
        defer { sqlite3_close(db) }

        _ = sqlite3_exec(db, "PRAGMA busy_timeout=8000;", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)

        let pathVariants: [String] = {
            var s = Set<String>()
            s.insert(newPath)
            s.insert(newPath.replacingOccurrences(of: "/private", with: ""))
            if !newPath.hasPrefix("/private"), newPath.hasPrefix("/var") {
                s.insert("/private" + newPath)
            }
            return Array(s)
        }()
        let uuidPairs = [
            (oldUUID, newUUID),
            (oldUUID.lowercased(), newUUID.lowercased()),
            (oldUUID.uppercased(), newUUID.uppercased())
        ]

        var any = false
        for (oldU, newU) in uuidPairs {
            for p in pathVariants {
                let esc = p.replacingOccurrences(of: "'", with: "''")
                let sqls = [
                    "UPDATE Containers SET uuid='\(newU)', path='\(esc)' WHERE uuid='\(oldU)';",
                    "UPDATE Containers SET UUID='\(newU)', Path='\(esc)' WHERE UUID='\(oldU)';",
                    "UPDATE containers SET uuid='\(newU)', path='\(esc)' WHERE uuid='\(oldU)';",
                    "UPDATE Containers SET uuid='\(newU)', path='\(esc)' WHERE identifier='\(bundleID)';",
                    "UPDATE Containers SET UUID='\(newU)', Path='\(esc)' WHERE Identifier='\(bundleID)';",
                    "UPDATE containers SET uuid='\(newU)', path='\(esc)' WHERE identifier='\(bundleID)';",
                    "UPDATE CodeSigningEntries SET data_container_uuid='\(newU)' WHERE data_container_uuid='\(oldU)';",
                    "UPDATE CodeSigningEntries SET data_container_uuid='\(newU)' WHERE identifier='\(bundleID)';",
                    // 部分系统用 relative path / 仅目录名
                    "UPDATE Containers SET uuid='\(newU)' WHERE uuid='\(oldU)';",
                    "UPDATE Containers SET path='\(esc)' WHERE uuid='\(newU)' OR uuid='\(oldU)' OR identifier='\(bundleID)';"
                ]
                for sql in sqls {
                    if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, sqlite3_changes(db) > 0 { any = true }
                }
            }
        }

        // 动态：所有表文本列含旧 UUID
        var tablesStmt: OpaquePointer?
        var tables: [String] = []
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &tablesStmt, nil) == SQLITE_OK {
            while sqlite3_step(tablesStmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(tablesStmt, 0) {
                    tables.append(String(cString: c))
                }
            }
        }
        sqlite3_finalize(tablesStmt)

        for table in tables {
            let cols = pragmaColumns(db: db, table: table)
            for col in cols {
                for (oldU, newU) in uuidPairs {
                    let sql1 = "UPDATE \"\(table)\" SET \"\(col)\"='\(newU)' WHERE \"\(col)\"='\(oldU)';"
                    if sqlite3_exec(db, sql1, nil, nil, nil) == SQLITE_OK, sqlite3_changes(db) > 0 { any = true }
                    if col.lowercased().contains("path") {
                        for p in pathVariants {
                            let esc = p.replacingOccurrences(of: "'", with: "''")
                            let sql2 = "UPDATE \"\(table)\" SET \"\(col)\"='\(esc)' WHERE \"\(col)\" LIKE '%\(oldU)%';"
                            if sqlite3_exec(db, sql2, nil, nil, nil) == SQLITE_OK, sqlite3_changes(db) > 0 { any = true }
                        }
                    }
                }
            }
        }

        _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil)
        return .init(ok: any, error: any ? "" : "0行更新 \(path)")
    }

    private static func pragmaColumns(db: OpaquePointer, table: String) -> [String] {
        var stmt: OpaquePointer?
        var cols: [String] = []
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\"\(table)\")", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1) {
                    cols.append(String(cString: c))
                }
            }
        }
        sqlite3_finalize(stmt)
        return cols
    }

    /// Fuck 附近真实符号：registerAppAtPath:forBundleId:withExplicitContainer:
    private static func reregisterContainer(bundleID: String, containerPath: String) -> Bool {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return false }
        let defSel = NSSelectorFromString("defaultWorkspace")
        guard wsClass.responds(to: defSel),
              let ws = wsClass.perform(defSel)?.takeUnretainedValue() as? NSObject
        else { return false }

        // 尝试带容器路径的注册（若实现存在）
        let sel = NSSelectorFromString("registerApplicationDictionary:")
        if ws.responds(to: sel) {
            let dict: [String: Any] = [
                "CFBundleIdentifier": bundleID,
                "Path": containerPath,
                "Container": containerPath
            ]
            _ = ws.perform(sel, with: dict)
            return true
        }
        return false
    }

    // MARK: - 2 清钥匙串

    /// 清钥匙串：SecItem + 直接改系统 `/var/Keychains/keychain-2.db`（工具箱/雷神同路径）
    private static func clearKeychain(bundleID: String) -> StepResult {
        let name = "清钥匙串"
        let beforeSec = countKeychainItems(bundleID: bundleID)
        let classes: [CFString] = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity
        ]

        var deleted = 0
        for secClass in classes {
            deleted += deleteKeychainItems(secClass: secClass, bundleID: bundleID)
        }

        for team in ["UGCRJ42T19", "3JTPEA4UU7", ""] {
            let agrp = team.isEmpty ? bundleID : "\(team).\(bundleID)"
            for secClass in classes {
                var q: [String: Any] = [
                    kSecClass as String: secClass,
                    kSecAttrAccessGroup as String: agrp,
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
                ]
                if SecItemDelete(q as CFDictionary) == errSecSuccess { deleted += 1 }
                q.removeValue(forKey: kSecAttrSynchronizable as String)
                if SecItemDelete(q as CFDictionary) == errSecSuccess { deleted += 1 }
            }
        }

        // 关键：直接清系统钥匙串库（SecItem 常枚举到 0，但库里有 agrp 行）
        let dbWipe = wipeKeychainDatabase(bundleID: bundleID)
        let afterSec = countKeychainItems(bundleID: bundleID)

        if dbWipe.deleted > 0 || deleted > 0 || afterSec < beforeSec {
            var detail = "SecItem 删 \(deleted) · 库删 \(dbWipe.deleted) 行 · 前 \(beforeSec) → 后 \(afterSec)"
            if !dbWipe.path.isEmpty { detail += "\n\(dbWipe.path)" }
            return .init(name: name, ok: true, detail: detail)
        }
        if beforeSec == 0 && dbWipe.deleted == 0 {
            let pathTip = dbWipe.path.isEmpty ? "未找到 keychain-2.db" : "库：\(dbWipe.path)（0 行匹配）"
            return .init(
                name: name,
                ok: false,
                detail: "SecItem=0 且库未删到行。\(pathTip)\n请确认 tipa 含 keychain-access-groups 且已巨魔重装"
            )
        }
        return .init(
            name: name,
            ok: false,
            detail: "仍有 \(afterSec) 项未删掉"
        )
    }

    private struct KeychainDBWipe {
        var deleted: Int
        var path: String
    }

    /// 系统钥匙串路径（雷神/雷蛇备份的 Keychains/ 即来自此）
    private static func keychainDBCandidates() -> [String] {
        [
            "/private/var/Keychains/keychain-2.db",
            "/var/Keychains/keychain-2.db",
            "/private/var/mobile/Library/Keychains/keychain-2.db",
            "/var/mobile/Library/Keychains/keychain-2.db"
        ]
    }

    private static func wipeKeychainDatabase(bundleID: String) -> KeychainDBWipe {
        let fm = FileManager.default
        let needles = [
            bundleID,
            "com.ss.iphone.ugc.Aweme",
            "UGCRJ42T19.\(bundleID)",
            "3JTPEA4UU7.\(bundleID)",
            "UGCRJ42T19.com.ss.iphone.ugc.Aweme",
            "3JTPEA4UU7.com.ss.iphone.ugc.Aweme"
        ]
        var total = 0
        var used = ""
        for path in keychainDBCandidates() where fm.fileExists(atPath: path) {
            unlockFile(path)
            unlockFile(path + "-wal")
            unlockFile(path + "-shm")
            let n = wipeKeychainSQLite(path: path, needles: needles)
            if n > 0 {
                total += n
                used = path
            } else if used.isEmpty {
                used = path
            }
        }
        // 也扫 jbroot
        for root in ["/var/jb/var/Keychains", "/private/var/jb/var/Keychains"] {
            let p = (root as NSString).appendingPathComponent("keychain-2.db")
            if fm.fileExists(atPath: p) {
                unlockFile(p)
                let n = wipeKeychainSQLite(path: p, needles: needles)
                if n > 0 { total += n; used = p }
                else if used.isEmpty { used = p }
            }
        }
        return .init(deleted: total, path: used)
    }

    private static func wipeKeychainSQLite(path: String, needles: [String]) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { return 0 }
        defer { sqlite3_close(db) }
        _ = sqlite3_exec(db, "PRAGMA busy_timeout=8000;", nil, nil, nil)

        // 常见表：genp / inet / cert / keys（agrp/svce/acct 文本或 blob）
        let tables = ["genp", "inet", "cert", "keys", "identity"]
        var deleted = 0
        for table in tables {
            // 表不存在则跳过
            var probe: OpaquePointer?
            let exists = sqlite3_prepare_v2(db, "SELECT 1 FROM \"\(table)\" LIMIT 1;", -1, &probe, nil) == SQLITE_OK
            sqlite3_finalize(probe)
            guard exists else { continue }

            let cols = Set(pragmaColumns(db: db, table: table).map { $0.lowercased() })
            let textCols = ["agrp", "svce", "acct", "labl", "klbl", "desc", "icmt"].filter { cols.contains($0) }
            guard !textCols.isEmpty else { continue }

            for needle in needles {
                let esc = needle.replacingOccurrences(of: "'", with: "''")
                let likes = textCols.map { "CAST(\"\($0)\" AS TEXT) LIKE '%\(esc)%'" }.joined(separator: " OR ")
                let sql = "DELETE FROM \"\(table)\" WHERE \(likes);"
                if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
                    deleted += Int(sqlite3_changes(db))
                }
            }
        }
        _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil)
        return deleted
    }

    private static func keychainKeywords(bundleID: String) -> [String] {
        [
            bundleID,
            "com.ss.iphone.ugc.Aweme",
            "aweme",
            "Aweme",
            "bytedance",
            "ByteDance",
            "ss.iphone.ugc",
            "UGCRJ42T19",
            "3JTPEA4UU7",
            "openudid",
            "sskeychain",
            "device_id",
            "install_id"
        ]
    }

    private static func deleteKeychainItems(secClass: CFString, bundleID: String) -> Int {
        var count = 0
        let keywords = keychainKeywords(bundleID: bundleID)

        var queries: [[String: Any]] = [
            [kSecClass as String: secClass, kSecAttrService as String: bundleID],
            [kSecClass as String: secClass, kSecAttrAccount as String: bundleID],
            [kSecClass as String: secClass, kSecAttrAccessGroup as String: bundleID],
            [kSecClass as String: secClass, kSecAttrService as String: "Aweme"],
            [kSecClass as String: secClass, kSecAttrAccount as String: "Aweme"]
        ]
        for team in ["UGCRJ42T19", "3JTPEA4UU7"] {
            queries.append([
                kSecClass as String: secClass,
                kSecAttrAccessGroup as String: "\(team).\(bundleID)"
            ])
        }

        for var q in queries {
            q[kSecMatchLimit as String] = kSecMatchLimitAll
            q[kSecReturnAttributes as String] = true
            q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            var result: CFTypeRef?
            let st = SecItemCopyMatching(q as CFDictionary, &result)
            if st == errSecSuccess, let arr = result as? [[String: Any]] {
                for item in arr {
                    if deleteOneKeychainItem(secClass: secClass, item: item) { count += 1 }
                }
            } else {
                var delQ = q
                delQ.removeValue(forKey: kSecMatchLimit as String)
                delQ.removeValue(forKey: kSecReturnAttributes as String)
                if SecItemDelete(delQ as CFDictionary) == errSecSuccess { count += 1 }
            }
        }

        count += wipeMatchingSecItems(secClass: secClass, keywords: keywords)
        return count
    }

    private static func wipeMatchingSecItems(secClass: CFString, keywords: [String]) -> Int {
        let query: [String: Any] = [
            kSecClass as String: secClass,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var result: CFTypeRef?
        let st = SecItemCopyMatching(query as CFDictionary, &result)
        guard st == errSecSuccess, let items = result as? [[String: Any]] else { return 0 }

        var n = 0
        for item in items {
            let hay = [
                item[kSecAttrService as String] as? String,
                item[kSecAttrAccount as String] as? String,
                item[kSecAttrAccessGroup as String] as? String,
                item[kSecAttrLabel as String] as? String
            ].compactMap { $0 }.joined(separator: " ").lowercased()

            guard keywords.contains(where: { hay.contains($0.lowercased()) }) else { continue }
            if deleteOneKeychainItem(secClass: secClass, item: item) { n += 1 }
        }
        return n
    }

    private static func deleteOneKeychainItem(secClass: CFString, item: [String: Any]) -> Bool {
        var del: [String: Any] = [kSecClass as String: secClass]
        if let svc = item[kSecAttrService as String] { del[kSecAttrService as String] = svc }
        if let acc = item[kSecAttrAccount as String] { del[kSecAttrAccount as String] = acc }
        if let ag = item[kSecAttrAccessGroup as String] { del[kSecAttrAccessGroup as String] = ag }
        return SecItemDelete(del as CFDictionary) == errSecSuccess
    }

    /// 统计该 Bundle 相关钥匙串条数（只读，不删）
    private static func countKeychainItems(bundleID: String) -> Int {
        var seen = Set<String>()
        let classes: [CFString] = [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey, kSecClassCertificate, kSecClassIdentity]
        let keywords = keychainKeywords(bundleID: bundleID)
        for secClass in classes {
            var queries: [[String: Any]] = [
                [kSecClass as String: secClass, kSecAttrService as String: bundleID],
                [kSecClass as String: secClass, kSecAttrAccount as String: bundleID],
                [kSecClass as String: secClass, kSecAttrAccessGroup as String: bundleID]
            ]
            for team in ["UGCRJ42T19", "3JTPEA4UU7"] {
                queries.append([
                    kSecClass as String: secClass,
                    kSecAttrAccessGroup as String: "\(team).\(bundleID)"
                ])
            }
            for var q in queries {
                q[kSecMatchLimit as String] = kSecMatchLimitAll
                q[kSecReturnAttributes as String] = true
                q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
                var result: CFTypeRef?
                let st = SecItemCopyMatching(q as CFDictionary, &result)
                if st == errSecSuccess, let arr = result as? [[String: Any]] {
                    for item in arr {
                        let key = "\(item[kSecAttrService as String] ?? "")|\(item[kSecAttrAccount as String] ?? "")|\(item[kSecAttrAccessGroup as String] ?? "")"
                        seen.insert(key)
                    }
                }
            }
            // 关键字扫一遍（与删除逻辑同口径，只计数）
            let broad: [String: Any] = [
                kSecClass as String: secClass,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true
            ]
            var result: CFTypeRef?
            if SecItemCopyMatching(broad as CFDictionary, &result) == errSecSuccess,
               let arr = result as? [[String: Any]] {
                for item in arr {
                    let hay = [
                        item[kSecAttrService as String] as? String,
                        item[kSecAttrAccount as String] as? String,
                        item[kSecAttrAccessGroup as String] as? String,
                        item[kSecAttrLabel as String] as? String
                    ].compactMap { $0 }.joined(separator: " ").lowercased()
                    guard keywords.contains(where: { hay.contains($0.lowercased()) }) else { continue }
                    let key = "\(item[kSecAttrService as String] ?? "")|\(item[kSecAttrAccount as String] ?? "")|\(item[kSecAttrAccessGroup as String] ?? "")"
                    seen.insert(key)
                }
            }
        }
        return seen.count
    }

    /// 只读扫描已有 lsdidentifiers
    private static func readExistingLSIdentifiers(_ body: ([String: Any]) -> Void) {
        if let dict = loadLSIdentifiersDict() { body(dict) }
    }

    private static func loadLSIdentifiersDict() -> [String: Any]? {
        for path in resolveLSIdentifierPaths(createIfMissing: false) {
            if let dict = readPlist(URL(fileURLWithPath: path)) { return dict }
        }
        return nil
    }

    // MARK: - 3 刷新标识符（Vendor / IDFV）

    /// 对齐工具箱 refreshUUID：有则改，没有就创建/写入（工具箱也会「生成新的」）
    private static func refreshVendorIdentifier(bundleID: String) -> StepResult {
        let name = "刷新标识符"
        let newVendor = UUID().uuidString.uppercased()
        let needles = vendorNeedles(bundleID: bundleID)

        var oldShown = "未找到"
        var writtenPath = ""
        let touched = mutateLSIdentifiersPlist(
            createIfMissing: true,
            body: { dict in
                var vendors = (dict["Vendors"] as? [String: Any]) ?? [:]
                let before = firstUUID(in: vendors, preferKeysMatching: needles) ?? firstAnyUUID(in: vendors)
                if let before { oldShown = before }

                let replaced = replaceUUIDValues(in: vendors, preferKeysMatching: needles, newValue: { _ in newVendor })
                if treeContains(replaced, needle: newVendor) {
                    vendors = replaced
                } else {
                    vendors = upsertVendorKeys(vendors, bundleID: bundleID, uuid: newVendor)
                }
                dict["Vendors"] = vendors
                dict["Vendor"] = newVendor
                return treeContains(vendors, needle: newVendor) || (dict["Vendor"] as? String) == newVendor
            },
            writtenPath: { writtenPath = $0 }
        )

        let tip = touched
            ? "旧 \(shortUUID(oldShown)) → 新 \(shortUUID(newVendor))\n\(writtenPath)"
            : "未写入 Vendor（lsdidentifiers 不可写）\n候选：\(resolveLSIdentifierPaths(createIfMissing: false).prefix(2).joined(separator: " | "))"
        return .init(name: name, ok: touched, detail: tip)
    }

    // MARK: - 4 刷新广告符（Advertiser / IDFA）

    /// 对齐工具箱：广告符「未找到」时仍会生成新 IDFA
    private static func refreshAdvertisingIdentifier(bundleID: String) -> StepResult {
        let name = "刷新广告符"
        let newAd = UUID().uuidString.uppercased()
        var oldShown = "未找到"
        var writtenPath = ""

        let touched = mutateLSIdentifiersPlist(
            createIfMissing: true,
            body: { dict in
                var ads = (dict["Advertisers"] as? [String: Any]) ?? [:]
                if let old = firstUUID(in: ads, preferKeysMatching: [bundleID])
                    ?? firstAnyUUID(in: ads)
                    ?? (dict["Advertiser"] as? String).flatMap({ looksLikeUUID($0) ? $0 : nil }) {
                    oldShown = old
                }

                if !ads.isEmpty {
                    ads = replaceUUIDValues(in: ads, preferKeysMatching: [], newValue: { _ in newAd })
                }
                if !treeContains(ads, needle: newAd) {
                    ads[bundleID] = newAd
                    ads["Advertiser"] = newAd
                    if ads["Default"] == nil { ads["Default"] = newAd }
                }
                dict["Advertisers"] = ads
                dict["Advertiser"] = newAd
                return true
            },
            writtenPath: { writtenPath = $0 }
        )

        let tip = touched
            ? "旧 \(shortUUID(oldShown)) → 新 \(shortUUID(newAd))\n\(writtenPath)"
            : "未写入 Advertisers（lsdidentifiers 不可写）"
        return .init(name: name, ok: touched, detail: tip)
    }

    private static func vendorNeedles(bundleID: String) -> [String] {
        [
            bundleID,
            "UGCRJ42T19",
            "3JTPEA4UU7",
            "Bytedance",
            "bytedance",
            "Aweme",
            "aweme",
            "ss.iphone.ugc"
        ]
    }

    /// 写入常见 TeamID.bundle / bundle 键，保证「未看到抖音 Vendor」时也能刷新成功
    private static func upsertVendorKeys(_ vendors: [String: Any], bundleID: String, uuid: String) -> [String: Any] {
        var out = vendors
        let keys = [
            bundleID,
            "UGCRJ42T19.\(bundleID)",
            "3JTPEA4UU7.\(bundleID)",
            "Vendor.\(bundleID)"
        ]
        for k in keys {
            // 已有子字典则往里塞 UUID；否则直接挂字符串
            if var sub = out[k] as? [String: Any] {
                sub["identifierForVendor"] = uuid
                sub["VendorIdentifier"] = uuid
                sub["UUID"] = uuid
                out[k] = sub
            } else {
                out[k] = uuid
            }
        }
        return out
    }

    private static func shortUUID(_ s: String) -> String {
        guard s.count >= 13, s != "未找到" else { return s }
        // 显示前两段，避免旧新看起来一样
        let parts = s.split(separator: "-")
        if parts.count >= 2 {
            return "\(parts[0])-\(parts[1])…"
        }
        return String(s.prefix(13)) + "…"
    }

    private static func firstUUID(in tree: [String: Any], preferKeysMatching needles: [String]) -> String? {
        for (k, v) in tree {
            let keyHit = needles.contains { k.localizedCaseInsensitiveContains($0) }
            if let s = v as? String, looksLikeUUID(s), keyHit || needles.isEmpty { return s }
            if let sub = v as? [String: Any] {
                if keyHit, let found = firstAnyUUID(in: sub) { return found }
                if let found = firstUUID(in: sub, preferKeysMatching: needles) { return found }
            }
        }
        return nil
    }

    private static func firstAnyUUID(in tree: [String: Any]) -> String? {
        for (_, v) in tree {
            if let s = v as? String, looksLikeUUID(s) { return s }
            if let sub = v as? [String: Any], let found = firstAnyUUID(in: sub) { return found }
        }
        return nil
    }

    /// 改 lsdidentifiers：已有则改；没有则在首选路径创建最小 plist（对齐工具箱「未找到也生成」）
    @discardableResult
    private static func mutateLSIdentifiersPlist(
        createIfMissing: Bool,
        body: (inout [String: Any]) -> Bool,
        writtenPath: ((String) -> Void)? = nil
    ) -> Bool {
        var paths = resolveLSIdentifierPaths(createIfMissing: createIfMissing)
        guard !paths.isEmpty else { return false }

        var any = false
        var lastOK = ""
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var dict = readPlist(url) ?? ["Vendors": [String: Any](), "Advertisers": [String: Any]()]
            if body(&dict), writePlist(dict, to: url) {
                any = true
                lastOK = path
            }
        }
        if any { writtenPath?(lastOK) }
        return any
    }

    /// 兼容旧名
    @discardableResult
    private static func mutateExistingLSIdentifiersPlist(_ body: (inout [String: Any]) -> Bool) -> Bool {
        mutateLSIdentifiersPlist(createIfMissing: false, body: body)
    }

    private static func resolveLSIdentifierPaths(createIfMissing: Bool) -> [String] {
        let fm = FileManager.default
        var paths = Set(candidateIdentifierPlistPaths().filter { fm.fileExists(atPath: $0) })
        for root in [
            "/var/containers/Shared/SystemGroup",
            "/private/var/containers/Shared/SystemGroup",
            "/var/mobile/Library/Caches",
            "/private/var/mobile/Library/Caches",
            "/var/mobile/Library/Preferences",
            "/private/var/mobile/Library/Preferences"
        ] where fm.fileExists(atPath: root) {
            if let more = findFiles(namedHints: ["lsdidentifiers"], under: root, maxDepth: 5) {
                more.forEach { paths.insert($0) }
            }
        }
        if paths.isEmpty, createIfMissing {
            // 首选可写路径：mobile Library Caches
            let preferred = [
                "/var/mobile/Library/Caches/com.apple.lsdidentifiers.plist",
                "/private/var/mobile/Library/Caches/com.apple.lsdidentifiers.plist",
                "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile.shared_container/Library/Caches/com.apple.lsdidentifiers.plist"
            ]
            for p in preferred {
                let dir = (p as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: dir) {
                    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                }
                if fm.fileExists(atPath: dir) || (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil {
                    let empty: [String: Any] = ["Vendors": [String: Any](), "Advertisers": [String: Any]()]
                    if writePlist(empty, to: URL(fileURLWithPath: p)) {
                        paths.insert(p)
                        break
                    }
                }
            }
        }
        return Array(paths).sorted()
    }

    private static func candidateIdentifierPlistPaths() -> [String] {
        [
            "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile.shared_container/Library/Caches/com.apple.lsdidentifiers.plist",
            "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile.shared_container/Library/Caches/com.apple.lsdidentifiers.plist",
            "/var/mobile/Library/Caches/com.apple.lsdidentifiers.plist",
            "/private/var/mobile/Library/Caches/com.apple.lsdidentifiers.plist",
            "/var/mobile/Library/Preferences/com.apple.lsdidentifiers.plist",
            "/private/var/mobile/Library/Preferences/com.apple.lsdidentifiers.plist"
        ]
    }

    // MARK: - 进程

    @discardableResult
    private static func terminateApp(bundleID: String) -> Bool {
        // RunningBoard（工具箱同权）
        if let rbClass = NSClassFromString("RBProcessManager") as? NSObject.Type
            ?? NSClassFromString("RBSProcessHandle") as? NSObject.Type {
            _ = rbClass
        }
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return false
        }
        let defSel = NSSelectorFromString("defaultWorkspace")
        guard wsClass.responds(to: defSel),
              let ws = wsClass.perform(defSel)?.takeUnretainedValue() as? NSObject
        else { return false }

        let sels = [
            "terminateApplicationBundleIdentifier:withReason:andReport:andCompletion:",
            "_terminateApplicationWithBundleIdentifier:",
            "killApplication:withCompletion:"
        ]
        for name in sels {
            let sel = NSSelectorFromString(name)
            guard ws.responds(to: sel) else { continue }
            if name.contains("BundleIdentifier") || name.hasPrefix("_terminate") {
                _ = ws.perform(sel, with: bundleID)
                return true
            }
        }
        return false
    }

    // MARK: - Plist / 树工具

    private static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any]
        else { return nil }
        return dict
    }

    private static func writePlist(_ dict: [String: Any], to url: URL) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            // 再试 xml
            guard let xml = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            else { return false }
            return (try? xml.write(to: url, options: .atomic)) != nil
        }
    }

    private static func replaceUUIDValues(
        in tree: [String: Any],
        preferKeysMatching needles: [String],
        newValue: (String) -> String
    ) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in tree {
            if let sub = v as? [String: Any] {
                out[k] = replaceUUIDValues(in: sub, preferKeysMatching: needles, newValue: newValue)
            } else if let s = v as? String, looksLikeUUID(s) {
                let hit = needles.contains { k.localizedCaseInsensitiveContains($0) || s.localizedCaseInsensitiveContains($0) }
                out[k] = hit || needles.isEmpty ? newValue(s) : s
            } else {
                out[k] = v
            }
        }
        return out
    }

    private static func treeContains(_ tree: [String: Any], needle: String) -> Bool {
        for (_, v) in tree {
            if let s = v as? String, s == needle { return true }
            if let sub = v as? [String: Any], treeContains(sub, needle: needle) { return true }
        }
        return false
    }

    private static func looksLikeUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }

    /// 容器刷新后写回本地网络等 TCC，减少抖音弹「网络链接」授权框（工具箱刷新后常见副作用）
    private static func restoreAwemeNetworkTCC(bundleID: String) -> StepResult {
        let name = "网络权限回写"
        let services = [
            "kTCCServiceLocalNetwork",
            "LocalNetwork",
            "kTCCServiceLiverpool",
            "kTCCServicePasteboard",
            "kTCCServicePasteFromOtherApps"
        ]
        let clients = [bundleID, "com.ss.iphone.ugc.Aweme", "com.ss.iphone.ugc.Aweme.inhouse"]
        let paths = [
            "/private/var/mobile/Library/TCC/TCC.db",
            "/var/mobile/Library/TCC/TCC.db"
        ]
        var n = 0
        for path in paths where FileManager.default.fileExists(atPath: path) {
            n += grantTCC(dbPath: path, services: services, clients: clients)
        }
        return .init(
            name: name,
            ok: n > 0,
            detail: n > 0 ? "已回写 \(n) 条本地网络/相关权限" : "TCC 未写入（可在设置里手动允许本地网络）"
        )
    }

    private static func grantTCC(dbPath: String, services: [String], clients: [String]) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return 0 }
        defer { sqlite3_close(db) }
        let cols = pragmaColumns(db: db, table: "access")
        guard !cols.isEmpty else { return 0 }
        var changed = 0
        let now = Int(Date().timeIntervalSince1970)
        for service in services {
            for client in clients {
                let escS = service.replacingOccurrences(of: "'", with: "''")
                let escC = client.replacingOccurrences(of: "'", with: "''")
                _ = sqlite3_exec(db, "DELETE FROM access WHERE service='\(escS)' AND client='\(escC)';", nil, nil, nil)
                if cols.contains("auth_value") {
                    var fields = ["service", "client", "client_type", "auth_value"]
                    var values = ["'\(escS)'", "'\(escC)'", "0", "2"]
                    if cols.contains("auth_reason") { fields.append("auth_reason"); values.append("2") }
                    if cols.contains("auth_version") { fields.append("auth_version"); values.append("1") }
                    if cols.contains("last_modified") { fields.append("last_modified"); values.append("\(now)") }
                    if cols.contains("flags") { fields.append("flags"); values.append("0") }
                    let pairs = zip(fields, values).filter { cols.contains($0.0) }
                    let sql = "INSERT INTO access (\(pairs.map(\.0).joined(separator: ","))) VALUES (\(pairs.map(\.1).joined(separator: ",")));"
                    if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK { changed += 1 }
                } else if cols.contains("allowed") {
                    let sql = "INSERT INTO access (service, client, client_type, allowed, prompt_count) VALUES ('\(escS)','\(escC)',0,1,0);"
                    if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK { changed += 1 }
                }
            }
        }
        return changed
    }

    private static func findFiles(namedHints hints: [String], under root: String, maxDepth: Int) -> [String]? {
        var found: [String] = []
        func walk(_ path: String, depth: Int) {
            guard depth <= maxDepth else { return }
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
            for name in items {
                let full = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                let lower = name.lowercased()
                if hints.contains(where: { lower.contains($0.lowercased()) }), !isDir.boolValue {
                    found.append(full)
                }
                if isDir.boolValue { walk(full, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return found.isEmpty ? nil : found
    }
}
