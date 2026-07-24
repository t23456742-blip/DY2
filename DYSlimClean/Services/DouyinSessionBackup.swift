import Foundation

/// 精简「不掉线」备份/还原（改机三件套：雷神 / 雷蛇 / 其它改机均可）
/// 1) 改机参数（Thor 明文、雷蛇 .razr 加密包、lsdidentifiers 等，能扫到就带）
/// 2) 系统 Keychain（keychain-2.db*）
/// 3) 抖音号料（mmkv / AWEStorage / loginData / ttaccount / Cookies 等）
enum DouyinSessionBackup {
    static let outDirs = [
        "/private/var/mobile/Media/dysession",
        "/var/mobile/Media/dysession",
        "/private/var/mobile/Media/dyhc",
        "/var/mobile/Media/dyhc"
    ]

    struct Outcome: Sendable {
        var ok: Bool
        var path: String
        var message: String
        var fileCount: Int
        var hasParams: Bool
        var hasKeychain: Bool
        var hasAweme: Bool
    }

    // MARK: - 备份

    static func backup(cleaner: SlimCleaner) -> Outcome {
        guard let container = cleaner.locateAwemeContainer() else {
            return .init(ok: false, path: "", message: "未找到抖音容器", fileCount: 0, hasParams: false, hasKeychain: false, hasAweme: false)
        }
        guard let outDir = firstWritableDir() else {
            return .init(ok: false, path: "", message: "无法创建 dysession 目录", fileCount: 0, hasParams: false, hasKeychain: false, hasAweme: false)
        }

        let stamp = stampString()
        let zipURL = outDir.appendingPathComponent("\(stamp)_session.zip")
        var pairs: [(entry: String, file: URL)] = []
        var hasParams = false
        var hasKeychain = false
        var hasAweme = false

        // 1) Thor 参数 + 系统标识
        for (entry, url) in collectDeviceParamFiles(stamp: stamp) {
            pairs.append((entry, url))
            hasParams = true
        }

        // 2) Keychain
        for (entry, url) in collectKeychainFiles(stamp: stamp) {
            pairs.append((entry, url))
            hasKeychain = true
        }

        // 3) 抖音精简号料（H9 + 登录增强）
        let awemePairs = collectAwemeSessionFiles(container: container, stamp: stamp)
        pairs.append(contentsOf: awemePairs)
        hasAweme = !awemePairs.isEmpty

        // manifest
        if let manURL = writeManifest(
            stamp: stamp,
            hasParams: hasParams,
            hasKeychain: hasKeychain,
            hasAweme: hasAweme,
            awemeCount: awemePairs.count
        ) {
            pairs.insert(("\(stamp)/manifest.json", manURL), at: 0)
        }

        guard hasAweme else {
            return .init(ok: false, path: "", message: "抖音号料为空，取消备份", fileCount: 0, hasParams: hasParams, hasKeychain: hasKeychain, hasAweme: false)
        }

        do {
            let n = try ZipMaxWriter.writeFileList(pairs, to: zipURL)
            var tip = "精简会话备份完成（\(n) 个文件）\n→ \(zipURL.path)\n"
            tip += hasParams ? "✓ 已含改机参数（Thor/雷蛇等）\n" : "⚠ 未找到改机参数文件（本机若用雷蛇/雷神，确认已改机并生成参数）\n"
            tip += hasKeychain ? "✓ 已含 Keychain\n" : "⚠ 未读到 keychain-2.db\n"
            tip += "✓ 已含抖音登录精简号料\n"
            tip += "移机还原：新机先装好巨魔/改机环境，再点「还原会话」，最后划掉抖音重开。"
            return .init(ok: true, path: zipURL.path, message: tip, fileCount: n, hasParams: hasParams, hasKeychain: hasKeychain, hasAweme: hasAweme)
        } catch {
            return .init(ok: false, path: "", message: "打包失败：\(error.localizedDescription)", fileCount: 0, hasParams: hasParams, hasKeychain: hasKeychain, hasAweme: hasAweme)
        }
    }

