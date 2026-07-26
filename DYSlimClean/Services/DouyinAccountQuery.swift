import Foundation

/// 对照桌面「抖音查询 v3」：本机读沙盒 + 直连查询（不用代理）。
/// 展示字段仅：机型、注册时间、国家、抖音号、名称、状态、是否在线、版本、抖音版本。
enum DouyinAccountQuery {
    struct Snapshot: Sendable {
        var deviceModel: String = "—"      // 机型
        var registerTime: String = "—"     // 注册时间（精确到分）
        var country: String = "—"          // 国家
        var douyinID: String = "—"         // 抖音号
        var nickname: String = "—"         // 名称
        var status: String = "—"           // 状态
        var online: String = "—"           // 是否在线
        var osVersion: String = "—"        // 版本（系统）
        var appVersion: String = "—"       // 抖音版本
        var ok: Bool = false
        var detail: String = ""

        var rows: [(String, String)] {
            [
                ("机型", deviceModel),
                ("注册时间", registerTime),
                ("国家", country),
                ("抖音号", douyinID),
                ("名称", nickname),
                ("状态", status),
                ("是否在线", online),
                ("版本", osVersion),
                ("抖音版本", appVersion)
            ]
        }

        var message: String {
            rows.map { "\($0.0)：\($0.1)" }.joined(separator: "\n")
        }
    }

    private struct Raw {
        var uniqueID: String?
        var shortID: String?
        var nickname: String?
        var mobile: String?
        var secUID: String?
        var userID: String?
        var registerTimeRaw: String?
        var deviceType: String?
        var osVersion: String?
        var appVersion: String?
        var buildNumber: String?
        var deviceID: String?
        var installID: String?
        var cdid: String?
        var token: String?
        var mccMnc: String?
        var screenWidth: String?
        var osAPI: String?
        var ac: String?
    }

    static func query(cleaner: SlimCleaner) -> Snapshot {
        query(cleaner: cleaner, container: nil)
    }

    /// 优先使用已定位容器路径（本机沙盒，不是电脑备份包）
    static func query(cleaner: SlimCleaner, container preferred: URL?) -> Snapshot {
        var snap = Snapshot()
        let container = preferred.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? cleaner.locateAwemeContainer()
        guard let container else {
            snap.detail = "未找到抖音容器"
            return snap
        }
        snap.detail = "本机容器：\(container.path)"

        var raw = Raw()
        loadFromPreferences(container, into: &raw)
        loadFromTTNetConfig(container, into: &raw)
        loadFromTTInstall(container, into: &raw)

        let uid = (raw.uniqueID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (raw.shortID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }

        snap.douyinID = uid ?? "—"
        snap.nickname = nonEmpty(raw.nickname) ?? "—"
        snap.deviceModel = friendlyDeviceName(nonEmpty(raw.deviceType) ?? "—")
        snap.osVersion = nonEmpty(raw.osVersion) ?? "—"
        snap.appVersion = nonEmpty(raw.appVersion) ?? "—"
        snap.registerTime = formatRegisterToMinute(raw.registerTimeRaw)
        snap.country = detectCountry(mobile: raw.mobile, fallbackUID: uid)

        // 1) 直连 iesdouyin 查状态/昵称（无代理）
        if let uid, !uid.isEmpty {
            let api = queryUserInfoNoProxy(uniqueID: uid)
            if !api.status.isEmpty { snap.status = api.status }
            if snap.nickname == "—" || snap.nickname.isEmpty, let n = api.nickname, !n.isEmpty {
                snap.nickname = n
            }
            // API create_time 补注册时间（精确到分）
            if snap.registerTime == "—", let ct = api.createTimeMinute {
                snap.registerTime = ct
            }
        } else {
            snap.status = "无抖音号"
        }

        // 2) 直连钱包接口查是否在线（无代理）
        snap.online = checkOnlineNoProxy(raw: raw)

        snap.ok = snap.douyinID != "—" || snap.nickname != "—"
        snap.detail = "本机容器提参 + 直连查询（无代理）\n\(container.path)"
        return snap
    }

    // MARK: - Preferences / config

    private static func loadFromPreferences(_ container: URL, into raw: inout Raw) {
        let pref = container.appendingPathComponent("Library/Preferences/com.ss.iphone.ugc.Aweme.plist")
        guard let data = try? Data(contentsOf: pref),
              let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return }

        if let tok = root["bdaccount_session_x_tt_token"] as? String, !tok.isEmpty {
            raw.token = tok
        }
        if let d = root["com.toutiao.account.userdefault.user"] as? Data {
            parseUserArchive(d, into: &raw)
        }
        if let d = root["kDYACurrentLoginUserPersistenceKey"] as? Data {
            parseProfileArchive(d, into: &raw)
        }

        // base64 设备 JSON（常见于设备指纹缓存）
        for (_, v) in root {
            guard let s = v as? String, s.count > 80 else { continue }
            guard let dec = Data(base64Encoded: s) ?? Data(base64Encoded: s + "=="),
                  let obj = try? JSONSerialization.jsonObject(with: dec) as? [String: Any],
                  obj["device_id"] != nil else { continue }
            if raw.deviceType == nil { raw.deviceType = obj["device_type"] as? String }
            if raw.osVersion == nil { raw.osVersion = obj["os_version"] as? String }
            if raw.appVersion == nil {
                raw.appVersion = (obj["app_version"] as? String) ?? (obj["version_code"] as? String)
            }
            if raw.deviceID == nil, let d = obj["device_id"] { raw.deviceID = "\(d)" }
            if raw.installID == nil, let d = obj["install_id"] { raw.installID = "\(d)" }
            if raw.cdid == nil, let d = obj["cdid"] { raw.cdid = "\(d)" }
            break
        }

        if raw.appVersion == nil {
            if let cj = root["CJPayUserAgent"] as? String,
               let r = cj.range(of: #"AID1128/([\d.]+)"#, options: .regularExpression) {
                raw.appVersion = String(cj[r]).replacingOccurrences(of: "AID1128/", with: "")
            } else if let v = root["kTTInstallServiceAppVersion"] as? String {
                raw.appVersion = v
            }
        }
        if raw.osVersion == nil {
            let ua = (root["AWEWebViewDefaultUA"] as? String) ?? (root["kBDPOriginUserAgentKey"] as? String) ?? ""
            if let m = ua.range(of: #"OS ([\d_]+)"#, options: .regularExpression) {
                raw.osVersion = String(ua[m]).replacingOccurrences(of: "OS ", with: "").replacingOccurrences(of: "_", with: ".")
            }
        }
    }

