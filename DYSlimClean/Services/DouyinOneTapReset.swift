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

    // MARK: - 1 刷新容器

    private struct ContainerRefresh {
        var step: StepResult
        var newPath: String?
    }

    /// 工具箱 refreshId：只动「当前 Bundle」的 Data 容器
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

            let mcmOK = updateMCMDatabase(
                bundleID: bundleID,
                oldUUID: oldUUID,
                newUUID: newUUID,
                newPath: newURL.path
            )
            let regOK = reregisterContainer(bundleID: bundleID, containerPath: newURL.path)

            var detail = "\(bundleID) · \(oldUUID.prefix(8))… → \(newUUID.prefix(8))…"
            if mcmOK { detail += " · MCM已更新" }
            else { detail += " · MCM未命中(目录+metadata已换)" }
            if regOK { detail += " · 已重注册" }

            return .init(step: .init(name: name, ok: true, detail: detail), newPath: newURL.path)
        } catch {
            return .init(
                step: .init(name: name, ok: false, detail: "重命名失败：\(error.localizedDescription)"),
                newPath: nil
            )
        }
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
        var candidates: [String] = [
            "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile_container_manager.shared/Library/Caches/com.apple.containermanagerd/containers.sqlite",
            "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile_container_manager.shared/Library/Caches/com.apple.containermanagerd/containers.sqlite",
            "/private/var/root/Library/MobileContainerManager/containers.sqlite",
            "/var/root/Library/MobileContainerManager/containers.sqlite",
            "/private/var/db/MobileContainerManager/containers.sqlite",
            "/var/db/MobileContainerManager/containers.sqlite"
        ]
        let fm = FileManager.default
        for root in ["/private/var/containers/Shared/SystemGroup", "/var/containers/Shared/SystemGroup"] {
            guard let groups = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for g in groups where g.lowercased().contains("container") || g.lowercased().contains("mobile_container") {
                let base = (root as NSString).appendingPathComponent(g)
                candidates.append(contentsOf: findFiles(namedHints: ["containers.sqlite"], under: base, maxDepth: 5) ?? [])
            }
        }

        var touched = false
        for path in Set(candidates) where fm.fileExists(atPath: path) {
            if patchSQLiteReplace(path: path, oldUUID: oldUUID, newUUID: newUUID, newPath: newPath, bundleID: bundleID) {
                touched = true
            }
        }
        return touched
    }

    private static func patchSQLiteReplace(path: String, oldUUID: String, newUUID: String, newPath: String, bundleID: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { return false }
        defer { sqlite3_close(db) }

        let escapedPath = newPath.replacingOccurrences(of: "'", with: "''")
        var any = false

        // 固定常见语句
        let sqls = [
            "UPDATE Containers SET uuid='\(newUUID)', path='\(escapedPath)' WHERE uuid='\(oldUUID)';",
            "UPDATE Containers SET UUID='\(newUUID)', Path='\(escapedPath)' WHERE UUID='\(oldUUID)';",
            "UPDATE containers SET uuid='\(newUUID)', path='\(escapedPath)' WHERE uuid='\(oldUUID)';",
            "UPDATE CodeSigningEntries SET data_container_uuid='\(newUUID)' WHERE data_container_uuid='\(oldUUID)';",
            "UPDATE CodeSigningEntries SET data_container_uuid='\(newUUID)' WHERE identifier='\(bundleID)';"
        ]
        for sql in sqls {
            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, sqlite3_changes(db) > 0 { any = true }
        }

        // 动态：所有表里文本列含旧 UUID 的替换
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
                let sql1 = "UPDATE \"\(table)\" SET \"\(col)\"='\(newUUID)' WHERE \"\(col)\"='\(oldUUID)';"
                if sqlite3_exec(db, sql1, nil, nil, nil) == SQLITE_OK, sqlite3_changes(db) > 0 { any = true }
                // 路径字段
                let sql2 = "UPDATE \"\(table)\" SET \"\(col)\"='\(escapedPath)' WHERE \"\(col)\" LIKE '%\(oldUUID)%';"
                if col.lowercased().contains("path") {
                    if sqlite3_exec(db, sql2, nil, nil, nil) == SQLITE_OK, sqlite3_changes(db) > 0 { any = true }
                }
            }
        }
        return any
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

    /// 对齐 Fuck：`cleanKeychainForBundleId:` —— SecItem 删除抖音相关项（删后 App 会重建新标识）
    private static func clearKeychain(bundleID: String) -> StepResult {
        let name = "清钥匙串"
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

        // 再按 AccessGroup = TeamID.bundle 强删一轮（设备指纹常挂这里）
        for team in ["UGCRJ42T19", "3JTPEA4UU7", ""] {
            let agrp = team.isEmpty ? bundleID : "\(team).\(bundleID)"
            for secClass in classes {
                let q: [String: Any] = [
                    kSecClass as String: secClass,
                    kSecAttrAccessGroup as String: agrp
                ]
                if SecItemDelete(q as CFDictionary) == errSecSuccess { deleted += 1 }
            }
        }

        let detail: String
        if deleted > 0 {
            detail = "已删除 \(deleted) 项钥匙串标识（Aweme/Team），下次启动会重建"
        } else {
            detail = "SecItem 无匹配（可能权限未生效或本就为空）；已尝试 TeamID.AccessGroup 强删"
        }
        return .init(name: name, ok: true, detail: detail)
    }

    private static func keychainKeywords(bundleID: String) -> [String] {
        // 收紧：避免 idfa/idfv 等泛词误伤其它 App / 改机写入
        [
            bundleID,
            "com.ss.iphone.ugc.Aweme",
            "aweme",
            "Aweme",
            "bytedance",
            "ByteDance",
            "ss.iphone.ugc",
            "UGCRJ42T19",
            "3JTPEA4UU7"
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
            kSecReturnAttributes as String: true
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

    // MARK: - 3 刷新标识符（Vendor / IDFV）

    /// 对齐工具箱 refreshUUID：有则改，没有就按 Bundle/Team 键写入（工具箱也会「生成新的」）
    private static func refreshVendorIdentifier(bundleID: String) -> StepResult {
        let name = "刷新标识符"
        let newVendor = UUID().uuidString.uppercased()
        let needles = vendorNeedles(bundleID: bundleID)

        var oldShown = "未找到"
        let touched = mutateExistingLSIdentifiersPlist { dict in
            var vendors = (dict["Vendors"] as? [String: Any]) ?? [:]
            let before = firstUUID(in: vendors, preferKeysMatching: needles) ?? firstAnyUUID(in: vendors)
            if let before { oldShown = before }

            let replaced = replaceUUIDValues(in: vendors, preferKeysMatching: needles, newValue: { _ in newVendor })
            if treeContains(replaced, needle: newVendor) {
                vendors = replaced
            } else {
                // 工具箱行为：没匹配到抖音键也照样写入，让系统下次读到新 IDFV
                vendors = upsertVendorKeys(vendors, bundleID: bundleID, uuid: newVendor)
            }
            dict["Vendors"] = vendors
            // 部分系统也会在根上挂 vendor 字符串
            if let root = dict["Vendor"] as? String, looksLikeUUID(root) {
                dict["Vendor"] = newVendor
            }
            return treeContains(vendors, needle: newVendor) || (dict["Vendor"] as? String) == newVendor
        }

        let tip = touched
            ? "旧 \(shortUUID(oldShown)) → 新 \(shortUUID(newVendor))"
            : "未写入 Vendor（lsdidentifiers 不可写/不存在）"
        return .init(name: name, ok: touched, detail: tip)
    }

    // MARK: - 4 刷新广告符（Advertiser / IDFA）

    /// 对齐工具箱：广告符「未找到」时仍会生成新 IDFA（截图里刷新前=未找到，刷新后仍有新值）
    private static func refreshAdvertisingIdentifier(bundleID: String) -> StepResult {
        let name = "刷新广告符"
        let newAd = UUID().uuidString.uppercased()
        var oldShown = "未找到"

        let touched = mutateExistingLSIdentifiersPlist { dict in
            var ads = (dict["Advertisers"] as? [String: Any]) ?? [:]
            if let old = firstAnyUUID(in: ads) ?? (dict["Advertiser"] as? String).flatMap({ looksLikeUUID($0) ? $0 : nil }) {
                oldShown = old
            }

            if !ads.isEmpty {
                ads = replaceUUIDValues(in: ads, preferKeysMatching: [], newValue: { _ in newAd })
            }
            // 没有 Advertisers / 没有 UUID 可替换 → 直接新建（工具箱同款）
            if !treeContains(ads, needle: newAd) {
                ads[bundleID] = newAd
                ads["Advertiser"] = newAd
                if ads["Default"] == nil { ads["Default"] = newAd }
            }
            dict["Advertisers"] = ads
            dict["Advertiser"] = newAd
            return true
        }

        let tip = touched
            ? "旧 \(shortUUID(oldShown)) → 新 \(shortUUID(newAd))"
            : "未写入 Advertisers（lsdidentifiers 不可写/不存在）"
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
        guard s.count >= 8, s != "未找到" else { return s }
        return String(s.prefix(8)) + "…"
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

    /// 只改磁盘上「已经存在」的 lsdidentifiers；绝不批量造假路径文件
    @discardableResult
    private static func mutateExistingLSIdentifiersPlist(_ body: (inout [String: Any]) -> Bool) -> Bool {
        let fm = FileManager.default
        var paths = Set(candidateIdentifierPlistPaths().filter { fm.fileExists(atPath: $0) })
        // RootHide / 多 SystemGroup：再扫一层已有目录里的同名文件
        for root in [
            "/var/containers/Shared/SystemGroup",
            "/private/var/containers/Shared/SystemGroup",
            "/var/mobile/Library/Caches",
            "/private/var/mobile/Library/Caches"
        ] where fm.fileExists(atPath: root) {
            if let more = findFiles(namedHints: ["lsdidentifiers"], under: root, maxDepth: 4) {
                more.forEach { paths.insert($0) }
            }
        }
        guard !paths.isEmpty else { return false }

        var any = false
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard var dict = readPlist(url) else { continue }
            if body(&dict), writePlist(dict, to: url) {
                any = true
            }
        }
        return any
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
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return false
        }
        let defSel = NSSelectorFromString("defaultWorkspace")
        guard wsClass.responds(to: defSel),
              let ws = wsClass.perform(defSel)?.takeUnretainedValue() as? NSObject
        else { return false }

        let sels = [
            "terminateApplicationBundleIdentifier:withReason:andReport:andCompletion:",
            "_terminateApplicationWithBundleIdentifier:"
        ]
        for name in sels {
            let sel = NSSelectorFromString(name)
            guard ws.responds(to: sel) else { continue }
            if name.hasPrefix("_terminate") {
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