    // MARK: - 还原

    static func restore(into cleaner: SlimCleaner, zipPath: String? = nil) -> Outcome {
        let fm = FileManager.default
        guard let container = cleaner.locateAwemeContainer() else {
            return .init(ok: false, path: "", message: "未找到抖音容器", fileCount: 0, hasParams: false, hasKeychain: false, hasAweme: false)
        }
        guard let zipURL = resolveZip(zipPath) else {
            return .init(ok: false, path: "", message: "未找到会话包（请先备份，或把 *_session.zip 放到 Media/dysession）", fileCount: 0, hasParams: false, hasKeychain: false, hasAweme: false)
        }

        _ = terminateAweme()

        do {
            let entries = try ZipSimpleReader.readEntries(zipURL)
            var written = 0
            var hasParams = false
            var hasKeychain = false
            var hasAweme = false
            var notes: [String] = []

            for e in entries {
                let name = e.name.replacingOccurrences(of: "\\", with: "/")
                if name.hasSuffix("/") || name.lowercased().hasSuffix("manifest.json") { continue }

                if let rel = deviceParamRel(name) {
                    if writeDeviceParam(entryName: name, fileName: rel, data: e.data) {
                        written += 1
                        hasParams = true
                    }
                    continue
                }
                if let rel = lsdRel(name) {
                    if writeToFirstExistingParent(candidates: lsdIdentifierCandidates(), fileName: (rel as NSString).lastPathComponent, data: e.data)
                        || writeLsdFallback(fileName: (rel as NSString).lastPathComponent, data: e.data) {
                        written += 1
                        hasParams = true
                    }
                    continue
                }
                if name.localizedCaseInsensitiveContains("Keychains/") || name.localizedCaseInsensitiveContains("keychain-2") {
                    if writeKeychainFile(entryName: name, data: e.data) {
                        written += 1
                        hasKeychain = true
                    }
                    continue
                }
                if let awemeRel = awemeRel(name) {
                    // 只还原会话相关路径，避免脏包乱写
                    if !isSessionPath(awemeRel) { continue }
                    let dest = container.appendingPathComponent(awemeRel)
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try e.data.write(to: dest, options: .atomic)
                    written += 1
                    hasAweme = true
                }
            }

            if !hasAweme {
                notes.append("未写入抖音号料")
            }
            if !hasParams {
                notes.append("未写入改机参数（无 Thor/雷蛇/lsdidentifiers 时，移机稳性下降）")
            }
            if !hasKeychain {
                notes.append("未写入 Keychain")
            }

            var tip = "会话还原完成：写入 \(written) 个文件 ← \(zipURL.lastPathComponent)\n"
            tip += hasParams ? "✓ 参数\n" : "✗ 参数\n"
            tip += hasKeychain ? "✓ Keychain\n" : "✗ Keychain\n"
            tip += hasAweme ? "✓ 抖音号料\n" : "✗ 抖音号料\n"
            if !notes.isEmpty {
                tip += notes.map { "· \($0)" }.joined(separator: "\n") + "\n"
            }
            tip += "请划掉抖音后重开。移机场景需新机改机参数与备份一致才能稳。"

            let ok = hasAweme && written > 0
            return .init(ok: ok, path: zipURL.path, message: tip, fileCount: written, hasParams: hasParams, hasKeychain: hasKeychain, hasAweme: hasAweme)
        } catch {
            return .init(ok: false, path: zipURL.path, message: "还原失败：\(error.localizedDescription)", fileCount: 0, hasParams: false, hasKeychain: false, hasAweme: false)
        }
    }

    // MARK: - Collect

