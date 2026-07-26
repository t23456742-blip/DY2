import Foundation

/// 对齐桌面 `aweme_param_extractor._parse_tt_net_config`，并补上 Zorro 真格式：
/// `key&#*value@$*key&#*value` + `session_url` 查询串里的 device_type / iid / cdid 等。
enum AwemeTTNetConfig {
    static func load(fromContainer container: URL) -> [String: String] {
        let fm = FileManager.default
        let directs = [
            container.appendingPathComponent("Documents/tt_net_config.config"),
            container.appendingPathComponent("Library/Preferences/tt_net_config.config"),
            container.appendingPathComponent("tmp/tt_net_config.config"),
            container.appendingPathComponent("Documents/mmkv/tt_net_config.config")
        ]
        for u in directs where fm.fileExists(atPath: u.path) {
            if let data = try? Data(contentsOf: u) {
                let cfg = parse(data)
                if !cfg.isEmpty { return cfg }
            }
        }
        // 浅搜
        for rootName in ["Documents", "Library", "tmp"] {
            let root = container.appendingPathComponent(rootName)
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            var budget = 4000
            while let u = en.nextObject() as? URL {
                budget -= 1
                if budget <= 0 { break }
                if u.lastPathComponent.lowercased() == "tt_net_config.config",
                   let data = try? Data(contentsOf: u) {
                    let cfg = parse(data)
                    if !cfg.isEmpty { return cfg }
                }
            }
        }
        return [:]
    }

    static func parse(_ data: Data) -> [String: String] {
        var cfg: [String: String] = [:]

        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            flatten(obj, prefix: "", into: &cfg)
            enrichFromURLValues(&cfg)
            return cfg
        }
        if let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            flatten(obj, prefix: "", into: &cfg)
            enrichFromURLValues(&cfg)
            return cfg
        }

        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        // Zorro / 雷神常见：key&#*value@$*key&#*value
        if text.contains("&#*") {
            for part in text.components(separatedBy: "@$*") {
                guard let sep = part.range(of: "&#*") else { continue }
                let k = String(part[..<sep.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let v = String(part[sep.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !k.isEmpty { cfg[k] = v }
            }
        }

        // 兼容 key=value 分行
        if cfg.isEmpty {
            for line in text.split(whereSeparator: \.isNewline) {
                let s = line.trimmingCharacters(in: .whitespaces)
                guard let eq = s.firstIndex(of: "="), !s.hasPrefix("#") else { continue }
                let k = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
                var v = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !k.isEmpty { cfg[k] = v }
            }
        }

        enrichFromURLValues(&cfg)
        normalizeAliases(&cfg)
        return cfg
    }

    /// 从任意含 URL 的值（尤其 session_url）抽出 query 参数
    private static func enrichFromURLValues(_ cfg: inout [String: String]) {
        var extras: [String: String] = [:]
        for (_, v) in cfg {
            guard v.contains("://") || v.contains("device_type=") || v.contains("install_id=") else { continue }
            for (qk, qv) in queryItems(from: v) {
                if extras[qk] == nil { extras[qk] = qv }
                // 也留一份带前缀，兼容桌面 endswith(_device_type) 逻辑
                let fk = "session_\(qk)"
                if extras[fk] == nil { extras[fk] = qv }
            }
        }
        for (k, v) in extras where cfg[k] == nil {
            cfg[k] = v
        }
        // 后缀回填
        for (k, v) in cfg {
            if k.hasSuffix("device_type"), cfg["device_type"] == nil { cfg["device_type"] = v }
            if k.hasSuffix("os_version"), cfg["os_version"] == nil { cfg["os_version"] = v }
            if k.hasSuffix("version_code"), cfg["version_code"] == nil { cfg["version_code"] = v }
            if k.hasSuffix("install_id"), cfg["install_id"] == nil { cfg["install_id"] = v }
            if k.hasSuffix("device_id"), cfg["device_id"] == nil { cfg["device_id"] = v }
            if k.hasSuffix("cdid"), cfg["cdid"] == nil { cfg["cdid"] = v }
            if k.hasSuffix("build_number"), cfg["build_number"] == nil { cfg["build_number"] = v }
        }
    }

    private static func normalizeAliases(_ cfg: inout [String: String]) {
        if cfg["did"] == nil { cfg["did"] = cfg["device_id"] }
        if cfg["iid"] == nil { cfg["iid"] = cfg["install_id"] ?? cfg["iid"] }
        if cfg["app_version"] == nil { cfg["app_version"] = cfg["version_code"] }
        // session_id cookie 串 → sessionid
        if cfg["sessionid"] == nil, let sid = cfg["session_id"] ?? cfg["sessionid"] {
            if let r = sid.range(of: #"sessionid=([^;\s]+)"#, options: .regularExpression) {
                let cap = String(sid[r]).replacingOccurrences(of: "sessionid=", with: "")
                cfg["sessionid"] = cap
            } else if !sid.contains("=") {
                cfg["sessionid"] = sid
            }
        }
        if cfg["x-tt-token"] == nil, let t = cfg["ticket"], !t.isEmpty {
            cfg["x-tt-token"] = t
        }
    }

    private static func queryItems(from text: String) -> [String: String] {
        var out: [String: String] = [:]
        // 抽所有 ?a=b&c=d 片段
        let pattern = #"[?&]([A-Za-z0-9_]+)=([^&\s\"']+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 3 {
            let k = ns.substring(with: m.range(at: 1))
            var v = ns.substring(with: m.range(at: 2))
            v = v.removingPercentEncoding ?? v
            if out[k] == nil { out[k] = v }
        }
        return out
    }

    private static func flatten(_ obj: [String: Any], prefix: String, into cfg: inout [String: String]) {
        for (k, v) in obj {
            let fk = prefix.isEmpty ? k : "\(prefix)_\(k)"
            if let d = v as? [String: Any] {
                flatten(d, prefix: fk, into: &cfg)
            } else if let s = v as? String {
                cfg[fk] = s
                cfg[k] = s
            } else if let n = v as? NSNumber {
                cfg[fk] = n.stringValue
                cfg[k] = n.stringValue
            }
        }
    }
}
