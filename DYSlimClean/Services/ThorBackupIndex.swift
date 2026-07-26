import Foundation

/// 雷神 Thor 备份索引：`backup_index.plist`
/// - name：备注（常为「抖音号-密码」）
/// - folderPath：备份包目录，如 `/var/mobile/Media/Thor/Backups/2026-07-26-23-46-38-98`
enum ThorBackupIndex {
    struct Entry: Identifiable, Sendable {
        var id: String { folderPath + "|" + name }
        var name: String          // 备注
        var createdAt: String
        var folderPath: String
        var bundleIDs: [String]
        var appNames: [String]
        var sizeBytes: Int64

        var sizeText: String {
            ContainerDiskSize.format(sizeBytes)
        }
    }

    static let indexCandidates = [
        "/var/mobile/Thor/backup_index.plist",
        "/private/var/mobile/Thor/backup_index.plist",
        "/var/mobile/Media/Thor/backup_index.plist",
        "/private/var/mobile/Media/Thor/backup_index.plist"
    ]

    static func load() -> [Entry] {
        let fm = FileManager.default
        for path in indexCandidates where fm.fileExists(atPath: path) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let arr = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [[String: Any]]
            else { continue }
            return arr.compactMap { parse($0) }.sorted { $0.createdAt > $1.createdAt }
        }
        // 无索引时，直接扫 Backups 目录
        return scanBackupFolders()
    }

    private static func parse(_ dict: [String: Any]) -> Entry? {
        let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folder = (dict["folderPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !folder.isEmpty else { return nil }
        let created = (dict["createdAt"] as? String) ?? ""
        let bundles = (dict["bundleIDs"] as? [String]) ?? []
        let apps = (dict["appNames"] as? [String]) ?? []
        let size: Int64
        if let n = dict["sizeBytes"] as? NSNumber {
            size = n.int64Value
        } else if let i = dict["sizeBytes"] as? Int {
            size = Int64(i)
        } else {
            size = 0
        }
        return Entry(
            name: name.isEmpty ? URL(fileURLWithPath: folder).lastPathComponent : name,
            createdAt: created,
            folderPath: folder,
            bundleIDs: bundles,
            appNames: apps,
            sizeBytes: size
        )
    }

    private static func scanBackupFolders() -> [Entry] {
        let roots = [
            "/var/mobile/Media/Thor/Backups",
            "/private/var/mobile/Media/Thor/Backups",
            "/var/mobile/Thor/Backups",
            "/private/var/mobile/Thor/Backups"
        ]
        let fm = FileManager.default
        var out: [Entry] = []
        for root in roots {
            guard let kids = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in kids {
                let path = (root as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                out.append(Entry(
                    name: name,
                    createdAt: "",
                    folderPath: path,
                    bundleIDs: [],
                    appNames: [],
                    sizeBytes: 0
                ))
            }
        }
        return out.sorted { $0.name > $1.name }
    }

    /// 在备份包内找抖音数据根（含 Documents/mmkv 或 Aweme.plist）
    static func findAwemeDataRoot(inBackup folderPath: String) -> URL? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: folderPath, isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return nil }

        // 常见：Backups/xxx/com.ss.iphone.ugc.Aweme/ 或直接是容器内容
        let direct = [
            root.appendingPathComponent("com.ss.iphone.ugc.Aweme"),
            root.appendingPathComponent("Aweme"),
            root
        ]
        for u in direct where looksLikeAwemeContainer(u) {
            return u
        }

        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        var budget = 4000
        while let u = en.nextObject() as? URL {
            budget -= 1
            if budget <= 0 { break }
            if u.lastPathComponent.caseInsensitiveCompare("com.ss.iphone.ugc.Aweme") == .orderedSame,
               looksLikeAwemeContainer(u) {
                return u
            }
            if u.lastPathComponent == "Aweme.db" || u.lastPathComponent == "com.ss.iphone.ugc.Aweme.plist" {
                // 上溯到容器根：…/Documents/Aweme.db → …
                let container = u.deletingLastPathComponent().deletingLastPathComponent()
                if looksLikeAwemeContainer(container) { return container }
            }
        }
        return nil
    }

    private static func looksLikeAwemeContainer(_ url: URL) -> Bool {
        let fm = FileManager.default
        let checks = [
            "Documents/Aweme.db",
            "Documents/mmkv",
            "Documents/_ttinstall_document",
            "Library/Preferences/com.ss.iphone.ugc.Aweme.plist"
        ]
        return checks.contains { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
    }
}
