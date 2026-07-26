import Foundation

/// 对齐桌面 `dy_plist.py`：解析 NSKeyedArchiver 内嵌 bplist（unique_id / register_time 等）。
/// 关键点：`$objects` 里 NS.keys/NS.objects 全是 CFUID，UID 解析失败就会「有文件却提不到号」。
enum AwemeKeyedArchive {
    /// 从容器读 Preferences，返回账号字段（对齐 dy_plist.parse_plist_data）
    static func loadAccount(fromContainer container: URL) -> [String: String] {
        let pref = container.appendingPathComponent("Library/Preferences/com.ss.iphone.ugc.Aweme.plist")
        return loadAccount(fromPlistURL: pref)
    }

    static func loadAccount(fromPlistURL url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return [:] }
        return loadAccount(fromRoot: root)
    }

    static func loadAccount(fromRoot root: [String: Any]) -> [String: String] {
        var info: [String: String] = [:]

        // 1) kDYACurrentLoginUserPersistenceKey → unique_id / short_id / nickname / uid / register_time
        if let d = root["kDYACurrentLoginUserPersistenceKey"] as? Data {
            let map = flattenAll(d)
            if let v = nonEmpty(map["unique_id"]) { info["抖音号"] = v; info["unique_id"] = v }
            if let v = nonEmpty(map["short_id"]), v != "0" {
                info["ShortID"] = v
                if info["抖音号"] == nil { info["抖音号"] = v; info["unique_id"] = v }
            }
            if let v = nonEmpty(map["nickname"]) { info["昵称"] = v; info["nickname"] = v }
            if let v = nonEmpty(map["uid"]) { info["用户ID"] = v; info["uid"] = v }
            if let v = nonEmpty(map["register_time"]) {
                info["注册时间"] = formatRegister(v)
                info["register_time"] = info["注册时间"] ?? v
            }
        }

        // 2) com.toutiao.account.userdefault.user → screenName / mobile / userID
        if let d = root["com.toutiao.account.userdefault.user"] as? Data {
            let map = flattenAll(d)
            if info["昵称"] == nil {
                if let v = nonEmpty(map["screenName"]) ?? nonEmpty(map["name"]) {
                    info["昵称"] = v
                    info["nickname"] = v
                }
            }
            if let v = nonEmpty(map["userID"]) ?? nonEmpty(map["userId"]) {
                info["UserID"] = v
                if info["用户ID"] == nil { info["用户ID"] = v; info["uid"] = v }
            }
            if let v = nonEmpty(map["mobile"]) {
                info["手机号"] = v
                info["mobile"] = v
            }
            if let v = nonEmpty(map["secUserId"]) {
                info["SecUserID"] = v
                info["secUserId"] = v
            }
        }

        if let tok = root["bdaccount_session_x_tt_token"] as? String, !tok.isEmpty {
            info["x-tt-token"] = tok
        }

        // 3) UID 仍失败时：从内嵌 bplist 字符串表旁路抠 unique_id 值
        if info["抖音号"] == nil,
           let d = root["kDYACurrentLoginUserPersistenceKey"] as? Data,
           let scraped = scrapeField(d, key: "unique_id") ?? scrapeField(d, key: "short_id") {
            info["抖音号"] = scraped
            info["unique_id"] = scraped
        }

        return info
    }

    /// 摊平内嵌 keyed archive 全部 NSDictionary
    static func flattenAll(_ data: Data) -> [String: String] {
        guard let objs = keyedObjects(data) else { return [:] }
        var map: [String: String] = [:]
        for obj in objs {
            guard let dict = obj as? [String: Any] else { continue }
            let flat = flattenNSDictionary(dict, objects: objs)
            for (k, v) in flat where map[k] == nil {
                map[k] = v
            }
        }
        return map
    }

    static func keyedObjects(_ data: Data) -> [Any]? {
        guard data.count >= 8, data.prefix(8) == Data("bplist00".utf8) else { return nil }
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objs = root["$objects"] as? [Any] else { return nil }
        return objs
    }

    static func flattenNSDictionary(_ dict: [String: Any], objects: [Any]) -> [String: String] {
        var out: [String: String] = [:]
        if let keys = dict["NS.keys"] as? [Any], let vals = dict["NS.objects"] as? [Any] {
            let n = min(keys.count, vals.count)
            for i in 0..<n {
                guard let ki = uidIndex(keys[i]), ki < objects.count,
                      let key = objects[ki] as? String else { continue }
                if let s = resolveString(vals[i], objects: objects) {
                    out[key] = s
                }
            }
            return out
        }
        for (k, v) in dict {
            if k.hasPrefix("$") || k.hasPrefix("NS.") { continue }
            if let s = resolveString(v, objects: objects) {
                out[k] = s
            }
        }
        return out
    }

    static func resolveString(_ any: Any, objects: [Any]) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        if let idx = uidIndex(any), idx < objects.count {
            let o = objects[idx]
            if let s = o as? String { return s }
            if let n = o as? NSNumber { return n.stringValue }
            // 嵌套 dict 不再展开
        }
        return nil
    }

    /// 兼容 CFUID / NSNumber / description / Mirror（桌面 plistlib.UID 对等）
    static func uidIndex(_ any: Any) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? Int64 { return Int(n) }
        if let n = any as? UInt64 { return Int(n) }
        if let n = any as? UInt32 { return Int(n) }
        if let n = any as? NSNumber {
            // 纯布尔别误当 UID
            let objC = String(cString: n.objCType)
            if objC == "c" || objC == "B" { /* may still be used */ }
            return n.intValue
        }

        let obj = any as AnyObject
        for key in ["UID", "value", "intValue", "integerValue"] {
            if obj.responds(to: NSSelectorFromString(key)),
               let n = obj.value(forKey: key) as? NSNumber {
                return n.intValue
            }
        }

        for child in Mirror(reflecting: any).children {
            if let n = child.value as? UInt64 { return Int(n) }
            if let n = child.value as? UInt32 { return Int(n) }
            if let n = child.value as? Int { return n }
            if let n = child.value as? Int64 { return Int(n) }
            if let n = child.value as? NSNumber { return n.intValue }
        }

        let desc = String(describing: any)
        let patterns = [
            #"UID\((\d+)\)"#,
            #"CFUID\((\d+)\)"#,
            #"UID\{[^}]*value\s*=\s*(\d+)"#,
            #"\{value\s*=\s*(\d+)"#,
            #"value\s*=\s*(\d+)"#
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = desc as NSString
            if let m = re.firstMatch(in: desc, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1,
               let v = Int(ns.substring(with: m.range(at: 1))) {
                return v
            }
        }
        return nil
    }

    /// 当 CFUID 完全解不开时：在 $objects 字符串表里找 key，再在同层 NSDictionary 取对应值
    static func scrapeField(_ data: Data, key: String) -> String? {
        guard let objs = keyedObjects(data) else { return nil }
        var keyIdx: Int?
        for (i, o) in objs.enumerated() {
            if let s = o as? String, s == key {
                keyIdx = i
                break
            }
        }
        guard let keyIdx else { return nil }

        for obj in objs {
            guard let dict = obj as? [String: Any],
                  let keys = dict["NS.keys"] as? [Any],
                  let vals = dict["NS.objects"] as? [Any] else { continue }
            let n = min(keys.count, vals.count)
            for i in 0..<n {
                // 即使 uidIndex 半残，也尝试；同时比较 resolved 字符串
                let resolvedKey: String?
                if let ki = uidIndex(keys[i]), ki < objs.count {
                    resolvedKey = objs[ki] as? String
                } else {
                    resolvedKey = keys[i] as? String
                }
                // 关键路径：NS.keys[i] 的 UID 数值 == keyIdx
                let matchesIndex: Bool = {
                    if let ki = uidIndex(keys[i]) { return ki == keyIdx }
                    return false
                }()
                guard resolvedKey == key || matchesIndex else { continue }
                if let s = resolveString(vals[i], objects: objs), !s.isEmpty, s != "0" {
                    return s
                }
                // 值 UID 数值直接取 objects
                if let vi = uidIndex(vals[i]), vi < objs.count {
                    if let s = objs[vi] as? String, !s.isEmpty, s != "0" { return s }
                    if let n = objs[vi] as? NSNumber { return n.stringValue }
                }
            }
        }
        return nil
    }

    private static func formatRegister(_ raw: String) -> String {
        if let n = Double(raw) {
            let sec = n > 10_000_000_000 ? n / 1000.0 : n
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.string(from: Date(timeIntervalSince1970: sec))
        }
        return raw
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
