import Foundation

/// 从抖音沙盒提取 Cookies，导出 Chrome「Cookie-Editor」可导入的 JSON / Netscape / Header
/// 用法：PC 打开 douyin.com → Cookie-Editor → Import → 选文件或粘贴 → Save
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
        guard let container = cleaner.locateAwemeContainer() else {
            return .init(ok: false, message: "未找到抖音容器", count: 0, jsonPath: "", netscapePath: "", headerPath: "", zipPath: "")
        }
        guard let outDir = firstWritableDir() else {
            return .init(ok: false, message: "无法创建 Media/dyck 目录", count: 0, jsonPath: "", netscapePath: "", headerPath: "", zipPath: "")
        }

        var cookies = collectCookies(from: container)
        // 用 Preferences 里的会话字段补全（常见 web 关键名）
        cookies.append(contentsOf: synthesizeFromPreferences(container: container))
        cookies = dedupe(cookies)

        // 优先保留抖音网页相关域
        let webish = cookies.filter { isWebRelevant($0) }
        let exportList = webish.isEmpty ? cookies : webish

        guard !exportList.isEmpty else {
            return .init(
                ok: false,
                message: "未读到 Cookies。\n请确认抖音曾登录过、且未精简掉 Library/Cookies。\n可先点「备份会话」再试，或打开抖音登录一次后再导出。",
                count: 0, jsonPath: "", netscapePath: "", headerPath: "", zipPath: ""
            )
        }

        let stamp = stampString()
        let jsonURL = outDir.appendingPathComponent("\(stamp)_douyin_ck.json")
        let nsURL = outDir.appendingPathComponent("\(stamp)_douyin_ck_netscape.txt")
        let hdrURL = outDir.appendingPathComponent("\(stamp)_douyin_ck_header.txt")
        let readmeURL = outDir.appendingPathComponent("\(stamp)_导入说明.txt")
        let manURL = outDir.appendingPathComponent("\(stamp)_manifest.json")
        let zipURL = outDir.appendingPathComponent("\(stamp)_dyck.zip")

        do {
            let jsonData = try makeCookieEditorJSON(exportList)
            try jsonData.write(to: jsonURL, options: .atomic)
            try makeNetscape(exportList).write(to: nsURL, atomically: true, encoding: .utf8)
            try makeHeaderString(exportList).write(to: hdrURL, atomically: true, encoding: .utf8)
            try makeReadme(count: exportList.count, jsonName: jsonURL.lastPathComponent, zipName: zipURL.lastPathComponent)
                .write(to: readmeURL, atomically: true, encoding: .utf8)

            let manifest: [String: Any] = [
                "format": "dyck-v1",
                "stamp": stamp,
                "count": exportList.count,
                "cookies": "cookies.json",
                "note": "Import this ZIP in DY PC Web Injector"
            ]
            let manData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            try manData.write(to: manURL, options: .atomic)

            // PC 配套：一键 ZIP（解压后 cookies.json）
            let pairs: [(entry: String, file: URL)] = [
                ("cookies.json", jsonURL),
                ("netscape.txt", nsURL),
                ("header.txt", hdrURL),
                ("manifest.json", manURL),
                ("导入说明.txt", readmeURL)
            ]
            _ = try ZipMaxWriter.writeFileList(pairs, to: zipURL)

            let names = exportList.map(\.name).sorted().joined(separator: ", ")
            let hasSession = exportList.contains { $0.name.lowercased().contains("session") || $0.name == "sid_tt" || $0.name == "uid_tt" }
            var tip = "已导出 \(exportList.count) 条 CK\n"
            tip += "★★ ZIP（给 PC 注入器直接导入）★★\n"
            tip += "\(zipURL.path)\n\n"
            tip += "同目录零散文件：\n"
            tip += "· \(jsonURL.lastPathComponent)\n"
            tip += "· \(nsURL.lastPathComponent)\n"
            tip += "· \(hdrURL.lastPathComponent)\n"
            tip += "含：\(names.prefix(180))\(names.count > 180 ? "…" : "")\n"
            tip += hasSession ? "✓ 含 session/sid 类字段\n" : "⚠ 未见典型 sessionid/sid_tt，网页可能仍要扫码\n"
            tip += "PC：打开「DY网页注入器」→ 导入该 ZIP → 自动解压注入 → 打开抖音网页"

            return .init(
                ok: true,
                message: tip,
                count: exportList.count,
                jsonPath: jsonURL.path,
                netscapePath: nsURL.path,
                headerPath: hdrURL.path,
                zipPath: zipURL.path
            )
        } catch {
            return .init(ok: false, message: "写出失败：\(error.localizedDescription)", count: exportList.count, jsonPath: "", netscapePath: "", headerPath: "", zipPath: "")
        }
    }

    // MARK: - Collect

    private static func collectCookies(from container: URL) -> [CookieItem] {
        let fm = FileManager.default
        var out: [CookieItem] = []
        let cookieDir = container.appendingPathComponent("Library/Cookies")
        if let items = try? fm.contentsOfDirectory(at: cookieDir, includingPropertiesForKeys: nil) {
            for u in items {
                let n = u.lastPathComponent.lowercased()
                if n.hasSuffix(".binarycookies") || n == "cookies.binarycookies" {
                    out.append(contentsOf: BinaryCookiesParser.parse(fileURL: u))
                }
            }
        }
        // 个别版本放在 WebKit 网络存储旁
        let alt = container.appendingPathComponent("Library/WebKit/WebsiteData/Cookies")
        if let items = try? fm.contentsOfDirectory(at: alt, includingPropertiesForKeys: nil) {
            for u in items where u.pathExtension.lowercased() == "binarycookies" || u.lastPathComponent.lowercased().contains("cookie") {
                out.append(contentsOf: BinaryCookiesParser.parse(fileURL: u))
            }
        }
        return out
    }

    /// 从 Aweme.plist / token 等补可能用于网页的字段（合成 Cookie）
    private static func synthesizeFromPreferences(container: URL) -> [CookieItem] {
        var out: [CookieItem] = []
        let pref = container.appendingPathComponent("Library/Preferences/com.ss.iphone.ugc.Aweme.plist")
        guard let data = try? Data(contentsOf: pref),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return out
        }

        func add(_ name: String, _ value: String, domain: String = ".douyin.com") {
            guard !value.isEmpty else { return }
            out.append(.init(name: name, value: value, domain: domain, path: "/", expires: Date().addingTimeInterval(86400 * 30), secure: true, httpOnly: false))
        }

        if let tok = root["bdaccount_session_x_tt_token"] as? String, !tok.isEmpty {
            // 网页不直接吃 x-tt-token，但部分工具/油猴会用；同时写入 header 友好名
            add("x_tt_token", tok, domain: ".douyin.com")
            add("x_tt_token", tok, domain: ".snssdk.com")
        }

        // 扫 plist 字符串值里像 sessionid 的键
        let interesting = ["sessionid", "sessionid_ss", "sid_tt", "sid_guard", "uid_tt", "uid_tt_ss", "ttwid", "passport_csrf_token", "odin_tt"]
        for (k, v) in root {
            let key = k.lowercased()
            guard let s = v as? String, !s.isEmpty, s.count < 4000 else { continue }
            for name in interesting where key.contains(name) || k == name {
                add(name, s, domain: ".douyin.com")
                add(name, s, domain: ".snssdk.com")
            }
        }
        return out
    }

    private static func isWebRelevant(_ c: CookieItem) -> Bool {
        let d = c.domain.lowercased()
        let n = c.name.lowercased()
        if d.contains("douyin") || d.contains("snssdk") || d.contains("amemv") || d.contains("bytedance") || d.contains("iesdouyin") {
            return true
        }
        if n.contains("session") || n.contains("sid_") || n.contains("uid_tt") || n.contains("ttwid") || n.contains("passport") || n.contains("odin") {
            return true
        }
        return false
    }

    private static func dedupe(_ items: [CookieItem]) -> [CookieItem] {
        var map: [String: CookieItem] = [:]
        for c in items {
            let key = "\(c.domain.lowercased())|\(c.path)|\(c.name)"
            // 优先保留更长 value / 更晚过期
            if let old = map[key] {
                if c.value.count >= old.value.count { map[key] = c }
            } else {
                map[key] = c
            }
        }
        return Array(map.values).sorted { $0.name < $1.name }
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
                "sameSite": "no_restriction"
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
        var lines = [
            "# Netscape HTTP Cookie File",
            "# DY助手导出 — 可用于 Cookie-Editor / curl",
            ""
        ]
        for c in cookies {
            let domain = normalizeDomain(c.domain)
            let flag = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let path = c.path.isEmpty ? "/" : c.path
            let secure = c.secure ? "TRUE" : "FALSE"
            let exp = Int((c.expires ?? Date().addingTimeInterval(86400 * 60)).timeIntervalSince1970)
            // domain \t includeSubdomains \t path \t secure \t expiry \t name \t value
            lines.append("\(domain)\t\(flag)\t\(path)\t\(secure)\t\(exp)\t\(c.name)\t\(c.value)")
        }
        return lines.joined(separator: "\n")
    }

    private static func makeHeaderString(_ cookies: [CookieItem]) -> String {
        // 同名时后者覆盖；按域名分组也写一份
        var byDomain: [String: [CookieItem]] = [:]
        for c in cookies {
            byDomain[normalizeDomain(c.domain), default: []].append(c)
        }
        var parts: [String] = []
        parts.append("# Cookie Header（可整段贴到请求头 Cookie:）")
        let all = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        parts.append(all)
        parts.append("")
        for (dom, list) in byDomain.sorted(by: { $0.key < $1.key }) {
            parts.append("# \(dom)")
            parts.append(list.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
        }
        return parts.joined(separator: "\n")
    }

    private static func makeReadme(count: Int, jsonName: String, zipName: String) -> String {
        """
        DY助手 — 抖音 CK 转 PC 网页说明
        ================================
        已导出 \(count) 条 Cookie。

        ★ 推荐（配套注入器）：
        把 ZIP 拷到电脑：\(zipName)
        打开「DY网页注入器」→ 导入 ZIP → 自动解压注入 → 打开抖音

        手动（Cookie-Editor）：
        1. Chrome/Edge 装 Cookie-Editor
        2. 打开 https://www.douyin.com
        3. Import → \(jsonName) → Save → 刷新

        手机路径：/var/mobile/Media/dyck/
        CK 勿外传。
        """
    }

    private static func normalizeDomain(_ d: String) -> String {
        var s = d.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("http://") { s = String(s.dropFirst(7)) }
        if s.hasPrefix("https://") { s = String(s.dropFirst(8)) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.isEmpty { return ".douyin.com" }
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

// MARK: - iOS Cookies.binarycookies 解析

enum BinaryCookiesParser {
    static func parse(fileURL: URL) -> [DouyinCookieExport.CookieItem] {
        guard let data = try? Data(contentsOf: fileURL), data.count > 8 else { return [] }
        // magic "cook"
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

        var cookies: [DouyinCookieExport.CookieItem] = []
        for size in pageSizes {
            guard size > 0, offset + size <= data.count else { break }
            let page = data.subdata(in: offset..<(offset + size))
            cookies.append(contentsOf: parsePage(page))
            offset += size
        }
        return cookies
    }

    private static func parsePage(_ page: Data) -> [DouyinCookieExport.CookieItem] {
        guard page.count >= 8 else { return [] }
        // byte 0-3 often 0x00000100
        let num = Int(readU32BE(page, 4))
        guard num > 0, num < 5000 else { return [] }
        var offsets: [Int] = []
        var o = 8
        for _ in 0..<num {
            guard o + 4 <= page.count else { break }
            offsets.append(Int(readU32BE(page, o)))
            o += 4
        }
        var out: [DouyinCookieExport.CookieItem] = []
        for off in offsets {
            if let c = parseCookie(page, start: off) {
                out.append(c)
            }
        }
        return out
    }

    private static func parseCookie(_ page: Data, start: Int) -> DouyinCookieExport.CookieItem? {
        guard start >= 0, start + 56 <= page.count else { return nil }
        // size at start (LE)
        let size = Int(readU32LE(page, start))
        guard size >= 56, start + size <= page.count else { return nil }

        let flags = readU32LE(page, start + 8)
        let urlOff = Int(readU32LE(page, start + 16))
        let nameOff = Int(readU32LE(page, start + 20))
        let pathOff = Int(readU32LE(page, start + 24))
        let valueOff = Int(readU32LE(page, start + 28))

        let exp = readDoubleLE(page, start + 40)
        // let creation = readDoubleLE(page, start + 48)

        func cstr(_ rel: Int) -> String {
            let abs = start + rel
            guard abs >= start, abs < start + size else { return "" }
            var end = abs
            while end < start + size, page[end] != 0 { end += 1 }
            return String(data: page.subdata(in: abs..<end), encoding: .utf8)
                ?? String(data: page.subdata(in: abs..<end), encoding: .isoLatin1)
                ?? ""
        }

        let domain = cstr(urlOff)
        let name = cstr(nameOff)
        let path = cstr(pathOff)
        let value = cstr(valueOff)
        guard !name.isEmpty else { return nil }

        // flags: bit0 secure, bit2 httpOnly（常见实现）
        let secure = (flags & 1) != 0
        let httpOnly = (flags & 4) != 0
        // Apple 用 2001-01-01 起的绝对时间；转 Unix
        var expires: Date?
        if exp > 0 {
            let appleEpoch = Date(timeIntervalSinceReferenceDate: exp)
            expires = appleEpoch
        }

        return .init(
            name: name,
            value: value,
            domain: domain.isEmpty ? ".douyin.com" : domain,
            path: path.isEmpty ? "/" : path,
            expires: expires,
            secure: secure,
            httpOnly: httpOnly
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
        for i in 0..<8 {
            raw |= UInt64(d[o + i]) << (8 * i)
        }
        return Double(bitPattern: raw)
    }
}
