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
        // UA 兜底：至少显示 iPhone + 系统版本
        if snap.deviceModel == "—" {
            snap.deviceModel = uaFallbackModel(raw: raw)
        }
        snap.osVersion = nonEmpty(raw.osVersion) ?? "—"
        snap.appVersion = nonEmpty(raw.appVersion) ?? "—"
        snap.registerTime = formatRegisterToMinute(raw.registerTimeRaw)
        snap.country = detectCountry(mobile: raw.mobile, fallbackUID: uid)

        // 1) 直连 iesdouyin 查状态/昵称（无代理；对齐桌面 Windows UA）
        if let uid, !uid.isEmpty {
            let api = queryUserInfoNoProxy(uniqueID: uid, secUID: raw.secUID, token: raw.token)
            if !api.status.isEmpty { snap.status = api.status }
            if snap.nickname == "—" || snap.nickname.isEmpty, let n = api.nickname, !n.isEmpty {
                snap.nickname = n
            }
            if snap.registerTime == "—", let ct = api.createTimeMinute {
                snap.registerTime = ct
            }
        } else {
            let pref = container.appendingPathComponent("Library/Preferences/com.ss.iphone.ugc.Aweme.plist")
            snap.status = FileManager.default.fileExists(atPath: pref.path) ? "plist无unique_id" : "无抖音号"
        }

        // 2) 钱包接口查是否在线（对齐桌面 check_token_online）
        snap.online = checkOnlineNoProxy(raw: raw)

        snap.ok = snap.douyinID != "—" || snap.nickname != "—"
        let missing: [String] = [
            raw.deviceType == nil ? "device_type" : nil,
            raw.token == nil ? "token" : nil,
            raw.deviceID == nil ? "did" : nil
        ].compactMap { $0 }
        snap.detail = "本机容器提参 + 直连查询（无代理）\n\(container.path)"
            + (missing.isEmpty ? "" : "\n缺字段：\(missing.joined(separator: ","))")
        return snap
    }

    // MARK: - Preferences / config

    private static func loadFromPreferences(_ container: URL, into raw: inout Raw) {
        let pref = container.appendingPathComponent("Library/Preferences/com.ss.iphone.ugc.Aweme.plist")
        guard let data = try? Data(contentsOf: pref),
              let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return }

        // 对齐桌面 dy_plist：从同一份 Aweme.plist 抠 unique_id / 注册时间 / 手机号
        let acct = AwemeKeyedArchive.loadAccount(fromRoot: root)
        if raw.uniqueID == nil { raw.uniqueID = acct["unique_id"] ?? acct["抖音号"] }
        if raw.shortID == nil { raw.shortID = acct["ShortID"] }
        if raw.nickname == nil { raw.nickname = acct["nickname"] ?? acct["昵称"] }
        if raw.userID == nil { raw.userID = acct["uid"] ?? acct["用户ID"] ?? acct["UserID"] }
        if raw.mobile == nil { raw.mobile = acct["mobile"] ?? acct["手机号"] }
        if raw.secUID == nil { raw.secUID = acct["secUserId"] ?? acct["SecUserID"] }
        if raw.registerTimeRaw == nil { raw.registerTimeRaw = acct["register_time"] ?? acct["注册时间"] }
        if raw.token == nil { raw.token = acct["x-tt-token"] }

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
        let cfg = AwemeTTNetConfig.load(fromContainer: container)
        guard !cfg.isEmpty else { return }
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

    // MARK: - API（无代理）

    private struct APIUser {
        var status: String = ""
        var nickname: String?
        var createTimeMinute: String?
    }

    /// 对齐桌面 douyin_panel：iesdouyin unique_id；失败再用 sec_uid+token 兜底
    private static func queryUserInfoNoProxy(uniqueID: String, secUID: String?, token: String?) -> APIUser {
        var out = queryIesDouyin(uniqueID: uniqueID)
        if out.status == "正常" || out.status == "封禁" || out.status == "违规"
            || out.status == "禁言" || out.status == "私密" || out.status == "参数非法" {
            return out
        }
        // 直连被拦 / 非 JSON → 用已登录 token + sec_uid 再查
        if let sec = nonEmpty(secUID), let tok = nonEmpty(token) {
            let alt = queryProfileBySecUID(secUID: sec, token: tok)
            if !alt.status.isEmpty { return alt }
        }
        return out.status.isEmpty ? APIUser(status: "查询失败") : out
    }

    private static func queryIesDouyin(uniqueID: String) -> APIUser {
        var out = APIUser()
        let enc = uniqueID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uniqueID
        guard let url = URL(string: "https://www.iesdouyin.com/web/api/v2/user/info/?unique_id=\(enc)") else {
            out.status = "查询失败"
            return out
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        // 桌面面板用 Windows Chrome UA；iPhone UA 更容易被拦成非 JSON
        req.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://www.iesdouyin.com/", forHTTPHeaderField: "Referer")
        req.setValue("close", forHTTPHeaderField: "Connection")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: cfg)
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if err != nil {
                out.status = "查询失败"
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                out.status = code == 0 ? "查询失败" : "接口拦截(\(code))"
                return
            }
            let sc = (json["status_code"] as? NSNumber)?.intValue
                ?? (json["status_code"] as? Int)
                ?? -1
            if sc == 5 {
                out.status = "参数非法"
                return
            }
            if sc != 0 {
                // 桌面遇非0非5会换代理重试；手机无代理时标明原因
                out.status = "接口拦截(sc=\(sc))"
                return
            }
            let user = (json["user_info"] as? [String: Any])
                ?? (json["user"] as? [String: Any])
                ?? ((json["data"] as? [String: Any])?["user_info"] as? [String: Any])
                ?? [:]
            out = parseUserStatus(user)
        }.resume()
        _ = sem.wait(timeout: .now() + 16)
        return out
    }

    private static func queryProfileBySecUID(secUID: String, token: String) -> APIUser {
        var out = APIUser()
        let enc = secUID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? secUID
        guard let url = URL(string: "https://www.iesdouyin.com/aweme/v1/web/user/profile/other/?sec_user_id=\(enc)") else {
            return out
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue(token, forHTTPHeaderField: "x-tt-token")
        req.setValue("https://www.iesdouyin.com/", forHTTPHeaderField: "Referer")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: cfg)
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let sc = (json["status_code"] as? NSNumber)?.intValue ?? (json["status_code"] as? Int) ?? -1
            guard sc == 0 else { return }
            let user = (json["user"] as? [String: Any])
                ?? ((json["data"] as? [String: Any])?["user"] as? [String: Any])
                ?? (json["user_info"] as? [String: Any])
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
        // 对齐桌面：缺省用兜底机型，避免空参直接被拒
        let deviceType = raw.deviceType ?? "iPhone10,6"
        let osVersion = raw.osVersion ?? "16.0"
        let appVersion = raw.appVersion ?? "23.9.0"
        let build = raw.buildNumber ?? "239013"

        var comps = URLComponents(string: "https://webcast5-normal-c-lf.amemv.com/webcast/wallet_api/mobile/plan/")
        comps?.queryItems = [
            URLQueryItem(name: "appTheme", value: "light"),
            URLQueryItem(name: "need_personal_recommend", value: "1"),
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
            URLQueryItem(name: "minor_status", value: "0"),
            URLQueryItem(name: "package", value: "com.ss.iphone.ugc.Aweme"),
            URLQueryItem(name: "device_platform", value: "iphone"),
            URLQueryItem(name: "is_vcd", value: "1"),
            URLQueryItem(name: "is_guest_mode", value: "0")
        ].filter { !($0.value ?? "").isEmpty }

        guard let url = comps?.url else { return "无法检测" }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(token, forHTTPHeaderField: "X-Tt-Token")
        req.setValue("3.1.0", forHTTPHeaderField: "X-Vc-Bdturing-Sdk-Version")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("2", forHTTPHeaderField: "Sdk-Version")
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
            // 桌面：HTTP 200 → 看 fee；非 200 → 掉线；异常 → 无法检测
            guard code == 200 else {
                result = code == 0 ? "无法检测" : "否"
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                result = "是" // 与桌面一致：解析失败保守当在线
                return
            }
            let fee = ((json["data"] as? [String: Any])?["fee"] as? [Any]) ?? []
            result = fee.isEmpty ? "否" : "是"
        }.resume()
        _ = sem.wait(timeout: .now() + 16)
        return result
    }

    private static func uaFallbackModel(raw: Raw) -> String {
        if let os = nonEmpty(raw.osVersion) {
            return "iPhone（iOS \(os)）"
        }
        return "—"
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

    /// Apple 内部代号 → 市面简称（14 / 14P / 14PM…）
    /// 注意：iPhone14,7 = 14，不是 14PM；14PM = iPhone15,3
    private static func friendlyDeviceName(_ code: String) -> String {
        let map: [String: String] = [
            // SE / 早期
            "iPhone8,1": "6s", "iPhone8,2": "6sP", "iPhone8,4": "SE1",
            "iPhone9,1": "7", "iPhone9,3": "7", "iPhone9,2": "7P", "iPhone9,4": "7P",
            "iPhone10,1": "8", "iPhone10,4": "8", "iPhone10,2": "8P", "iPhone10,5": "8P",
            "iPhone10,3": "X", "iPhone10,6": "X",
            "iPhone11,2": "XS", "iPhone11,4": "XSM", "iPhone11,6": "XSM", "iPhone11,8": "XR",
            "iPhone12,1": "11", "iPhone12,3": "11P", "iPhone12,5": "11PM", "iPhone12,8": "SE2",
            // 12
            "iPhone13,1": "12mini", "iPhone13,2": "12", "iPhone13,3": "12P", "iPhone13,4": "12PM",
            // 13（内部是 iPhone14,x）
            "iPhone14,4": "13mini", "iPhone14,5": "13", "iPhone14,2": "13P", "iPhone14,3": "13PM",
            "iPhone14,6": "SE3",
            // 14（内部是 iPhone14,7/8 + iPhone15,2/3）
            "iPhone14,7": "14", "iPhone14,8": "14Plus",
            "iPhone15,2": "14P", "iPhone15,3": "14PM",
            // 15
            "iPhone15,4": "15", "iPhone15,5": "15Plus",
            "iPhone16,1": "15P", "iPhone16,2": "15PM",
            // 16
            "iPhone17,3": "16", "iPhone17,4": "16Plus",
            "iPhone17,1": "16P", "iPhone17,2": "16PM",
            "iPhone17,5": "16e",
            // 17 / Air
            "iPhone18,3": "17", "iPhone18,1": "17P", "iPhone18,2": "17PM",
            "iPhone18,4": "Air"
        ]
        if let short = map[code] {
            return "\(short)（\(code)）"
        }
        return code
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