    private static func collectDeviceParamFiles(stamp: String) -> [(String, URL)] {
        let fm = FileManager.default
        var out: [(String, URL)] = []
        var seen = Set<String>()

        let scanDirs = [
            "/var/mobile/Library/Preferences",
            "/private/var/mobile/Library/Preferences",
            "/var/mobile/Library/Thor",
            "/private/var/mobile/Library/Thor",
            "/var/mobile/Library/Razer",
            "/private/var/mobile/Library/Razer",
            "/var/mobile/Library/DeviceParams",
            "/private/var/mobile/Library/DeviceParams",
            "/var/mobile/Documents",
            "/private/var/mobile/Documents",
            "/var/jb/var/mobile/Library/Preferences",
            "/var/jb/Library/Preferences"
        ]

        for dir in scanDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else {
                // 目录不存在时仍尝试已知 Thor 文件名
                for name in knownThorNames {
                    let u = URL(fileURLWithPath: dir).appendingPathComponent(name)
                    if fm.fileExists(atPath: u.path) {
                        let entry = "\(stamp)/DeviceParams/\(name)"
                        if seen.insert(entry).inserted { out.append((entry, u)) }
                    }
                }
                continue
            }
            for name in items {
                guard isDeviceParamFileName(name) else { continue }
                let u = URL(fileURLWithPath: dir).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let entry = "\(stamp)/DeviceParams/\(name)"
                if seen.insert(entry).inserted {
                    out.append((entry, u))
                }
            }
        }

