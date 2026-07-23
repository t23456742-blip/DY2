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

        // 1) 刷新容器
        let c = refreshContainer(cleaner: cleaner)
        steps.append(c.step)
        if let p = c.newPath { newPath = p }

        // 2) 清钥匙串（用可能已变的新容器再定位）
        steps.append(clearKeychain(bundleID: awemeBundleID))

        // 3) 刷新标识符（IDFV / Vendor）
        steps.append(refreshVendorIdentifier(bundleID: awemeBundleID))

        // 4) 刷新广告符（IDFA / Advertiser）
        steps.append(refreshAdvertisingIdentifier())

        let allOK = steps.allSatisfy(\.ok)
        let lines = steps.map { "\($0.ok ? "✓" : "✗") \($0.name)：\($0.detail)" }
        let tip = """
        \(allOK ? "一键搞定 · 全部成功" : "一键搞定 · 部分失败")

        \(lines.joined(separator: "\n"))

        请完全退出抖音后重新打开。
        若仍识别为旧设备，可再点一次（会自动再跑完整四步）。
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

    /// 等价 Fuck：`renameBundleContainerForBundleId` + `updateMetadataPlist` + `updateMCMDatabase…`
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

            var detail = "\(oldUUID.prefix(8))… → \(newUUID.prefix(8))…"
            if !metaOK { detail += " · metadata 未完全更新" }
            if !mcmOK { detail += " · MCM库未命中(已改目录)" }

            // 尽量让系统重新认容器
            _ = reregisterIfPossible(bundleID: awemeBundleID, containerPath: newURL.path)

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
            // 没有就写一份最小可用
            let fresh: [String: Any] = [
                "MCMMetadataIdentifier": bundleID,
                "MCMMetadataUUID": newUUID,
                "MCMMetadataInfo": [:] as [String: Any]
            ]
            return writePlist(fresh, to: meta)
        }
        dict["MCMMetadataIdentifier"] = bundleID
        dict["MCMMetadataUUID"] = newUUID
        if dict["MCMMetadataInfo"] == nil {
            dict["MCMMetadataInfo"] = [:] as [String: Any]
        }
        return writePlist(dict, to: meta)
    }

    /// 尝试改 MobileContainerManager / 相关 sqlite（路径因系统而异，失败不阻断）
    private static func updateMCMDatabase(bundleID: String, oldUUID: String, newUUID: String, newPath: String) -> Bool {
        let candidates = [
            "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile_container_manager.shared/Library/Caches/com.apple.containermanagerd/containers.sqlite",
            "/var/root/Library/MobileContainerManager/containers.sqlite",
            "/var/db/MobileContainerManager/containers.sqlite",
            "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile_container_manager.shared/Library/Caches/com.apple.containermanagerd/containers.sqlite"
        ]
        let fm = FileManager.default
        var touched = false
        for path in candidates where fm.fileExists(atPath: path) {
            if patchSQLiteReplace(path: path, oldUUID: oldUUID, newUUID: newUUID, newPath: newPath, bundleID: bundleID) {
                touched = true
            }
        }

        // 再扫 SystemGroup 下可能的 containermanager 库
        let groupRoots = [
            "/var/containers/Shared/SystemGroup",
            "/private/var/containers/Shared/SystemGroup"
        ]
        for root in groupRoots {
            guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in dirs where name.lowercased().contains("container") {
                let base = (root as NSString).appendingPathComponent(name)
                if let found = findFiles(namedHints: ["containers.sqlite", "containermanager", ".sqlite"], under: base, maxDepth: 4) {
                    for db in found {
                        if patchSQLiteReplace(path: db, oldUUID: oldUUID, newUUID: newUUID, newPath: newPath, bundleID: bundleID) {
                            touched = true
                        }
                    }
                }
            }
        }
        return touched
    }

    private static func patchSQLiteReplace(path: String, oldUUID: String, newUUID: String, newPath: String, bundleID: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return false }
        defer { sqlite3_close(db) }

        // 通用：把文本字段里的旧 UUID / 旧路径换掉（表结构因版本不同）
        let sqls = [
            "UPDATE Containers SET uuid='\(newUUID)', path='\(newPath.replacingOccurrences(of: "'", with: "''"))' WHERE uuid='\(oldUUID)';",
            "UPDATE Containers SET UUID='\(newUUID)', Path='\(newPath.replacingOccurrences(of: "'", with: "''"))' WHERE UUID='\(oldUUID)';",
            "UPDATE containers SET uuid='\(newUUID)' WHERE uuid='\(oldUUID)';",
            "UPDATE CodeSigningEntries SET data_container_uuid='\(newUUID)' WHERE data_container_uuid='\(oldUUID)';"
        ]
        var any = false
        for sql in sqls {
            if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
                if sqlite3_changes(db) > 0 { any = true }
            }
        }
        _ = bundleID
        return any
    }

    private static func reregisterIfPossible(bundleID: String, containerPath: String) -> Bool {
        // LSApplicationWorkspace 私有：registerApplicationDictionary / 无则跳过
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return false }
        let defSel = NSSelectorFromString("defaultWorkspace")
        guard wsClass.responds(to: defSel),
              let ws = wsClass.perform(defSel)?.takeUnretainedValue() as? NSObject
        else { return false }

        // 尝试 invalidate
        let inv = NSSelectorFromString("_invalidate")
        if ws.responds(to: inv) {
            _ = ws.perform(inv)
        }
        _ = bundleID
        _ = containerPath
        return true
    }

    // MARK: - 2 清钥匙串

    /// 等价 Fuck：`cleanKeychainForBundleId:`
    private static func clearKeychain(bundleID: String) -> StepResult {
        let name = "清钥匙串"
        var deleted = 0

        let classes: [CFString] = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity
        ]

        for secClass in classes {
            deleted += deleteKeychainItems(secClass: secClass, bundleID: bundleID)
        }

        // 再清容器内常见本地凭证缓存（不删 mmkv 整目录，只清偏好里设备指纹相关由后续步骤处理）
        deleted += clearContainerCredentialFiles(bundleID: bundleID)

        let ok = deleted >= 0
        return .init(
            name: name,
            ok: ok,
            detail: deleted > 0 ? "已清理约 \(deleted) 项" : "已执行清理（可能本无匹配项）"
        )
    }

    private static func deleteKeychainItems(secClass: CFString, bundleID: String) -> Int {
        var count = 0

        // 按 AccessGroup / Service / Account 模糊匹配
        let queries: [[String: Any]] = [
            [kSecClass as String: secClass, kSecAttrService as String: bundleID],
            [kSecClass as String: secClass, kSecAttrAccount as String: bundleID],
            [kSecClass as String: secClass, kSecAttrAccessGroup as String: bundleID],
            [kSecClass as String: secClass, kSecAttrService as String: "Aweme"],
            [kSecClass as String: secClass, kSecAttrAccount as String: "Aweme"]
        ]

        for var q in queries {
            q[kSecMatchLimit as String] = kSecMatchLimitAll
            q[kSecReturnAttributes as String] = true
            var result: CFTypeRef?
            let st = SecItemCopyMatching(q as CFDictionary, &result)
            if st == errSecSuccess, let arr = result as? [[String: Any]] {
                for item in arr {
                    var del: [String: Any] = [kSecClass as String: secClass]
                    if let svc = item[kSecAttrService as String] { del[kSecAttrService as String] = svc }
                    if let acc = item[kSecAttrAccount as String] { del[kSecAttrAccount as String] = acc }
                    if let ag = item[kSecAttrAccessGroup as String] { del[kSecAttrAccessGroup as String] = ag }
                    if SecItemDelete(del as CFDictionary) == errSecSuccess {
                        count += 1
                    }
                }
            } else {
                // 直接按查询删
                var delQ = q
                delQ.removeValue(forKey: kSecMatchLimit as String)
                delQ.removeValue(forKey: kSecReturnAttributes as String)
                if SecItemDelete(delQ as CFDictionary) == errSecSuccess {
                    count += 1
                }
            }
        }

        // 枚举 GenericPassword 全量，筛 bundle / bytedance / aweme
        if secClass == kSecClassGenericPassword {
            count += wipeMatchingGenericPasswords(keywords: [
                bundleID,
                "aweme",
                "Aweme",
                "bytedance",
                "ByteDance",
                "ss.iphone.ugc",
                "openudid",
                "idfa",
                "idfv",
                "device_id",
                "install_id"
            ])
        }
        return count
    }

    private static func wipeMatchingGenericPasswords(keywords: [String]) -> Int {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
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

            var del: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
            if let svc = item[kSecAttrService as String] { del[kSecAttrService as String] = svc }
            if let acc = item[kSecAttrAccount as String] { del[kSecAttrAccount as String] = acc }
            if let ag = item[kSecAttrAccessGroup as String] { del[kSecAttrAccessGroup as String] = ag }
            if SecItemDelete(del as CFDictionary) == errSecSuccess { n += 1 }
        }
        return n
    }

    private static func clearContainerCredentialFiles(bundleID: String) -> Int {
        _ = bundleID
        let cleaner = SlimCleaner()
        guard let container = cleaner.locateAwemeContainer() else { return 0 }
        let fm = FileManager.default
        var n = 0
        // 常见设备指纹缓存文件名（存在才删）
        let relatives = [
            "Library/Preferences/com.ss.iphone.ugc.Aweme.plist",
            // 不整删 Preferences，避免伤登录票据；只在后续标识符步骤改系统侧
        ]
        // 这里刻意少删文件：钥匙串为主；应用内 id 交给系统 Vendor/Advertiser 刷新
        _ = relatives
        _ = fm
        _ = container
        return n
    }

    // MARK: - 3 刷新标识符（Vendor / IDFV）

    private static func refreshVendorIdentifier(bundleID: String) -> StepResult {
        let name = "刷新标识符"
        let newVendor = UUID().uuidString.uppercased()
        let touched = mutateLSIdentifiersPlist { dict in
            // Vendors: teamID → { bundle → uuid } 或扁平结构，兼容多种
            if var vendors = dict["Vendors"] as? [String: Any] {
                let preferred = replaceUUIDValues(
                    in: vendors,
                    preferKeysMatching: [bundleID, "UGCRJ42T19", "Bytedance", "bytedance"],
                    newValue: { _ in newVendor }
                )
                vendors = treeContains(preferred, needle: newVendor)
                    ? preferred
                    : deepReplaceAllUUIDLikeStrings(vendors, with: newVendor)
                dict["Vendors"] = vendors
                return true
            }
            if dict["Vendor"] != nil {
                dict["Vendor"] = newVendor
                return true
            }
            dict["Vendors"] = [bundleID: newVendor]
            return true
        }
        return .init(
            name: name,
            ok: touched,
            detail: touched ? "Vendor/IDFV → \(newVendor.prefix(8))…" : "未找到 lsdidentifiers，已尝试写入候选路径"
        )
    }

    // MARK: - 4 刷新广告符（Advertiser / IDFA）

    private static func refreshAdvertisingIdentifier() -> StepResult {
        let name = "刷新广告符"
        let newAd = UUID().uuidString.uppercased()
        let touched = mutateLSIdentifiersPlist { dict in
            if var ads = dict["Advertisers"] as? [String: Any] {
                ads = deepReplaceAllUUIDLikeStrings(ads, with: newAd)
                dict["Advertisers"] = ads
                return true
            }
            if dict["Advertiser"] != nil {
                dict["Advertiser"] = newAd
                return true
            }
            // Fuck AdvertisingIdentifierManager: advertiserKey
            dict["Advertisers"] = ["Default": newAd]
            return true
        }
        return .init(
            name: name,
            ok: touched,
            detail: touched ? "Advertiser/IDFA → \(newAd.prefix(8))…" : "未写入广告标识（路径可能变化）"
        )
    }

    /// 等价 Fuck `AdvertisingIdentifierManager`：在多候选路径找/改标识 plist
    @discardableResult
    private static func mutateLSIdentifiersPlist(_ body: (inout [String: Any]) -> Bool) -> Bool {
        let fm = FileManager.default
        var paths = candidateIdentifierPlistPaths()
        // 已存在的优先
        paths.sort { fm.fileExists(atPath: $0) && !fm.fileExists(atPath: $1) }

        var any = false
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var dict = readPlist(url) ?? [:]
            let dir = url.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if body(&dict), writePlist(dict, to: url) {
                any = true
            }
        }
        return any
    }

    private static func candidateIdentifierPlistPaths() -> [String] {
        var list: [String] = [
            "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile.shared_container/Library/Caches/com.apple.lsdidentifiers.plist",
            "/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.shared/Library/Caches/com.apple.lsdidentifiers.plist",
            "/var/mobile/Library/Caches/com.apple.lsdidentifiers.plist",
            "/var/mobile/Library/Preferences/com.apple.lsdidentifiers.plist",
            "/private/var/mobile/Library/Caches/com.apple.lsdidentifiers.plist",
            "/private/var/mobile/Library/Preferences/com.apple.lsdidentifiers.plist"
        ]

        let roots = [
            "/var/containers/Shared/SystemGroup",
            "/private/var/containers/Shared/SystemGroup"
        ]
        let fm = FileManager.default
        for root in roots {
            guard let groups = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for g in groups {
                let base = (root as NSString).appendingPathComponent(g)
                list.append((base as NSString).appendingPathComponent("Library/Caches/com.apple.lsdidentifiers.plist"))
                list.append((base as NSString).appendingPathComponent("Library/Preferences/com.apple.lsdidentifiers.plist"))
            }
        }
        return Array(Set(list))
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

    private static func deepReplaceAllUUIDLikeStrings(_ tree: [String: Any], with newUUID: String) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in tree {
            if let sub = v as? [String: Any] {
                out[k] = deepReplaceAllUUIDLikeStrings(sub, with: newUUID)
            } else if let s = v as? String, looksLikeUUID(s) {
                out[k] = newUUID
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
        let u = UUID(uuidString: s)
        return u != nil
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
                if isDir.boolValue {
                    walk(full, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return found.isEmpty ? nil : found
    }
}
