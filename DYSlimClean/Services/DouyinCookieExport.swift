import Foundation

/// 全量导出 Cookies → PC 隔离浏览器导入
/// ①系统 Safari / 自带浏览器 Cookies.binarycookies（创作者中心等网页全量，不过滤）
/// ②抖音 App 沙盒 Cookies（原样，不过滤 SSID）
/// ③Preferences 会话字段仅作补充
enum DouyinCookieExport {
    static let outDirs = [
        "/private/var/mobile/Media/dyck",
        "/var/mobile/Media/dyck",
        "/private/var/mobile/Media/dysession",
        "/var/mobile/Media/dysession"
    ]

    struct CookieItem: Sendable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
        var secure: Bool
        var httpOnly: Bool
        var source: String
    }

    struct Outcome: Sendable {
        var ok: Bool
        var message: String
        var count: Int
        var jsonPath: String
        var netscapePath: String
        var headerPath: String
        var zipPath: String
    }

    static func export(cleaner: SlimCleaner) -> Outcome {
        guard let outDir = firstWritableDir() else {
            return .init(ok: false, message: "无法创建 Media/dyck 目录", count: 0, jsonPath: "", netscapePath: "", headerPath: "", zipPath: "")
        }

        var cookies: [CookieItem] = []
        var rawCookieFiles: [(entry: String, file: URL)] = []
        var safariCount = 0
        var awemeCount = 0
        var synthCount = 0

        // 1) Safari / 系统浏览器 — 全量原样
        let safariFiles = locateAllBinaryCookieFiles()
        for f in safariFiles {
            let parsed = BinaryCookiesParser.parse(fileURL: f).map {
                CookieItem(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                           expires: $0.expires, secure: $0.secure, httpOnly: $0.httpOnly, source: "safari")
            }
            cookies.append(contentsOf: parsed)
            safariCount += parsed.count
            rawCookieFiles.append(("raw/\(safeEntryName(f))", f))
        }

        // 2) 抖音沙盒 — 全量原样
        if let container = cleaner.locateAwemeContainer() {
            let aweme = collectCookies(from: container, source: "aweme")
            cookies.append(contentsOf: aweme)
            awemeCount = aweme.count
            let cookieDir = container.appendingPathComponent("Library/Cookies")
            if let items = try? FileManager.default.contentsOfDirectory(at: cookieDir, includingPropertiesForKeys: nil) {
                for u in items where u.lastPathComponent.lowercased().contains("cookie") {
                    rawCookieFiles.append(("raw/aweme_\(u.lastPathComponent)", u))
                }
            }
            let synth = synthesizeFromPreferences(container: container)
            cookies.append(contentsOf: synth)
            synthCount = synth.count
        }

        cookies = dedupe(cookies)

        guard !cookies.isEmpty else {
            return .init(
                ok: false,
                message: "未读到任何 Cookies。\n请先用手机自带 Safari 打开并登录 https://creator.douyin.com ，再点导出。\n系统路径：/var/mobile/Library/Cookies/",
                count: 0, jsonPath: "", netscapePath: "", headerPath: "", zipPath: ""
            )
        }

        let stamp = stampString()
        let jsonURL = outDir.appendingPathComponent("\(stamp)_full_ck.json")
        let nsURL = outDir.appendingPathComponent("\(stamp)_full_ck_netscape.txt")
        let hdrURL = outDir.appendingPathComponent("\(stamp)_full_ck_header.txt")
        let readmeURL = outDir.appendingPathComponent("\(stamp)_导入说明.txt")
        let manURL = outDir.appendingPathComponent("\(stamp)_manifest.json")
        let zipURL = outDir.appendingPathComponent("\(stamp)_dyck.zip")

        do {
            try makeCookieEditorJSON(cookies).write(to: jsonURL, options: .atomic)
            try makeNetscape(cookies).write(to: nsURL, atomically: true, encoding: .utf8)
            try makeHeaderString(cookies).write(to: hdrURL, atomically: true, encoding: .utf8)
            try makeReadme(total: cookies.count, safari: safariCount, aweme: awemeCount, synth: synthCount, zipName: zipURL.lastPathComponent)
                .write(to: readmeURL, atomically: true, encoding: .utf8)

            let domains = Set(cookies.map { normalizeDomain($0.domain).lowercased() }).sorted()
            let manifest: [String: Any] = [
                "format": "dyck-v2-full",
                "stamp": stamp,
                "count": cookies.count,
                "safariCount": safariCount,
                "awemeCount": awemeCount,
                "synthCount": synthCount,
                "domains": Array(domains.prefix(80)),
                "cookies": "cookies.json",
                "note": "Full Safari+Aweme cookies; import ZIP in DY PC Web Injector"
            ]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: manURL, options: .atomic)

            var pairs: [(entry: String, file: URL)] = [
                ("cookies.json", jsonURL),
                ("netscape.txt", nsURL),
                ("header.txt", hdrURL),
                ("manifest.json", manURL),
                ("导入说明.txt", readmeURL)
            ]
            pairs.append(contentsOf: rawCookieFiles)
            _ = try ZipMaxWriter.writeFileList(pairs, to: zipURL)

            var tip = "全量 CK 导出完成：共 \(cookies.count) 条\n"
            tip += "· Safari/系统浏览器：\(safariCount)\n"
            tip += "· 抖音 App 沙盒：\(awemeCount)\n"
            tip += "· Preferences 补充：\(synthCount)\n"
            tip += "· 原始 binarycookies 已打进 ZIP\n\n"
            tip += "★★ ZIP 路径 ★★\n\(zipURL.path)\n\n"
            tip += "域示例：\(domains.prefix(12).joined(separator: ", "))\n"
            tip += "用法：PC「DY网页注入器」→ 导入该 ZIP（全量，不筛 SSID）"

            return .init(ok: true, message: tip, count: cookies.count, jsonPath: jsonURL.path, netscapePath: nsURL.path, headerPath: hdrURL.path, zipPath: zipURL.path)
        } catch {
            return .init(ok: false, message: "写出失败：\(error.localizedDescription)", count: cookies.count, jsonPath: "", netscapePath: "", headerPath: "", zipPath: "")
        }
    }

    // MARK: - Collect

    private static func locateAllBinaryCookieFiles() -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        var seen = Set<String>()

        func add(_ path: String) {
            let u = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: u.path) else { return }
            let key = u.standardizedFileURL.path
            if seen.insert(key).inserted { files.append(u) }
        }
        func addDir(_ dir: String) {
            let d = URL(fileURLWithPath: dir, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { return }
            for u in items {
                let n = u.lastPathComponent.lowercased()
                if n.hasSuffix(".binarycookies") || n == "cookies.binarycookies" {
                    add(u.path)
                }
            }
        }

        [
            "/var/mobile/Library/Cookies/Cookies.binarycookies",
            "/private/var/mobile/Library/Cookies/Cookies.binarycookies",
            "/var/root/Library/Cookies/Cookies.binarycookies"
        ].forEach(add)

        [
            "/var/mobile/Library/Cookies",
            "/private/var/mobile/Library/Cookies",
            "/var/mobile/Library/WebKit/WebsiteData/Cookies",
            "/private/var/mobile/Library/WebKit/WebsiteData/Cookies"
        ].forEach(addDir)

        for bid in ["com.apple.mobilesafari", "com.apple.SafariViewService"] {
            if let root = AppContainerLocator.locateViaProxy(bid) ?? AppContainerLocator.locateViaMetadata(bid) {
                addDir(root.appendingPathComponent("Library/Cookies").path)
                addDir(root.appendingPathComponent("Library/WebKit/WebsiteData/Cookies").path)
            }
        }
        return files
    }

    private static func collectCookies(from container: URL, source: String) -> [CookieItem] {
        let fm = FileManager.default
        var out: [CookieItem] = []
        let dirs = [
            container.appendingPathComponent("Library/Cookies"),
            container.appendingPathComponent("Library/WebKit/WebsiteData/Cookies")
        ]
        for cookieDir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: cookieDir, includingPropertiesForKeys: nil) else { continue }
            for u in items {
                let n = u.lastPathComponent.lowercased()
                if n.hasSuffix(".binarycookies") || n.contains("cookie") {
                    out.append(contentsOf: BinaryCookiesParser.parse(fileURL: u).map {
                        CookieItem(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                                   expires: $0.expires, secure: $0.secure, httpOnly: $0.httpOnly, source: source)
                    })
                }
            }
        }
        return out
    }

    private static func synthesizeFromPreferences(container: URL) -> [CookieItem] {
        var out: [CookieItem] = []
        let pref = container.appendingPathComponent("Library/Preferences/com.ss.iphone.ugc.Aweme.plist")
        guard let data = try? Data(contentsOf: pref),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return out
        }

        func add(_ name: String, _ value: String, domain: String) {
            guard !value.isEmpty else { return }
            out.append(.init(name: name, value: value, domain: domain, path: "/",
                             expires: Date().addingTimeInterval(86400 * 30),
                             secure: true, httpOnly: false, source: "prefs"))
        }

        if let tok = root["bdaccount_session_x_tt_token"] as? String, !tok.isEmpty {
            add("x_tt_token", tok, domain: ".douyin.com")
            add("x_tt_token", tok, domain: ".snssdk.com")
        }
        for (k, v) in root {
            guard let s = v as? String, !s.isEmpty, s.count < 8000 else { continue }
            let low = k.lowercased()
            if low.contains("session") || low.contains("sid_") || low.contains("uid_tt")
                || low.contains("ttwid") || low.contains("passport") || low.contains("odin")
                || low.contains("csrf") || low.contains("token") || low.contains("cookie") {
                let name = (k as NSString).lastPathComponent
                add(name, s, domain: ".douyin.com")
                add(name, s, domain: ".snssdk.com")
                add(name, s, domain: ".creator.douyin.com")
            }
        }
        return out
    }

    private static func dedupe(_ items: [CookieItem]) -> [CookieItem] {
        var map: [String: CookieItem] = [:]
        for c in items {
            let key = "\(c.domain.lowercased())|\(c.path)|\(c.name)"
            if let old = map[key] {
                if c.value.count > old.value.count {
                    map[key] = c
                } else if c.value.count == old.value.count, c.source == "safari", old.source != "safari" {
                    map[key] = c
                }
            } else {
                map[key] = c
            }
        }
        return Array(map.values).sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }
    }

    private static func safeEntryName(_ url: URL) -> String {
        let p = url.path.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "")
        if p.count > 120 { return String(p.suffix(120)) }
        return p.isEmpty ? url.lastPathComponent : p
    }

    // MARK: - Formats

    private static func makeCookieEditorJSON(_ cookies: [CookieItem]) throws -> Data {
        var arr: [[String: Any]] = []
        for c in cookies {
            var obj: [String: Any] = [
                "name": c.name,
                "value": c.value,
                "domain": normalizeDomain(c.domain),
                "path": c.path.isEmpty ? "/" : c.path,
                "secure": c.secure,
                "httpOnly": c.httpOnly,
                "session": c.expires == nil,
                "storeId": "0",
                "sameSite": "no_restriction",
                "source": c.source
            ]
            if let exp = c.expires {
                obj["expirationDate"] = exp.timeIntervalSince1970
            } else {
                obj["expirationDate"] = Date().addingTimeInterval(86400 * 60).timeIntervalSince1970
            }
            arr.append(obj)
        }
        return try JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
    }

    private static func makeNetscape(_ cookies: [CookieItem]) -> String {
        var lines = ["# Netscape HTTP Cookie File", "# DY助手全量导出 Safari+Aweme", ""]
        for c in cookies {
            let domain = normalizeDomain(c.domain)
            let flag = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let path = c.path.isEmpty ? "/" : c.path
            let secure = c.secure ? "TRUE" : "FALSE"
            let exp = Int((c.expires ?? Date().addingTimeInterval(86400 * 60)).timeIntervalSince1970)
            lines.append("\(domain)\t\(flag)\t\(path)\t\(secure)\t\(exp)\t\(c.name)\t\(c.value)")
        }
        return lines.joined(separator: "\n")
    }

    private static func makeHeaderString(_ cookies: [CookieItem]) -> String {
        var byDomain: [String: [CookieItem]] = [:]
        for c in cookies { byDomain[normalizeDomain(c.domain), default: []].append(c) }
        var parts = ["# Cookie Header 全量"]
        parts.append(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
        parts.append("")
        for (dom, list) in byDomain.sorted(by: { $0.key < $1.key }) {
            parts.append("# \(dom) (\(list.count))")
            parts.append(list.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
        }
        return parts.joined(separator: "\n")
    }

    private static func makeReadme(total: Int, safari: Int, aweme: Int, synth: Int, zipName: String) -> String {
        """
        DY助手 — 全量 CK（Safari + 抖音）
        总计 \(total)：Safari \(safari) / App \(aweme) / 补充 \(synth)

        建议先用手机 Safari 登录 https://creator.douyin.com 再导出。
        ZIP：\(zipName)
        PC：DY网页注入器 → 导入 ZIP（全量注入，不筛 SSID）
        """
    }

    private static func normalizeDomain(_ d: String) -> String {
        var s = d.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("http://") { s = String(s.dropFirst(7)) }
        if s.hasPrefix("https://") { s = String(s.dropFirst(8)) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.isEmpty || s == "." { return ".douyin.com" }
        return s
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
}

// MARK: - binarycookies

enum BinaryCookiesParser {
    struct Parsed {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
        var secure: Bool
        var httpOnly: Bool
    }

    static func parse(fileURL: URL) -> [Parsed] {
        guard let data = try? Data(contentsOf: fileURL), data.count > 8 else { return [] }
        guard String(data: data.prefix(4), encoding: .ascii) == "cook" else { return [] }

        var offset = 4
        guard offset + 4 <= data.count else { return [] }
        let pageCount = Int(readU32BE(data, offset)); offset += 4
        guard pageCount > 0, pageCount < 10_000, offset + pageCount * 4 <= data.count else { return [] }

        var pageSizes: [Int] = []
        for _ in 0..<pageCount {
            pageSizes.append(Int(readU32BE(data, offset)))
            offset += 4
        }

        var cookies: [Parsed] = []
        for size in pageSizes {
            guard size > 0, offset + size <= data.count else { break }
            cookies.append(contentsOf: parsePage(data.subdata(in: offset..<(offset + size))))
            offset += size
        }
        return cookies
    }

    private static func parsePage(_ page: Data) -> [Parsed] {
        guard page.count >= 8 else { return [] }
        let num = Int(readU32BE(page, 4))
        guard num > 0, num < 5000 else { return [] }
        var offsets: [Int] = []
        var o = 8
        for _ in 0..<num {
            guard o + 4 <= page.count else { break }
            offsets.append(Int(readU32BE(page, o)))
            o += 4
        }
        return offsets.compactMap { parseCookie(page, start: $0) }
    }

    private static func parseCookie(_ page: Data, start: Int) -> Parsed? {
        guard start >= 0, start + 56 <= page.count else { return nil }
        let size = Int(readU32LE(page, start))
        guard size >= 56, start + size <= page.count else { return nil }

        let flags = readU32LE(page, start + 8)
        let urlOff = Int(readU32LE(page, start + 16))
        let nameOff = Int(readU32LE(page, start + 20))
        let pathOff = Int(readU32LE(page, start + 24))
        let valueOff = Int(readU32LE(page, start + 28))
        let exp = readDoubleLE(page, start + 40)

        func cstr(_ rel: Int) -> String {
            let abs = start + rel
            guard abs >= start, abs < start + size else { return "" }
            var end = abs
            while end < start + size, page[end] != 0 { end += 1 }
            return String(data: page.subdata(in: abs..<end), encoding: .utf8)
                ?? String(data: page.subdata(in: abs..<end), encoding: .isoLatin1)
                ?? ""
        }

        let name = cstr(nameOff)
        guard !name.isEmpty else { return nil }
        let domain = cstr(urlOff)
        let path = cstr(pathOff)
        let value = cstr(valueOff)

        return .init(
            name: name,
            value: value,
            domain: domain.isEmpty ? "." : domain,
            path: path.isEmpty ? "/" : path,
            expires: exp > 0 ? Date(timeIntervalSinceReferenceDate: exp) : nil,
            secure: (flags & 1) != 0,
            httpOnly: (flags & 4) != 0
        )
    }

    private static func readU32BE(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
    }

    private static func readU32LE(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }

    private static func readDoubleLE(_ d: Data, _ o: Int) -> Double {
        var raw: UInt64 = 0
        for i in 0..<8 { raw |= UInt64(d[o + i]) << (8 * i) }
        return Double(bitPattern: raw)
    }
}
