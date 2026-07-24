import Foundation
import Network

/// 不打开抖音：从沙盒 Preferences 读当前账号，并检测商城本地资源 + 本机网络
enum DouyinAccountProbe {
    struct Report: Sendable {
        var ok: Bool
        var message: String
        var hasAccount: Bool
        var hasToken: Bool
        var mallLocalReady: Bool
        var networkOK: Bool
    }

    static func inspect(cleaner: SlimCleaner) -> Report {
        guard let container = cleaner.locateAwemeContainer() else {
            return .init(
                ok: false,
                message: "未找到抖音容器（请确认已安装抖音，且本软件用巨魔安装）",
                hasAccount: false,
                hasToken: false,
                mallLocalReady: false,
                networkOK: false
            )
        }

        let account = readAccount(from: container)
        let mall = checkMallLocal(container: container)
        let net = checkNetworkSync()
        let session = probeSessionLite(token: account.token, deviceID: account.deviceID)

        var lines: [String] = []
        lines.append("—— 当前账号（未打开抖音）——")
        if account.hasAny {
            if let v = account.uniqueID, !v.isEmpty { lines.append("抖音号：\(v)") }
            if let v = account.nickname, !v.isEmpty { lines.append("昵称：\(v)") }
            if let v = account.userID, !v.isEmpty { lines.append("用户ID：\(v)") }
            if let v = account.mobile, !v.isEmpty { lines.append("手机：\(v)") }
            if let v = account.secUID, !v.isEmpty {
                lines.append("主页：https://www.douyin.com/user/\(v)")
            }
            if let v = account.deviceModel, !v.isEmpty { lines.append("设备：\(v)") }
            if let v = account.osVersion, !v.isEmpty { lines.append("系统：\(v)") }
            if let v = account.appVersion, !v.isEmpty { lines.append("抖音版本：\(v)") }
            if let v = account.deviceID, !v.isEmpty { lines.append("DID：\(v)") }
            if let t = account.token, !t.isEmpty {
                lines.append("x-tt-token：\(maskToken(t))")
            } else {
                lines.append("x-tt-token：未找到（可能未登录或 plist 被清）")
            }
        } else {
            lines.append("未解析到账号字段（Preferences 可能缺失）")
        }

        lines.append("")
        lines.append("—— 商城本地资源 ——")
        lines.append(mall.detail)

        lines.append("")
        lines.append("—— 网络（不启动抖音）——")
        lines.append(net.detail)
        lines.append(session)

        lines.append("")
        let canMall: String
        if !account.hasToken {
            canMall = "商城预判：弱（无登录 token，进商城大概率要重新登录）"
        } else if !mall.ready {
            canMall = "商城预判：中（已登录，但电商资源包偏少；首次进商城可能要拉包）"
        } else if !net.ok {
            canMall = "商城预判：弱（本机网络不通，打开也会白屏/失败）"
        } else {
            canMall = "商城预判：较强（有 token + 本地电商资源 + 网络可达；仍需进 App 最终确认 UI）"
        }
        lines.append(canMall)
        lines.append("说明：本检测不启动抖音；只读沙盒 + DY助手自己发请求。")

        return .init(
            ok: account.hasAny || mall.ready || net.ok,
            message: lines.joined(separator: "\n"),
            hasAccount: account.hasAny,
            hasToken: account.hasToken,
            mallLocalReady: mall.ready,
            networkOK: net.ok
        )
    }

    // MARK: - Account from plist（对齐 dy_parser / 抖音plist数据提取说明）

    private struct AccountInfo {
        var uniqueID: String?
        var nickname: String?
        var userID: String?
        var mobile: String?
        var secUID: String?
        var deviceModel: String?
        var osVersion: String?
        var appVersion: String?
        var deviceID: String?
        var token: String?

        var hasToken: Bool { !(token ?? "").isEmpty }
        var hasAny: Bool {
            [uniqueID, nickname, userID, mobile, secUID, token].contains { !($0 ?? "").isEmpty }
        }
    }

    private static func readAccount(from container: URL) -> AccountInfo {
        var info = AccountInfo()
        let fm = FileManager.default
        let pref = container.appendingPathComponent("Library/Preferences/com.ss.iphone.ugc.Aweme.plist")
        if let data = try? Data(contentsOf: pref),
           let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            parseOuterPlist(root, into: &info)
        }

