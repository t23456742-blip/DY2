import Foundation
import Security
import SQLite3

/// 对照 Fuck 工具箱四项能力，合并为抖音「一键搞定」流水线。
///
/// 原版映射：
/// 1. 刷新容器  → renameBundleContainer / replaceContainerUUID / updateMCM / updateMetadataPlist
/// 2. 清钥匙串  → cleanKeychainForBundleId:
/// 3. 刷新标识符 → Vendors / IdentifierForVendor（系统 lsdidentifiers）
/// 4. 刷新广告符 → Advertisers / AdvertisingIdentifierManager
///
/// 固定顺序（用户指定）：容器 → 钥匙串 → 标识符 → 广告符
enum DouyinOneTapReset {
    static let awemeBundleID = SlimCleaner.awemeBundleID

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

    /// 执行完整四步；任一步失败仍尽量继续后面步骤，最终 ok=全部成功。
    static func run(cleaner: SlimCleaner) -> Result {
        var steps: [StepResult] = []
        var newPath: String?

        // 0) 先杀抖音，避免文件占用
        _ = terminateAweme()

        // 1) 刷新容器（失败则回滚，避免 MCM 仍指旧路径导致改机/抖音找不到容器）
        let c = refreshContainer(cleaner: cleaner)
        steps.append(c.step)
        if let p = c.newPath { newPath = p }

        // 2) 清钥匙串 —— 对齐 Fuck：只 SecItem，不动系统 keychain-2.db / 不删 Preferences
        steps.append(clearKeychain(bundleID: awemeBundleID))

        // 3) 刷新标识符（IDFV / Vendor）—— 只改抖音相关键，禁止整树乱刷
        steps.append(refreshVendorIdentifier(bundleID: awemeBundleID))

        // 4) 刷新广告符（IDFA）—— 只改已存在的 lsdidentifiers，禁止新建假 plist
        steps.append(refreshAdvertisingIdentifier())

        let allOK = steps.allSatisfy(\.ok)
        let lines = steps.map { "\($0.ok ? "✓" : "✗") \($0.name)：\($0.detail)" }
        let tip = """
        \(allOK ? "一键搞定 · 全部成功" : "一键搞定 · 部分失败")

        \(lines.joined(separator: "\n"))

        说明：与工具箱「刷新」一致，主要换设备标识；账号数据通常还在（不是清数据）。
        请划掉抖音后重开。若改机工具异常，勿反复点——本版已避免改系统钥匙串库/乱写标识文件。
        """
        return Result(
            ok: allOK,
            steps: steps,
            message: tip.trimmingCharacters(in: .whitespacesAndNewlines),
            newContainerPath: newPath
        )
    }

    // MARK: - 1 刷新容器

    private struct ContainerRefresh {
        var step: StepResult
        var newPath: String?
    }

    /// 对齐 Fuck：`renameBundleContainer` + `updateMetadataPlist` + `updateMCMDatabase`
    /// MCM 更新失败则目录改回，避免系统/改机仍指向已不存在的旧 UUID。
    private static func refreshContainer(cleaner: SlimCleaner) -> ContainerRefresh {
        let name = "刷新容器"
        guard let oldURL = cleaner.locateAwemeContainer() else {
            return .init(step: .init(name: name, ok: false, detail: "未找到抖音数据容器"), newPath: nil)
        }

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

            let metaOK = updateMetadataPlist(at: newURL, newUUID: newUUID, bundleID: awemeBundleID)
            let mcmOK = updateMCMDatabase(
                bundleID: awemeBundleID,
                oldUUID: oldUUID,
                newUUID: newUUID,
                newPath: newURL.path
            )

            if !mcmOK {
                // 回滚：否则 containermanager / 改机仍认旧路径 → 抖音/改机全乱
                try? fm.moveItem(at: newURL, to: oldURL)
                _ = updateMetadataPlist(at: oldURL, newUUID: oldUUID, bundleID: awemeBundleID)
                return .init(
                    step: .init(name: name, ok: false, detail: "MCM 库未更新，已回滚目录（避免路径损坏）"),
                    newPath: nil
                )
            }

            var detail = "\(oldUUID.prefix(8))… → \(newUUID.prefix(8))…"
            if !metaOK { detail += " · metadata 警告" }

            return .init(
                step: .init(name: name, ok: true, detail: detail),
                newPath: newURL.path
            )
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

    /// 只改已知 MCM 库路径，禁止扫整个 SystemGroup 乱改 sqlite
    private static func updateMCMDatabase(bundleID: String, oldUUID: String, newUUID: String, newPath: String) -> Bool {
        let candidates = [
            "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile_container_manager.shared/Library/Caches/com.apple.containermanagerd/containers.sqlite",
            "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile_container_manager.shared/Library/Caches/com.apple.containermanagerd/containers.sqlite",
            "/private/var/root/Library/MobileContainerManager/containers.sqlite",
            "/var/root/Library/MobileContainerManager/containers.sqlite"
        ]
        let fm = FileManager.default
        var touched = false
        for path in candidates where fm.fileExists(atPath: path) {
            if patchSQLiteReplace(path: path, oldUUID: oldUUID, newUUID: newUUID, newPath: newPath, bundleID: bundleID) {
                touched = true
            }
        }
        return touched
    }

    private static func patchSQLiteReplace(path: String, oldUUID: String, newUUID: String, newPath: String, bundleID: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return false }
        defer { sqlite3_close(db) }

        let escapedPath = newPath.replacingOccurrences(of: "'", with: "''")
        let sqls = [
            "UPDATE Containers SET uuid='\(newUUID)', path='\(escapedPath)' WHERE uuid='\(oldUUID)';",
            "UPDATE Containers SET UUID='\(newUUID)', Path='\(escapedPath)' WHERE UUID='\(oldUUID)';",
            "UPDATE containers SET uuid='\(newUUID)', path='\(escapedPath)' WHERE uuid='\(oldUUID)';",
            "UPDATE CodeSigningEntries SET data_container_uuid='\(newUUID)' WHERE data_container_uuid='\(oldUUID)';",
            "UPDATE CodeSigningEntries SET data_container_uuid='\(newUUID)' WHERE identifier='\(bundleID)' AND data_container_uuid='\(oldUUID)';"
        ]
        var any = false
        for sql in sqls {
            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, sqlite3_changes(db) > 0 {
                any = true
            }
        }
        return any
    }

