import Foundation

/// 雷蛇 RAZER 备份包扫描
/// 根目录：`/private/var/mobile/Media/RAZER`
/// 包名示例：`20260727-17-25-54` → 其下 `com.ss.iphone.ugc.Aweme` 为抖音数据
enum RazerBackupIndex {
    struct Entry: Identifiable, Sendable {
        var id: String { resolvedPath }
        /// 备份包文件夹名（时间戳）
        var name: String
        var resolvedPath: String
        var sizeBytes: Int64
        var queryStatus: String = ""
        var queryOnline: String = ""
        /// 查询后写回的抖音号（列表展示用）
        var queryAccount: String = ""

        var sizeText: String {
            sizeBytes > 0 ? ContainerDiskSize.format(sizeBytes) : "—"
        }

        var displayPath: String { resolvedPath }

        var listTitle: String {
            queryAccount.isEmpty ? name : queryAccount
        }

        var listSubtitle: String {
            queryAccount.isEmpty ? "备份包 · \(sizeText)" : "\(name) · \(sizeText)"
        }
    }

    static let roots = [
        "/private/var/mobile/Media/RAZER",
        "/var/mobile/Media/RAZER"
    ]

    /// 是否存在 RAZER 目录（未安装雷蛇时为 false）
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        return roots.contains { fm.fileExists(atPath: $0) }
    }

    /// 扫描全部备份包（有 Aweme 子目录的时间戳文件夹），新→旧
    static func load() -> [Entry] {
        let fm = FileManager.default
        var byPath: [String: Entry] = [:]

        for root in roots where fm.fileExists(atPath: root) {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names {
                let pack = (root as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: pack, isDirectory: &isDir), isDir.boolValue else { continue }
                // 跳过非包目录（隐藏文件、索引等）
                if name.hasPrefix(".") { continue }
                guard hasAwemePack(at: pack) else { continue }

                let key = pack
                if byPath[key] != nil { continue }
                byPath[key] = Entry(
                    name: name,
                    resolvedPath: pack,
                    sizeBytes: measureSize(pack)
                )
            }
            // 已扫到 private 根则不再扫 /var 镜像
            if root.hasPrefix("/private/") { break }
        }

        return byPath.values.sorted { a, b in
            if a.name != b.name { return a.name > b.name }
            return a.resolvedPath > b.resolvedPath
        }
    }

    private static func hasAwemePack(at packPath: String) -> Bool {
        let fm = FileManager.default
        let candidates = [
            (packPath as NSString).appendingPathComponent("com.ss.iphone.ugc.Aweme"),
            (packPath as NSString).appendingPathComponent("com.ss.iphone.ugc.aweme")
        ]
        for p in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                return true
            }
        }
        // 也接受包根本身就是 Aweme 容器的情况
        return ThorBackupIndex.findAwemeDataRoot(inBackup: packPath) != nil
    }

    private static func measureSize(_ path: String) -> Int64 {
        ContainerDiskSize.byteSize(of: URL(fileURLWithPath: path), budget: 50_000)
    }
}
