import Foundation

/// 对照桌面 `aweme_param_extractor`：从本机抖音沙盒提取 16 参，按抖音号写 TXT 到 Media。
enum DouyinParamExtractor {
    static let mediaDirs = [
        "/private/var/mobile/Media",
        "/var/mobile/Media"
    ]

    /// 输出字段顺序（与说明文档一致）
    static let outputKeys = [
        "did", "iid", "sessionid", "uid_tt", "PassportCSRF", "odin_tt", "cdid",
        "x-tt-dt", "x-tt-token", "session-tlb-tag", "token-tlb-tag",
        "mfa-token", "sid_guard", "x-tt-token-supplement", "multi_sids", "d_ticket"
    ]

    struct Outcome: Sendable {
        var ok: Bool
        var message: String
        var path: String
        var douyinID: String
        var filledCount: Int
    }

    static func extractAndSave(cleaner: SlimCleaner) -> Outcome {
        extractAndSave(cleaner: cleaner, container: nil)
    }

    /// 优先用已定位的抖音容器路径提参（本机沙盒，不是电脑备份包）
    static func extractAndSave(cleaner: SlimCleaner, container preferred: URL?) -> Outcome {
        let container = preferred.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? cleaner.locateAwemeContainer()
        guard let container else {
            return Outcome(ok: false, message: "未找到抖音容器", path: "", douyinID: "", filledCount: 0)
        }

        var params = extractParams(from: container)
        let douyinID = resolveDouyinID(container: container, params: &params)
        guard !douyinID.isEmpty else {
            return Outcome(ok: false, message: "未读到抖音号，请先登录抖音", path: "", douyinID: "", filledCount: 0)
        }

        let text = formatTXT(douyinID: douyinID, params: params)
        guard let outDir = firstWritableMediaDir() else {
            return Outcome(ok: false, message: "无法写入 /private/var/mobile/Media", path: "", douyinID: douyinID, filledCount: countFilled(params))
        }

        let fileURL = outDir.appendingPathComponent("\(safeFileName(douyinID)).txt")
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            let n = countFilled(params)
            return Outcome(
                ok: true,
                message: "提参成功\n来源容器：\(container.path)\n抖音号：\(douyinID)\n已写入 \(n)/\(outputKeys.count) 项\n\(fileURL.path)",
                path: fileURL.path,
                douyinID: douyinID,
                filledCount: n
            )
        } catch {
            return Outcome(ok: false, message: "写入失败：\(error.localizedDescription)", path: "", douyinID: douyinID, filledCount: countFilled(params))
        }
    }

    // MARK: - Extract

    private static func extractParams(from container: URL) -> [String: String] {
        var params: [String: String] = [:]

        // 1) tt_net_config.config → did / iid / cdid / sessionid
        if let data = firstFileData(named: "tt_net_config.config", under: container) {
            let cfg = parseTTNetConfig(data)
            setIfEmpty(&params, "did", cfg["device_id"] ?? cfg["did"])
            setIfEmpty(&params, "iid", cfg["install_id"] ?? cfg["iid"])
            setIfEmpty(&params, "cdid", cfg["cdid"])
            setIfEmpty(&params, "sessionid", cfg["sessionid"] ?? cfg["session_id"])
            setIfEmpty(&params, "x-tt-token", cfg["ticket"] ?? cfg["x-tt-token"])
            for (k, v) in cfg {
                if k.hasSuffix("device_id") { setIfEmpty(&params, "did", v) }
                if k.hasSuffix("install_id") { setIfEmpty(&params, "iid", v) }
                if k.hasSuffix("cdid") { setIfEmpty(&params, "cdid", v) }
                if k.hasSuffix("sessionid") || k.hasSuffix("session_id") { setIfEmpty(&params, "sessionid", v) }
            }
        }

        // 2) Cookies.binarycookies
        let cookieDirs = [
            container.appendingPathComponent("Library/Cookies"),
            container.appendingPathComponent("Library/WebKit/WebsiteData/Cookies")
        ]
        for dir in cookieDirs {
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for u in items where u.lastPathComponent.lowercased().contains("cookie") {
                for c in BinaryCookiesParser.parse(fileURL: u) {
                    applyCookie(name: c.name, value: c.value, into: &params)
                }
                // 二进制兜底正则
                if let raw = try? Data(contentsOf: u) {
                    applyCookieRegexFallback(raw, into: &params)
                }
            }
        }

        // 3) ttinstall_ids.plist → x-tt-dt
        let installCandidates = [
            container.appendingPathComponent("Documents/_ttinstall_document/ttinstall_ids.plist"),
            container.appendingPathComponent("Library/Preferences/ttinstall_ids.plist")
        ]
        for url in installCandidates {
            if let dt = parseTTInstallDT(url) {
                setIfEmpty(&params, "x-tt-dt", dt)
                break
            }
        }
        if params["x-tt-dt"] == nil,
           let data = firstFileData(named: "ttinstall_ids.plist", under: container) {
            setIfEmpty(&params, "x-tt-dt", parseTTInstallDT(data: data))
        }

        // 4) ttaccount_token_guard_data.archiver → x-tt-token
        if let data = firstFileData(named: "ttaccount_token_guard_data.archiver", under: container) {
            setIfEmpty(&params, "x-tt-token", parseTokenGuard(data))
        }

        // 5) com.ttaccount.custom_mmkv → tlb tags
        if let data = firstFileData(named: "com.ttaccount.custom_mmkv", under: container) {
            merge(parseTLBTags(data), into: &params)
        }

        // 6) Aweme.plist
        let pref = container.appendingPathComponent("Library/Preferences/com.ss.iphone.ugc.Aweme.plist")
        if let data = try? Data(contentsOf: pref),
           let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            merge(extractAwemePlist(root), into: &params)
        }

        return params
    }

    private static func resolveDouyinID(container: URL, params: inout [String: String]) -> String {
        let pref = container.appendingPathComponent("Library/Preferences/com.ss.iphone.ugc.Aweme.plist")
        if let data = try? Data(contentsOf: pref),
           let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            if let d = root["kDYACurrentLoginUserPersistenceKey"] as? Data,
               let map = keyedFlatMap(d) {
                if let u = map["unique_id"], !u.isEmpty, u != "0" { return u }
                if let s = map["short_id"], !s.isEmpty, s != "0" { return s }
                if let uid = map["uid"], !uid.isEmpty { return uid }
            }
            if let d = root["com.toutiao.account.userdefault.user"] as? Data,
               let map = keyedFlatMap(d) {
                if let id = map["userID"] ?? map["userId"], !id.isEmpty { return id }
            }
        }
        // multi_sids 前缀常为 uid
        if let ms = params["multi_sids"], let colon = ms.firstIndex(of: ":") {
            let uid = String(ms[..<colon])
            if !uid.isEmpty { return uid }
        }
        return ""
    }

    // MARK: - Sources

    private static func applyCookie(name: String, value: String, into params: inout [String: String]) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        switch name.lowercased() {
        case "uid_tt", "uid_tt_token":
            setIfEmpty(&params, "uid_tt", v)
        case "odin_tt":
            setIfEmpty(&params, "odin_tt", v)
        case "passport_csrf_token", "passportcsrf":
            setIfEmpty(&params, "PassportCSRF", v)
        case "sid_guard":
            setIfEmpty(&params, "sid_guard", v)
        case "sessionid", "session_id":
            setIfEmpty(&params, "sessionid", v)
        case "d_ticket", "dticket":
            setIfEmpty(&params, "d_ticket", v)
        case "multi_sids":
            setIfEmpty(&params, "multi_sids", v)
        default:
            break
        }
    }

    private static func applyCookieRegexFallback(_ data: Data, into params: inout [String: String]) {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let pairs: [(String, String)] = [
            ("uid_tt", #"uid_tt[^=\x00]{0,8}([a-f0-9]{32,})"#),
            ("odin_tt", #"odin_tt[^=\x00]{0,8}([A-Za-z0-9+/=_\-]{20,})"#),
            ("PassportCSRF", #"passport_csrf_token[^=\x00]{0,8}([a-f0-9]{32,})"#),
            ("sid_guard", #"sid_guard[^=\x00]{0,8}([^\x00\|]+\|[^\x00]+)"#),
            ("sessionid", #"sessionid[^=\x00]{0,8}([a-f0-9]{32})"#)
        ]
        for (key, pattern) in pairs {
            guard params[key] == nil || params[key]?.isEmpty == true else { continue }
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            if let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges > 1 {
                let cap = ns.substring(with: match.range(at: 1))
                if !cap.isEmpty { params[key] = cap }
            }
        }
    }

    private static func parseTTInstallDT(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseTTInstallDT(data: data)
    }

    private static func parseTTInstallDT(data: Data) -> String? {
        if let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            for k in ["x-tt-dt", "X-Tt-Dt", "dt_token", "install_device_token"] {
                if let v = root[k] as? String, !v.isEmpty { return v }
            }
            for v in root.values {
                if let s = v as? String, s.count > 20 { return s }
            }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if let r = text.range(of: #"[A-Za-z0-9+/=]{40,}"#, options: .regularExpression) {
            return String(text[r])
        }
        return nil
    }

    private static func parseTokenGuard(_ data: Data) -> String? {
        if data.prefix(6) == Data("bplist".utf8),
           let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
           let objs = root["$objects"] as? [Any] {
            for obj in objs {
                if let s = obj as? String, s.count > 20, !s.hasPrefix("$") { return s }
                if let d = obj as? [String: Any] {
                    for v in d.values {
                        if let s = v as? String, s.count > 20 { return s }
                    }
                }
            }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if let r = text.range(of: #"[a-f0-9]{32,}"#, options: .regularExpression) {
            return String(text[r])
        }
        return nil
    }

    private static func parseTLBTags(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        if let re = try? NSRegularExpression(pattern: #"session.?tlb.?tag["':\s]+([^"'\s,\}]+)"#, options: .caseInsensitive),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           m.numberOfRanges > 1 {
            let s = (text as NSString).substring(with: m.range(at: 1))
            if s.contains("|") { out["session-tlb-tag"] = s }
        }
        if let re = try? NSRegularExpression(pattern: #"token.?tlb.?tag["':\s]+([^"'\s,\}]+)"#, options: .caseInsensitive),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           m.numberOfRanges > 1 {
            let s = (text as NSString).substring(with: m.range(at: 1))
            if s.contains("|") { out["token-tlb-tag"] = s }
        }
        if out["session-tlb-tag"] == nil,
           let re = try? NSRegularExpression(pattern: #"sttt\|3\|(\S+)"#),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           m.numberOfRanges > 1 {
            let cap = (text as NSString).substring(with: m.range(at: 1))
            out["session-tlb-tag"] = "sttt|3|\(cap)"
        }
        if out["token-tlb-tag"] == nil,
           let re = try? NSRegularExpression(pattern: #"sttt\|7\|(\S+)"#),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           m.numberOfRanges > 1 {
            let cap = (text as NSString).substring(with: m.range(at: 1))
            out["token-tlb-tag"] = "sttt|7|\(cap)"
        }
        return out
    }

    private static func extractAwemePlist(_ root: [String: Any]) -> [String: String] {
        var params: [String: String] = [:]

        if let tok = root["bdaccount_session_x_tt_token"] as? String, !tok.isEmpty {
            params["x-tt-token"] = tok.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let raw = root["accountsdk_extra_headers"] as? Data {
            merge(parseTLBTags(raw), into: &params)
        } else if let s = root["accountsdk_extra_headers"] as? String, let d = s.data(using: .utf8) {
            merge(parseTLBTags(d), into: &params)
        }

        for (key, aliases) in [
            ("mfa-token", ["mfa_token", "MFA_Token", "mfa-token"]),
            ("d_ticket", ["d_ticket", "D_Ticket", "dticket"]),
            ("multi_sids", ["multi_sids", "MultiSids"]),
            ("x-tt-token-supplement", ["x-tt-token-supplement", "X_Tt_Token_Supplement"]),
            ("sessionid", ["sessionid", "session_id", "AWE_SessionID", "sessionID"]),
            ("sid_guard", ["sid_guard", "SidGuard"]),
            ("uid_tt", ["uid_tt", "uid_tt_token"]),
            ("PassportCSRF", ["passport_csrf_token", "PassportCSRF"])
        ] as [(String, [String])] {
            for a in aliases {
                if let v = root[a] as? String, !v.isEmpty {
                    setIfEmpty(&params, key, v)
                    break
                }
            }
        }
        return params
    }

    // MARK: - Helpers

    private static func formatTXT(douyinID: String, params: [String: String]) -> String {
        var lines: [String] = ["抖音号\(douyinID)"]
        for k in outputKeys {
            lines.append("\(k)=\(params[k] ?? "")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func countFilled(_ params: [String: String]) -> Int {
        outputKeys.filter { !(params[$0] ?? "").isEmpty }.count
    }

    private static func firstWritableMediaDir() -> URL? {
        let fm = FileManager.default
        for p in mediaDirs {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            if !fm.fileExists(atPath: u.path) {
                try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            }
            let probe = u.appendingPathComponent(".dy_write_probe")
            do {
                try "ok".write(to: probe, atomically: true, encoding: .utf8)
                try? fm.removeItem(at: probe)
                return u
            } catch { continue }
        }
        return nil
    }

    private static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return s.components(separatedBy: bad).joined(separator: "_")
    }

    private static func setIfEmpty(_ dict: inout [String: String], _ key: String, _ value: String?) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        if dict[key] == nil || dict[key]?.isEmpty == true {
            dict[key] = value
        }
    }

    private static func merge(_ src: [String: String], into dest: inout [String: String]) {
        for (k, v) in src { setIfEmpty(&dest, k, v) }
    }

    private static func parseTTNetConfig(_ data: Data) -> [String: String] {
        var cfg: [String: String] = [:]
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            flattenJSON(obj, prefix: "", into: &cfg)
            return cfg
        }
        if let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            flattenJSON(obj, prefix: "", into: &cfg)
            return cfg
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard let eq = s.firstIndex(of: "=") else { continue }
            let k = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !k.isEmpty { cfg[k] = v }
        }
        return cfg
    }

    private static func flattenJSON(_ obj: [String: Any], prefix: String, into cfg: inout [String: String]) {
        for (k, v) in obj {
            let fk = prefix.isEmpty ? k : "\(prefix)_\(k)"
            if let d = v as? [String: Any] {
                flattenJSON(d, prefix: fk, into: &cfg)
            } else if let s = v as? String {
                cfg[fk] = s
                cfg[k] = s
            } else if let n = v as? NSNumber {
                cfg[fk] = n.stringValue
                cfg[k] = n.stringValue
            }
        }
    }

    private static func keyedFlatMap(_ data: Data) -> [String: String]? {
        guard data.count >= 8, data.prefix(8) == Data("bplist00".utf8) else { return nil }
        guard let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let objs = root["$objects"] as? [Any] else { return nil }
        var map: [String: String] = [:]
        for obj in objs {
            guard let dict = obj as? [String: Any] else { continue }
            if let keys = dict["NS.keys"] as? [Any], let vals = dict["NS.objects"] as? [Any] {
                let n = min(keys.count, vals.count)
                for i in 0..<n {
                    guard let ki = uidIndex(keys[i]), ki < objs.count,
                          let key = objs[ki] as? String else { continue }
                    if let s = resolveString(vals[i], objects: objs) {
                        map[key] = s
                    }
                }
            } else {
                for (k, v) in dict {
                    if k.hasPrefix("$") || k.hasPrefix("NS.") { continue }
                    if let s = resolveString(v, objects: objs) { map[k] = s }
                }
            }
        }
        return map.isEmpty ? nil : map
    }

    private static func resolveString(_ any: Any, objects: [Any]) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        if let idx = uidIndex(any), idx < objects.count {
            if let s = objects[idx] as? String { return s }
            if let n = objects[idx] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    private static func uidIndex(_ any: Any) -> Int? {
        let obj = any as AnyObject
        if obj.responds(to: Selector(("UID"))) {
            if let n = obj.value(forKey: "UID") as? NSNumber { return n.intValue }
            if let u = obj.value(forKey: "UID") as? UInt32 { return Int(u) }
            if let u = obj.value(forKey: "UID") as? Int { return u }
        }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    /// 在容器内按文件名浅搜（Documents / Library / mmkv）
    private static func firstFileData(named name: String, under container: URL) -> Data? {
        let fm = FileManager.default
        let roots = [
            container.appendingPathComponent("Documents"),
            container.appendingPathComponent("Library"),
            container.appendingPathComponent("tmp")
        ]
        let target = name.lowercased()
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { continue }
            var depthBudget = 8000
            while let u = en.nextObject() as? URL {
                depthBudget -= 1
                if depthBudget <= 0 { break }
                if u.lastPathComponent.lowercased() == target {
                    return try? Data(contentsOf: u)
                }
            }
        }
        // 直接常见路径
        let directs = [
            container.appendingPathComponent("Documents/\(name)"),
            container.appendingPathComponent("Documents/mmkv/\(name)"),
            container.appendingPathComponent("Library/Preferences/\(name)")
        ]
        for u in directs where fm.fileExists(atPath: u.path) {
            return try? Data(contentsOf: u)
        }
        return nil
    }
}