    // MARK: - 2 清钥匙串

    /// 对齐 Fuck：`cleanKeychainForBundleId:` —— 只用 SecItem，不碰系统 keychain-2.db，不删 Preferences
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

        let detail = deleted > 0
            ? "SecItem 已删约 \(deleted) 项（仅抖音相关）"
            : "SecItem 已执行（当前无匹配项；账号数据不在此清）"
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
        var query: [String: Any] = [
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

    private static func refreshVendorIdentifier(bundleID: String) -> StepResult {
        let name = "刷新标识符"
        let newVendor = UUID().uuidString.uppercased()
        let needles = [bundleID, "UGCRJ42T19", "3JTPEA4UU7", "Bytedance", "bytedance", "Aweme", "aweme"]
        let touched = mutateExistingLSIdentifiersPlist { dict in
            guard var vendors = dict["Vendors"] as? [String: Any] else { return false }
            let updated = replaceUUIDValues(in: vendors, preferKeysMatching: needles, newValue: { _ in newVendor })
            // 禁止 deepReplace 整树：会把其它 App / 改机写入的 IDFV 一并改坏
            guard treeContains(updated, needle: newVendor) else { return false }
            dict["Vendors"] = updated
            return true
        }
        return .init(
            name: name,
            ok: touched,
            detail: touched ? "仅抖音相关 Vendor → \(newVendor.prefix(8))…" : "未改到抖音 Vendor 键（未动其它 App）"
        )
    }

    // MARK: - 4 刷新广告符（Advertiser / IDFA）

    private static func refreshAdvertisingIdentifier() -> StepResult {
        let name = "刷新广告符"
        let newAd = UUID().uuidString.uppercased()
        // IDFA 多为设备级一条；只改 Advertisers 下已有 UUID 值，且只写「已存在」的 plist
        let touched = mutateExistingLSIdentifiersPlist { dict in
            if var ads = dict["Advertisers"] as? [String: Any] {
                ads = replaceUUIDValues(in: ads, preferKeysMatching: [], newValue: { _ in newAd })
                // preferKeys 空：replaceUUIDValues 里 needles.isEmpty 时会替换所有 UUID —— 对 Advertisers 合理（设备级 IDFA）
                dict["Advertisers"] = ads
                return true
            }
            if dict["Advertiser"] != nil {
                dict["Advertiser"] = newAd
                return true
            }
            return false
        }
        return .init(
            name: name,
            ok: touched,
            detail: touched ? "Advertiser/IDFA → \(newAd.prefix(8))…" : "未找到已有 Advertisers（未新建假文件）"
        )
    }

    /// 只改磁盘上「已经存在」的 lsdidentifiers；绝不 createDirectory / 绝不批量写假 plist（会搞崩改机）
    @discardableResult
    private static func mutateExistingLSIdentifiersPlist(_ body: (inout [String: Any]) -> Bool) -> Bool {
        let fm = FileManager.default
        let existing = candidateIdentifierPlistPaths().filter { fm.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return false }

        var any = false
        for path in existing {
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
    private static func terminateAweme() -> Bool {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return false
        }
        let defSel = NSSelectorFromString("defaultWorkspace")
        guard wsClass.responds(to: defSel),
              let ws = wsClass.perform(defSel)?.takeUnretainedValue() as? NSObject
        else { return false }

        // terminateApplication:withOptions: / synchronize
        let sels = [
            "terminateApplicationBundleIdentifier:withReason:andReport:andCompletion:",
            "_terminateApplicationWithBundleIdentifier:"
        ]
        for name in sels {
            let sel = NSSelectorFromString(name)
            guard ws.responds(to: sel) else { continue }
            if name.hasPrefix("_terminate") {
                _ = ws.perform(sel, with: awemeBundleID)
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
}