        for path in lsdIdentifierCandidates() where fm.fileExists(atPath: path) {
            let u = URL(fileURLWithPath: path)
            let entry = "\(stamp)/DeviceIdentity/\(u.lastPathComponent)"
            if seen.insert(entry).inserted {
                out.append((entry, u))
            }
        }
        return out
    }

    private static let knownThorNames = [
        "com.Thor.DeviceIfaddrs.plist",
        "com.Thor.DeviceParams.plist",
        "com.Thor.DeviceLocation.plist",
        "com.Thor.DeviceTarget.plist"
    ]

    /// Thor 明文 / 雷蛇加密 .razr / 常见改机偏好
    private static func isDeviceParamFileName(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.hasSuffix(".razr") || n.contains("_enc.razr") { return true }
        if name.hasPrefix("com.Thor.") { return true }
        if n.contains("razer") || n.contains("thor") { return true }
        if n.contains("deviceparams") || n.contains("deviceifaddrs")
            || n.contains("devicelocation") || n.contains("devicetarget") {
            return true
        }
        if n.contains("fakedevice") || n.contains("shadowtracker") || n.contains("hiddencam") {
            return true
        }
        return false
    }

    private static func collectKeychainFiles(stamp: String) -> [(String, URL)] {
        let fm = FileManager.default
        var out: [(String, URL)] = []
        let bases = [
            "/var/Keychains",
            "/private/var/Keychains",
            "/var/mobile/Library/Keychains",
            "/private/var/mobile/Library/Keychains"
        ]
        let names = ["keychain-2.db", "keychain-2.db-wal", "keychain-2.db-shm"]
        for base in bases {
            for name in names {
                let u = URL(fileURLWithPath: base).appendingPathComponent(name)
                if fm.fileExists(atPath: u.path) {
                    out.append(("\(stamp)/Keychains/\(name)", u))
                }
            }
        }
        return out
    }

    private static func collectAwemeSessionFiles(container: URL, stamp: String) -> [(String, URL)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: container,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        ) else { return [] }

        let rootPath = container.standardizedFileURL.path
        let prefix = "\(stamp)/com.ss.iphone.ugc.Aweme"
        var pairs: [(String, URL)] = []

        while let item = enumerator.nextObject() as? URL {
            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if vals?.isDirectory == true { continue }
            guard vals?.isRegularFile == true else { continue }
            let full = item.standardizedFileURL.path
            guard full.hasPrefix(rootPath) else { continue }
            var rel = String(full.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            rel = rel.replacingOccurrences(of: "\\", with: "/")
            if SlimCleaner.protectedNames.contains(item.lastPathComponent) { continue }
            // 只收会话相关路径，保证包体精简（对齐雷神号料，不整夹 Caches）
            guard isSessionPath(rel) else { continue }
            if isBulkyCache(rel) { continue }
            pairs.append(("\(prefix)/\(rel)", item))
        }
        return pairs
    }

    /// 登录会话必需/增强路径（比纯 H9 多 Cookies/passport/HTTPStorages）
    private static func isSessionPath(_ rel: String) -> Bool {
        let r = rel.replacingOccurrences(of: "\\", with: "/")
        let prefixes = [
            "Documents/mmkv",
            "Documents/_ttinstall_document",
            "Documents/ttaccount",
            "Documents/Aweme.db",
            "Documents/db.sqlite3",
            "Documents/server.json",
            "Documents/lsdata.plist",
            "Documents/hostcache",
            "Documents/tt_net_config",
            "Documents/com.bytedance.ies",
            "Documents/FeedbackRecorder",
            "Documents/IESPlayTimePredictModel",
            "Documents/uni_comm_cache",
            "Library/AWEStorage",
            "Library/loginData.dat",
            "Library/Preferences",
            "Library/SyncedPreferences",
            "Library/Cookies",
            "Library/passportStorage",
            "Library/HTTPStorages",
            "Library/Application Support/gurd_cache",
            "Library/AWEIMRoot"
        ]
        for p in prefixes {
            if r == p || r.hasPrefix(p) || r.hasPrefix(p + "/") { return true }
        }
        if SlimCleaner.documentsKeepFiles.contains(r) { return true }
        if SlimCleaner.libraryKeepFiles.contains(r) { return true }
        return false
    }

    private static func isBulkyCache(_ rel: String) -> Bool {
        let l = rel.lowercased()
        if l.hasPrefix("library/caches/") { return true }
        if l.contains("videocache") || l.contains("/offline") { return true }
        if l.hasPrefix("documents/com.bytedance.ies-effects") { return true }
        if l.contains("splashboard/snapshots") { return true }
        if l.hasPrefix("tmp/") { return true }
        return false
    }

    // MARK: - Write helpers

    private static func writeDeviceParam(entryName _: String, fileName: String, data: Data) -> Bool {
        let fm = FileManager.default
        let name = (fileName as NSString).lastPathComponent
        let lower = name.lowercased()
        var dirs = [
            "/var/mobile/Library/Preferences",
            "/private/var/mobile/Library/Preferences"
        ]
        if lower.hasSuffix(".razr") || lower.contains("razer") {
            dirs.insert(contentsOf: [
                "/var/mobile/Library/Razer",
                "/private/var/mobile/Library/Razer"
            ], at: 0)
        }
        if name.hasPrefix("com.Thor.") {
            dirs.append(contentsOf: [
                "/var/mobile/Library/Thor",
                "/private/var/mobile/Library/Thor"
            ])
        }
        var ok = false
        for dir in dirs {
            let dest = URL(fileURLWithPath: dir).appendingPathComponent(name)
            do {
                try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
                try data.write(to: dest, options: .atomic)
                ok = true
            } catch { continue }
        }
        return ok
    }

    private static func writeKeychainFile(entryName: String, data: Data) -> Bool {
        let name = (entryName as NSString).lastPathComponent
        let bases = [
            "/var/Keychains",
            "/private/var/Keychains"
        ]
        let fm = FileManager.default
        var ok = false
        for base in bases {
            do {
                try fm.createDirectory(at: URL(fileURLWithPath: base), withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: base).appendingPathComponent(name), options: .atomic)
                ok = true
            } catch { continue }
        }
        return ok
    }

    private static func writeToFirstExistingParent(candidates: [String], fileName: String, data: Data) -> Bool {
        let fm = FileManager.default
        for path in candidates {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            if fm.fileExists(atPath: dir.path) || path.hasSuffix(fileName) {
                let dest = dir.appendingPathComponent(fileName)
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try data.write(to: dest, options: .atomic)
                    return true
                } catch { continue }
            }
        }
        return false
    }

    private static func writeLsdFallback(fileName: String, data: Data) -> Bool {
        let paths = [
            "/var/mobile/Library/Caches/\(fileName)",
            "/private/var/mobile/Library/Caches/\(fileName)"
        ]
        for p in paths {
            let u = URL(fileURLWithPath: p)
            do {
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: u, options: .atomic)
                return true
            } catch { continue }
        }
        return false
    }

    private static func deviceParamRel(_ name: String) -> String? {
        let n = name.replacingOccurrences(of: "\\", with: "/")
        if n.contains("DeviceParams/") {
            return (n as NSString).lastPathComponent
        }
        let last = (n as NSString).lastPathComponent
        if isDeviceParamFileName(last) { return last }
        if let r = n.range(of: "com.Thor.", options: .caseInsensitive) {
            return String(n[r.lowerBound...])
        }
        return nil
    }

    private static func lsdRel(_ name: String) -> String? {
        let n = name.replacingOccurrences(of: "\\", with: "/")
        if n.contains("DeviceIdentity/") || n.lowercased().contains("lsdidentifiers") {
            return (n as NSString).lastPathComponent
        }
        return nil
    }

    private static func awemeRel(_ name: String) -> String? {
        var n = name.replacingOccurrences(of: "\\", with: "/")
        if let r = n.range(of: "com.ss.iphone.ugc.Aweme/", options: .caseInsensitive) {
            n = String(n[r.upperBound...])
            if n.hasPrefix("Documents/") || n.hasPrefix("Library/") || n.hasPrefix("tmp/") {
                return n
            }
        }
        return nil
    }

    private static func lsdIdentifierCandidates() -> [String] {
        [
            "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile.shared_container/Library/Caches/com.apple.lsdidentifiers.plist",
            "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobile.shared_container/Library/Caches/com.apple.lsdidentifiers.plist",
            "/var/mobile/Library/Caches/com.apple.lsdidentifiers.plist",
            "/private/var/mobile/Library/Caches/com.apple.lsdidentifiers.plist",
            "/var/mobile/Library/Preferences/com.apple.lsdidentifiers.plist",
            "/private/var/mobile/Library/Preferences/com.apple.lsdidentifiers.plist"
        ]
    }

    private static func terminateAweme() -> Bool {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return false }
        let defSel = NSSelectorFromString("defaultWorkspace")
        guard wsClass.responds(to: defSel),
              let ws = wsClass.perform(defSel)?.takeUnretainedValue() as? NSObject else { return false }
        let sel = NSSelectorFromString("_terminateApplicationWithBundleIdentifier:")
        if ws.responds(to: sel) {
            _ = ws.perform(sel, with: SlimCleaner.awemeBundleID)
            return true
        }
        return false
    }

    private static func writeManifest(stamp: String, hasParams: Bool, hasKeychain: Bool, hasAweme: Bool, awemeCount: Int) -> URL? {
        let dict: [String: Any] = [
            "format": "dysession-v1",
            "stamp": stamp,
            "bundle": SlimCleaner.awemeBundleID,
            "hasParams": hasParams,
            "hasKeychain": hasKeychain,
            "hasAweme": hasAweme,
            "awemeFileCount": awemeCount,
            "note": "params+keychain+aweme slim session; restore atomically for no-logout"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dysession_\(stamp)_manifest.json")
        try? data.write(to: url, options: .atomic)
        return url
    }

    private static func stampString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func firstWritableDir() -> URL? {
        let fm = FileManager.default
        for path in outDirs {
            let u = URL(fileURLWithPath: path, isDirectory: true)
            do {
                try fm.createDirectory(at: u, withIntermediateDirectories: true)
                return u
            } catch { continue }
        }
        return nil
    }

    private static func resolveZip(_ zipPath: String?) -> URL? {
        let fm = FileManager.default
        if let zipPath, fm.fileExists(atPath: zipPath) {
            return URL(fileURLWithPath: zipPath)
        }
        var zips: [URL] = []
        for path in outDirs {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for u in items {
                let n = u.lastPathComponent.lowercased()
                if n.hasSuffix(".zip"), n.contains("session") || path.contains("dysession") {
                    zips.append(u)
                }
            }
        }
        return zips.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }.first
    }
}
