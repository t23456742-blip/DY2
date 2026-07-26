import Foundation
import SQLite3

/// 移机恢复后复制/粘贴修复：授权抖音剪贴板 TCC + 清理异常偏好
enum MigratePasteFix {
    struct Result: Sendable {
        var ok: Bool
        var message: String
    }

    private static let awemeIDs = [
        "com.ss.iphone.ugc.Aweme",
        "com.ss.iphone.ugc.Aweme.inhouse",
        "com.ss.iphone.ugc.aweme"
    ]

    private static let pasteServices = [
        "kTCCServicePasteboard",
        "kTCCServicePasteFromOtherApps",
        "Pasteboard",
        "PasteFromOtherApps"
    ]

    static func run(cleaner: SlimCleaner) -> Result {
        var notes: [String] = []

        // 1) 确保 Preferences 目录存在（移机缺文件时至少不崩）
        if let container = cleaner.locateAwemeContainer() {
            let prefs = container.appendingPathComponent("Library/Preferences", isDirectory: true)
            try? FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
            notes.append("已检查 Library/Preferences")
        } else {
            notes.append("未找到抖音容器（仍尝试修系统剪贴板权限）")
        }

        // 2) 写入 TCC 允许抖音粘贴（系统级，沙盒备份带不过来）
        let tccPaths = [
            "/var/mobile/Library/TCC/TCC.db",
            "/private/var/mobile/Library/TCC/TCC.db",
            "/Library/TCC/TCC.db"
        ]
        var tccOK = false
        for path in tccPaths {
            if grantPasteInTCC(dbPath: path) {
                tccOK = true
                notes.append("已授权剪贴板：\(path)")
                break
            }
        }
        if !tccOK {
            notes.append("TCC 写入失败（RootHide 下路径可能隔离，请在「设置→抖音→从其他 App 粘贴」手动允许）")
        }

        // 3) 清掉可能卡住的粘贴板偏好（不影响抖音沙盒主体）
        let pbPrefs = [
            "/var/mobile/Library/Preferences/com.apple.Pasteboard.plist",
            "/private/var/mobile/Library/Preferences/com.apple.Pasteboard.plist"
        ]
        for p in pbPrefs {
            if FileManager.default.fileExists(atPath: p) {
                // 不直接删系统文件，改为忽略；避免副作用
                notes.append("检测到系统 Pasteboard 偏好（未删除）")
                break
            }
        }

        let ok = tccOK || cleaner.locateAwemeContainer() != nil
        let tip = """
        \(notes.joined(separator: "\n"))

        说明：
        · 沙盒备份不含系统「粘贴权限」，移机后常会失效
        · 请完全退出抖音后重开；仍不行则到 设置→抖音→从其他 App 粘贴→允许
        · 备份时建议同时备份 App Group 容器，否则部分功能仍可能异常
        """
        return Result(ok: ok, message: tip.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func grantPasteInTCC(dbPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: dbPath) else { return false }

        // 备份
        let bak = dbPath + ".dyfixbak"
        try? FileManager.default.removeItem(atPath: bak)
        try? FileManager.default.copyItem(atPath: dbPath, toPath: bak)

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            return false
        }
        defer { sqlite3_close(db) }

        // 探测表结构
        let cols = tableColumns(db: db, table: "access")
        guard !cols.isEmpty else { return false }

        _ = exec(db, "BEGIN")
        var changed = false
        for service in pasteServices {
            for client in awemeIDs {
                if upsertAccess(db: db, columns: cols, service: service, client: client) {
                    changed = true
                }
            }
        }
        _ = exec(db, changed ? "COMMIT" : "ROLLBACK")
        return changed
    }

    private static func tableColumns(db: OpaquePointer, table: String) -> [String] {
        var stmt: OpaquePointer?
        var cols: [String] = []
        let sql = "PRAGMA table_info(\(table))"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1) {
                    cols.append(String(cString: c))
                }
            }
        }
        sqlite3_finalize(stmt)
        return cols
    }

    private static func upsertAccess(db: OpaquePointer, columns: [String], service: String, client: String) -> Bool {
        // 兼容旧版 / 新版 TCC access 表
        // 常见列: service, client, client_type, auth_value, auth_reason, auth_version, ...
        let now = Int(Date().timeIntervalSince1970)

        // 先删旧记录再插，避免唯一约束冲突
        let del = "DELETE FROM access WHERE service='\(escape(service))' AND client='\(escape(client))';"
        _ = exec(db, del)

        if columns.contains("auth_value") && columns.contains("client_type") {
            // iOS 15/16 常见
            var fields = ["service", "client", "client_type", "auth_value"]
            var values: [String] = ["'\(escape(service))'", "'\(escape(client))'", "0", "2"]
            if columns.contains("auth_reason") { fields.append("auth_reason"); values.append("2") }
            if columns.contains("auth_version") { fields.append("auth_version"); values.append("1") }
            if columns.contains("last_modified") { fields.append("last_modified"); values.append("\(now)") }
            if columns.contains("flags") { fields.append("flags"); values.append("0") }
            // 只插入表里存在的列
            let pairs = zip(fields, values).filter { columns.contains($0.0) }
            let sql = "INSERT INTO access (\(pairs.map(\.0).joined(separator: ","))) VALUES (\(pairs.map(\.1).joined(separator: ",")));"
            return exec(db, sql)
        }

        // 更老结构 fallback
        if columns.contains("allowed") {
            let sql = "INSERT INTO access (service, client, client_type, allowed, prompt_count, csreq, policy_id) VALUES ('\(escape(service))','\(escape(client))',0,1,0,NULL,NULL);"
            return exec(db, sql)
        }
        return false
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    @discardableResult
    private static func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK
        if let err { sqlite3_free(err) }
        return ok
    }
}