        // ttinstall DID/IID
        let ttid = container.appendingPathComponent("Documents/_ttinstall_document/ttinstall_ids.plist")
        if let data = try? Data(contentsOf: ttid),
           let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            if info.deviceID == nil || info.deviceID?.isEmpty == true {
                let did = (root["kDeviceIDStorageKey"] as? String)
                    ?? (root["kClientDIDStorageKey"] as? String)
                if let did, !did.isEmpty { info.deviceID = did }
            }
        }

        let uidFile = container.appendingPathComponent("Documents/.uid")
        if info.userID == nil || info.userID?.isEmpty == true,
           fm.fileExists(atPath: uidFile.path),
           let s = try? String(contentsOf: uidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            info.userID = s
        }

        return info
    }

    private static func parseOuterPlist(_ root: [String: Any], into info: inout AccountInfo) {
        if let tok = root["bdaccount_session_x_tt_token"] as? String, !tok.isEmpty {
            info.token = tok
        }

        if let raw = root["com.toutiao.account.userdefault.user"] as? Data {
            parseKeyedArchiveUser(raw, into: &info)
        }
        if let raw = root["kDYACurrentLoginUserPersistenceKey"] as? Data {
            parseKeyedArchiveProfile(raw, into: &info)
        }

        // base64 设备 JSON
        for (_, v) in root {
            guard let s = v as? String, s.count > 80 else { continue }
            guard let dec = Data(base64Encoded: s) ?? Data(base64Encoded: s + "==") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: dec) as? [String: Any],
                  obj["device_id"] != nil else { continue }
            if info.deviceModel == nil { info.deviceModel = obj["device_type"] as? String }
            if info.osVersion == nil { info.osVersion = obj["os_version"] as? String }
            if info.appVersion == nil { info.appVersion = obj["app_version"] as? String }
            if info.deviceID == nil {
                if let d = obj["device_id"] { info.deviceID = "\(d)" }
            }
            break
        }

        if info.osVersion == nil || info.appVersion == nil {
            let ua = (root["AWEWebViewDefaultUA"] as? String) ?? (root["kBDPOriginUserAgentKey"] as? String) ?? ""
            if info.osVersion == nil,
               let m = ua.range(of: #"OS ([\d_]+)"#, options: .regularExpression) {
                let ver = String(ua[m]).replacingOccurrences(of: "OS ", with: "").replacingOccurrences(of: "_", with: ".")
                info.osVersion = ver
            }
            if info.appVersion == nil {
                if let cj = root["CJPayUserAgent"] as? String,
                   let r = cj.range(of: #"AID1128/([\d.]+)"#, options: .regularExpression) {
                    info.appVersion = String(cj[r]).replacingOccurrences(of: "AID1128/", with: "")
                } else if let v = root["kTTInstallServiceAppVersion"] as? String {
                    info.appVersion = v
                }
            }
            if info.deviceModel == nil {
                if ua.contains("iPad") { info.deviceModel = "iPad (iOS)" }
                else if ua.contains("iPhone") { info.deviceModel = "iPhone (iOS)" }
            }
        }
    }

    private static func parseKeyedArchiveUser(_ data: Data, into info: inout AccountInfo) {
        guard let inner = keyedObjects(data) else { return }
        for obj in inner {
            guard let dict = obj as? [String: Any] else { continue }
            let map = flattenNSDictionary(dict, objects: inner)
            if let v = map["screenName"] ?? map["name"], info.nickname == nil { info.nickname = v }
            if let v = map["userID"], info.userID == nil { info.userID = v }
            if let v = map["mobile"], info.mobile == nil { info.mobile = v }
            if let v = map["secUserId"], info.secUID == nil { info.secUID = v }
        }
    }

    private static func parseKeyedArchiveProfile(_ data: Data, into info: inout AccountInfo) {
        guard let inner = keyedObjects(data) else { return }
        for obj in inner {
            guard let dict = obj as? [String: Any] else { continue }
            let map = flattenNSDictionary(dict, objects: inner)
            guard map["unique_id"] != nil || map["nickname"] != nil || map["uid"] != nil else { continue }
            if let v = map["unique_id"], info.uniqueID == nil { info.uniqueID = v }
            if let v = map["short_id"], info.uniqueID == nil { info.uniqueID = v }
            if let v = map["nickname"], info.nickname == nil { info.nickname = v }
            if let v = map["uid"], info.userID == nil { info.userID = v }
            if let v = map["register_time"] {
                _ = v // 可选展示，先不占行
            }
            break
        }
    }

    private static func keyedObjects(_ data: Data) -> [Any]? {
        guard data.count >= 8, data.prefix(8) == Data("bplist00".utf8) else { return nil }
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objs = root["$objects"] as? [Any] else { return nil }
        return objs
    }

    /// 把 NSKeyedArchiver 的 NS.keys/NS.objects 字典摊平
    private static func flattenNSDictionary(_ dict: [String: Any], objects: [Any]) -> [String: String] {
        var out: [String: String] = [:]
        if let keys = dict["NS.keys"] as? [Any], let vals = dict["NS.objects"] as? [Any] {
            let n = min(keys.count, vals.count)
            for i in 0..<n {
                guard let ki = uidIndex(keys[i]), ki < objects.count,
                      let key = objects[ki] as? String else { continue }
                let val = resolveValue(vals[i], objects: objects)
                if let s = val as? String {
                    out[key] = s
                } else if let n = val as? NSNumber {
                    out[key] = n.stringValue
                }
            }
            return out
        }
        for (k, v) in dict {
            if k.hasPrefix("$") || k.hasPrefix("NS.") { continue }
            if let s = v as? String {
                out[k] = s
            } else if let idx = uidIndex(v), idx < objects.count, let s = objects[idx] as? String {
                out[k] = s
            }
        }
        return out
    }

    private static func resolveValue(_ any: Any, objects: [Any]) -> Any? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n }
        if let idx = uidIndex(any), idx < objects.count {
            let o = objects[idx]
            if let s = o as? String { return s }
            if let n = o as? NSNumber { return n }
            return o
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
        // 部分系统把 UID 暴露为整型
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    // MARK: - Mall local

    private struct MallLocal {
        var ready: Bool
        var detail: String
    }

    private static func checkMallLocal(container: URL) -> MallLocal {
        let fm = FileManager.default
        let gurd = container.appendingPathComponent("Library/Application Support/gurd_cache")
        var ecomFiles = 0
        var totalGurd = 0
        if let en = fm.enumerator(at: gurd, includingPropertiesForKeys: [.isRegularFileKey], options: []) {
            while let u = en.nextObject() as? URL {
                let vals = try? u.resourceValues(forKeys: [.isRegularFileKey])
                guard vals?.isRegularFile == true else { continue }
                totalGurd += 1
                let p = u.path.lowercased()
                if p.contains("ecommerce") || p.contains("aweec") || p.contains("ecom_")
                    || p.contains("/mall") || p.contains("mall_") || p.contains("goods_") {
                    ecomFiles += 1
                }
            }
        }

        let mmkvOK = fm.fileExists(atPath: container.appendingPathComponent("Documents/mmkv").path)
        let aweStorageOK = fm.fileExists(atPath: container.appendingPathComponent("Library/AWEStorage").path)
        let prefOK = fm.fileExists(atPath: container.appendingPathComponent("Library/Preferences/com.ss.iphone.ugc.Aweme.plist").path)

        // 经验阈值：H9 精简包里电商 png 很多；有几十个以上基本说明商城资源还在
        let ready = ecomFiles >= 20 && mmkvOK && (aweStorageOK || prefOK)
        var detail = "gurd 电商相关文件：\(ecomFiles)（总 gurd \(totalGurd)）\n"
        detail += mmkvOK ? "✓ mmkv\n" : "✗ mmkv\n"
        detail += aweStorageOK ? "✓ AWEStorage\n" : "✗ AWEStorage\n"
        detail += prefOK ? "✓ Aweme.plist\n" : "✗ Aweme.plist\n"
        detail += ready ? "本地商城资源：较完整" : "本地商城资源：不足或缺登录态文件"
        return .init(ready: ready, detail: detail)
    }

    // MARK: - Network（DY助手自己请求，不启动抖音）

    private struct NetResult {
        var ok: Bool
        var detail: String
    }

    private static func checkNetworkSync() -> NetResult {
        // 系统路径
        let monitor = NWPathMonitor()
        let sem = DispatchSemaphore(value: 0)
        var pathOK = false
        var pathDesc = "未知"
        monitor.pathUpdateHandler = { path in
            pathOK = path.status == .satisfied
            if path.usesInterfaceType(.wifi) { pathDesc = "Wi‑Fi" }
            else if path.usesInterfaceType(.cellular) { pathDesc = "蜂窝" }
            else if pathOK { pathDesc = "已连接" }
            else { pathDesc = "不可用" }
            sem.signal()
        }
        let q = DispatchQueue(label: "dy.probe.net")
        monitor.start(queue: q)
        _ = sem.wait(timeout: .now() + 1.5)
        monitor.cancel()

        // 轻量探测抖音/电商相关域名（仅连通性）
        let urls = [
            "https://www.douyin.com",
            "https://aweme.snssdk.com",
            "https://ecom.snssdk.com"
        ]
        var hits: [String] = []
        var anyHTTP = false
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 4
        let session = URLSession(configuration: cfg)
        for s in urls {
            guard let url = URL(string: s) else { continue }
            let sem2 = DispatchSemaphore(value: 0)
            var line = "\(url.host ?? s)：失败"
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            session.dataTask(with: req) { _, resp, err in
                if let http = resp as? HTTPURLResponse {
                    line = "\(url.host ?? s)：HTTP \(http.statusCode)"
                    if (200..<500).contains(http.statusCode) { anyHTTP = true }
                } else if let err {
                    // 部分 CDN 拒 HEAD，改试 GET 短超时
                    line = "\(url.host ?? s)：\(err.localizedDescription)"
                }
                sem2.signal()
            }.resume()
            _ = sem2.wait(timeout: .now() + 4.5)
            // HEAD 失败时补一次 GET
            if line.contains("失败") || line.contains("不支持") || line.contains("cancelled") {
                let sem3 = DispatchSemaphore(value: 0)
                session.dataTask(with: url) { _, resp, err in
                    if let http = resp as? HTTPURLResponse {
                        line = "\(url.host ?? s)：HTTP \(http.statusCode)"
                        if (200..<500).contains(http.statusCode) { anyHTTP = true }
                    } else if let err {
                        line = "\(url.host ?? s)：\(err.localizedDescription)"
                    }
                    sem3.signal()
                }.resume()
                _ = sem3.wait(timeout: .now() + 4.5)
            }
            hits.append(line)
        }

        let ok = pathOK && anyHTTP
        var detail = "系统网络：\(pathDesc)\n" + hits.joined(separator: "\n")
        detail += ok ? "\n结论：外网可达" : "\n结论：网络异常或域名不可达"
        return .init(ok: ok, detail: detail)
    }

    /// 用本地 token 轻探会话是否还活着（不打开抖音）
    private static func probeSessionLite(token: String?, deviceID: String?) -> String {
        guard let token, !token.isEmpty else {
            return "会话探测：跳过（无 token）"
        }
        // 公开用户信息接口形态因版本常变；这里只做「带 token 请求是否被拒」的粗测
        guard let url = URL(string: "https://aweme.snssdk.com/aweme/v1/user/profile/self/?device_id=\(deviceID ?? "0")") else {
            return "会话探测：URL 无效"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(token, forHTTPHeaderField: "x-tt-token")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("Aweme Chinese iOS", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 5

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: cfg)
        let sem = DispatchSemaphore(value: 0)
        var result = "会话探测：无响应"
        session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err {
                result = "会话探测：\(err.localizedDescription)"
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            if code == 200, body.contains("status_code") || body.contains("user") || body.contains("uid") {
                result = "会话探测：HTTP \(code)，像有有效回包（token 可能仍有效）"
            } else if code == 401 || code == 403 || body.contains("login") || body.contains("登录") {
                result = "会话探测：HTTP \(code)，疑似登录失效"
            } else {
                result = "会话探测：HTTP \(code)（接口可能变更，仅供参考）"
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        return result
    }

    private static func maskToken(_ t: String) -> String {
        if t.count <= 16 { return String(t.prefix(6)) + "…" }
        return String(t.prefix(12)) + "…" + String(t.suffix(6))
    }
}