    private static func loadFromTTNetConfig(_ container: URL, into raw: inout Raw) {
        let candidates = [
            container.appendingPathComponent("Documents/tt_net_config.config"),
            container.appendingPathComponent("Library/Preferences/tt_net_config.config"),
            container.appendingPathComponent("tmp/tt_net_config.config")
        ]
        let fm = FileManager.default
        for url in candidates where fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let cfg = parseTTNetConfig(data)
            if raw.deviceID == nil { raw.deviceID = cfg["device_id"] ?? cfg["did"] }
            if raw.installID == nil { raw.installID = cfg["install_id"] ?? cfg["iid"] }
            if raw.cdid == nil { raw.cdid = cfg["cdid"] }
            if raw.deviceType == nil { raw.deviceType = cfg["device_type"] }
            if raw.osVersion == nil { raw.osVersion = cfg["os_version"] }
            if raw.appVersion == nil {
                raw.appVersion = cfg["version_code"] ?? cfg["app_version"]
            }
            if raw.buildNumber == nil { raw.buildNumber = cfg["build_number"] }
            if raw.mccMnc == nil { raw.mccMnc = cfg["mcc_mnc"] }
            if raw.screenWidth == nil { raw.screenWidth = cfg["screen_width"] }
            if raw.osAPI == nil { raw.osAPI = cfg["os_api"] }
            if raw.ac == nil { raw.ac = cfg["ac"] }
            if raw.token == nil || raw.token?.isEmpty == true {
                let t = cfg["ticket"] ?? cfg["x-tt-token"]
                if let t, !t.isEmpty { raw.token = t }
            }
            // nested keys
            for (k, v) in cfg {
                if k.hasSuffix("device_type"), raw.deviceType == nil { raw.deviceType = v }
                if k.hasSuffix("os_version"), raw.osVersion == nil { raw.osVersion = v }
                if k.hasSuffix("version_code"), raw.appVersion == nil { raw.appVersion = v }
            }
            break
        }
    }

    private static func loadFromTTInstall(_ container: URL, into raw: inout Raw) {
        let ttid = container.appendingPathComponent("Documents/_ttinstall_document/ttinstall_ids.plist")
        guard let data = try? Data(contentsOf: ttid),
              let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return }
        if raw.deviceID == nil {
            let did = (root["kDeviceIDStorageKey"] as? String) ?? (root["kClientDIDStorageKey"] as? String)
            if let did, !did.isEmpty { raw.deviceID = did }
        }
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

    private static func parseUserArchive(_ data: Data, into raw: inout Raw) {
        guard let objs = keyedObjects(data) else { return }
        for obj in objs {
            guard let dict = obj as? [String: Any] else { continue }
            let map = flattenNSDictionary(dict, objects: objs)
            if raw.nickname == nil { raw.nickname = map["screenName"] ?? map["name"] }
            if raw.userID == nil { raw.userID = map["userID"] }
            if raw.mobile == nil { raw.mobile = map["mobile"] }
            if raw.secUID == nil { raw.secUID = map["secUserId"] }
        }
    }

    private static func parseProfileArchive(_ data: Data, into raw: inout Raw) {
        guard let objs = keyedObjects(data) else { return }
        for obj in objs {
            guard let dict = obj as? [String: Any] else { continue }
            let map = flattenNSDictionary(dict, objects: objs)
            guard map["unique_id"] != nil || map["nickname"] != nil || map["uid"] != nil || map["register_time"] != nil else { continue }
            if raw.uniqueID == nil { raw.uniqueID = map["unique_id"] }
            if raw.shortID == nil { raw.shortID = map["short_id"] }
            if raw.nickname == nil { raw.nickname = map["nickname"] }
            if raw.userID == nil { raw.userID = map["uid"] }
            if raw.registerTimeRaw == nil { raw.registerTimeRaw = map["register_time"] }
            break
        }
    }

    // MARK: - API（无代理）

    private struct APIUser {
        var status: String = ""
        var nickname: String?
        var createTimeMinute: String?
    }

    private static func queryUserInfoNoProxy(uniqueID: String) -> APIUser {
        var out = APIUser()
        let enc = uniqueID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uniqueID
        guard let url = URL(string: "https://www.iesdouyin.com/web/api/v2/user/info/?unique_id=\(enc)") else {
            out.status = "查询失败"
            return out
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://www.iesdouyin.com/", forHTTPHeaderField: "Referer")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:] // 明确禁用系统代理
        cfg.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: cfg)
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, _, err in
            defer { sem.signal() }
            if err != nil {
                out.status = "查询失败"
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                out.status = "查询失败"
                return
            }
            let user = (json["user_info"] as? [String: Any])
                ?? ((json["data"] as? [String: Any])?["user_info"] as? [String: Any])
                ?? [:]
            out = parseUserStatus(user)
        }.resume()
        _ = sem.wait(timeout: .now() + 16)
        return out
    }

    private static func parseUserStatus(_ user: [String: Any]) -> APIUser {
        var out = APIUser()
        let uid = (user["unique_id"] as? String) ?? ""
        if uid.isEmpty && user.isEmpty {
            out.status = "参数非法"
            return out
        }
        out.nickname = user["nickname"] as? String

        if let ct = user["create_time"] as? NSNumber {
            out.createTimeMinute = formatUnixToMinute(ct.doubleValue)
        } else if let ct = user["create_time"] as? Double {
            out.createTimeMinute = formatUnixToMinute(ct)
        } else if let ct = user["create_time"] as? Int {
            out.createTimeMinute = formatUnixToMinute(Double(ct))
        }

        let nick = out.nickname ?? ""
        let sig = (user["signature"] as? String) ?? ""
        let text = nick + " " + sig

        if let punish = user["punish_remind_info"] as? [String: Any], (punish["is_punish"] as? Bool) == true {
            let title = (punish["punish_title"] as? String) ?? ""
            let content = ((punish["punish_content"] as? [String: Any])?["content"] as? String) ?? ""
            let full = title + " " + content
            if full.contains("封禁") || full.contains("封号") {
                out.status = "封禁"
                return out
            }
            if full.contains("禁言") {
                out.status = "禁言"
                return out
            }
            if full.contains("违规") || full.contains("违反") {
                out.status = "违规"
                return out
            }
        }

        let banned = ["账号已重置", "账号已封禁", "封号", "已被封禁", "被禁止", "受限制"]
        if banned.contains(where: { text.contains($0) }) {
            out.status = "封禁"
            return out
        }
        if text.contains("禁言") || text.contains("被禁言") {
            out.status = "禁言"
            return out
        }
        if (user["secret"] as? Int) == 1 || text.contains("私密") {
            out.status = "私密"
            return out
        }
        out.status = "正常"
        return out
    }

    private static func checkOnlineNoProxy(raw: Raw) -> String {
        guard let token = raw.token, !token.isEmpty else { return "无法检测" }
        let did = raw.deviceID ?? ""
        let iid = raw.installID ?? ""
        let cdid = raw.cdid ?? ""
        let deviceType = raw.deviceType ?? "iPhone10,6"
        let osVersion = raw.osVersion ?? "16.0"
        let appVersion = raw.appVersion ?? "23.9.0"
        let build = raw.buildNumber ?? "239013"

        var comps = URLComponents(string: "https://webcast5-normal-c-lf.amemv.com/webcast/wallet_api/mobile/plan/")
        comps?.queryItems = [
            URLQueryItem(name: "version_code", value: appVersion),
            URLQueryItem(name: "app_version", value: appVersion),
            URLQueryItem(name: "device_id", value: did),
            URLQueryItem(name: "iid", value: iid),
            URLQueryItem(name: "cdid", value: cdid),
            URLQueryItem(name: "device_type", value: deviceType),
            URLQueryItem(name: "os_version", value: osVersion),
            URLQueryItem(name: "build_number", value: build),
            URLQueryItem(name: "mcc_mnc", value: raw.mccMnc ?? "46011"),
            URLQueryItem(name: "screen_width", value: raw.screenWidth ?? "750"),
            URLQueryItem(name: "os_api", value: raw.osAPI ?? "18"),
            URLQueryItem(name: "ac", value: raw.ac ?? "WIFI"),
            URLQueryItem(name: "app_name", value: "aweme"),
            URLQueryItem(name: "channel", value: "App Store"),
            URLQueryItem(name: "aid", value: "1128"),
            URLQueryItem(name: "package", value: "com.ss.iphone.ugc.Aweme"),
            URLQueryItem(name: "device_platform", value: "iphone")
        ].filter { !($0.value ?? "").isEmpty }

        guard let url = comps?.url else { return "无法检测" }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(token, forHTTPHeaderField: "X-Tt-Token")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(
            "Aweme \(appVersion) rv:\(build) (iPhone; iOS \(osVersion); zh_CN) Cronet",
            forHTTPHeaderField: "User-Agent"
        )

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: cfg)
        let sem = DispatchSemaphore(value: 0)
        var result = "无法检测"
        session.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                result = code == 0 ? "无法检测" : "否"
                return
            }
            let fee = ((json["data"] as? [String: Any])?["fee"] as? [Any]) ?? []
            result = fee.isEmpty ? "否" : "是"
        }.resume()
        _ = sem.wait(timeout: .now() + 16)
        return result
    }

    // MARK: - Country / device / time

    private static func detectCountry(mobile: String?, fallbackUID: String?) -> String {
        let phone = (mobile ?? fallbackUID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if phone.isEmpty { return "—" }
        var p = phone
        if p.hasPrefix("+") { p.removeFirst() }

        // 中国 11 位 1 开头（含掩码）
        if p.count >= 11, p.first == "1" { return "中国" }

        let map: [(String, String)] = [
            ("852", "中国香港"), ("853", "中国澳门"), ("886", "中国台湾"),
            ("63", "菲律宾"), ("66", "泰国"), ("62", "印尼"), ("60", "马来西亚"),
            ("65", "新加坡"), ("84", "越南"), ("86", "中国"), ("81", "日本"),
            ("82", "韩国"), ("44", "英国"), ("1", "美加")
        ].sorted { $0.0.count > $1.0.count }

        for (prefix, name) in map where p.hasPrefix(prefix) {
            return name
        }
        return "—"
    }

    private static func formatRegisterToMinute(_ raw: String?) -> String {
        guard let raw = nonEmpty(raw) else { return "—" }
        if let n = Double(raw) {
            return formatUnixToMinute(n)
        }
        // 已是日期字符串
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 16 {
            // YYYY-MM-DD HH:mm:ss → 到分
            return String(trimmed.prefix(16))
        }
        if trimmed.count >= 10 { return String(trimmed.prefix(10)) }
        return trimmed
    }

    private static func formatUnixToMinute(_ ts: Double) -> String {
        // 秒 / 毫秒兼容
        let sec = ts > 10_000_000_000 ? ts / 1000.0 : ts
        let date = Date(timeIntervalSince1970: sec)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func friendlyDeviceName(_ code: String) -> String {
        let map: [String: String] = [
            "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE",
            "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
            "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
            "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
            "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,6": "iPhone SE (3)", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus"
        ]
        if let name = map[code] { return "\(name)（\(code)）" }
        return code
    }

    // MARK: - Keyed archive helpers（与 DouyinAccountProbe 同思路）

    private static func keyedObjects(_ data: Data) -> [Any]? {
        guard data.count >= 8, data.prefix(8) == Data("bplist00".utf8) else { return nil }
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objs = root["$objects"] as? [Any] else { return nil }
        return objs
    }

    private static func flattenNSDictionary(_ dict: [String: Any], objects: [Any]) -> [String: String] {
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
            if let s = v as? String {
                out[k] = s
            } else if let n = v as? NSNumber {
                out[k] = n.stringValue
            } else if let idx = uidIndex(v), idx < objects.count {
                if let s = objects[idx] as? String { out[k] = s }
                else if let n = objects[idx] as? NSNumber { out[k] = n.stringValue }
            }
        }
        return out
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

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
