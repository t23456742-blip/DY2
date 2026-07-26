import Foundation

/// 按扫描结果 / H9 常见缓存路径，在抖音沙盒里「随机新增」缓存文件（不覆盖账号关键文件）。
enum DouyinRandomCacheSeeder {
    struct Result: Sendable {
        var ok: Bool
        var created: Int
        var bytes: Int64
        var message: String
    }

    /// 禁止动的路径前缀（登录/号料）
    private static let forbiddenPrefixes: [String] = [
        "Documents/mmkv",
        "Documents/_ttinstall_document",
        "Documents/Aweme.db",
        "Documents/ttaccount",
        "Documents/server.json",
        "Documents/lsdata.plist",
        "Documents/db.sqlite3",
        "Library/AWEStorage",
        "Library/loginData.dat",
        "Library/Preferences",
        "Library/SyncedPreferences",
        "Library/AWEIMRoot/IMUser",
        ".com.apple.mobile_container_manager.metadata.plist"
    ]

    /// 随机缓存落点（对齐常见抖音缓存目录；H9 精简包本身不含这些，用来「养肥」沙盒）
    private static let seedRoots: [String] = [
        "Library/Caches",
        "Library/Caches/com.hackemist.SDWebImageCache.default",
        "Library/Caches/com.ss.iphone.ugc.Aweme",
        "Library/Caches/AWEStorage",
        "Library/Caches/tt_video_cache",
        "Library/Caches/request_cache",
        "Documents/Offline",
        "Documents/VideoCache",
        "Documents/Caches",
        "tmp"
    ]

    /// - Parameter hintRels: 扫描得到的相对路径（可保留+多余），用来推断还要往哪些目录塞
    static func seedRandomCache(into container: URL, hintRels: [String] = [], count: Int? = nil) -> Result {
        let fm = FileManager.default
        var targets = Set(seedRoots)
        for rel in hintRels {
            let r = rel.replacingOccurrences(of: "\\", with: "/")
            if isForbidden(r) { continue }
            let lower = r.lowercased()
            if lower.contains("cache") || lower.hasPrefix("library/caches")
                || lower.hasPrefix("tmp/") || lower.contains("offline")
                || lower.contains("videocache") || lower.contains("image") {
                let parent = (r as NSString).deletingLastPathComponent
                if !parent.isEmpty, parent != "." {
                    targets.insert(parent)
                }
            }
        }

        let goal = count ?? Int.random(in: 80...180)
        var created = 0
        var totalBytes: Int64 = 0
        var usedNames = Set<String>()

        for root in targets {
            try? fm.createDirectory(
                at: container.appendingPathComponent(root, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        var guardRounds = 0
        while created < goal, guardRounds < goal * 4 {
            guardRounds += 1
            let folder = targets.randomElement() ?? "Library/Caches"
            if isForbidden(folder) { continue }

            let sub: String
            if Bool.random() {
                sub = folder
            } else {
                sub = folder + "/" + randomDirName()
            }
            if isForbidden(sub) { continue }

            let dirURL = container.appendingPathComponent(sub, isDirectory: true)
            try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)

            let name = randomFileName()
            let rel = sub + "/" + name
            if isForbidden(rel) || usedNames.contains(rel) { continue }
            usedNames.insert(rel)

            let size = Int.random(in: 512...(48 * 1024))
            let data = randomData(size: size)
            let dest = container.appendingPathComponent(rel)
            do {
                try data.write(to: dest, options: .atomic)
                created += 1
                totalBytes += Int64(size)
            } catch {
                continue
            }
        }

        // 再写几份「看起来像」hostcache / 列表缓存的小文件（仅当不存在时）
        let softFiles: [(String, ClosedRange<Int>)] = [
            ("Documents/uni_comm_cache.plist", 64...512),
            ("tmp/rand_cache_meta.dat", 256...2048)
        ]
        for (rel, range) in softFiles {
            if isForbidden(rel) { continue }
            let url = container.appendingPathComponent(rel)
            if fm.fileExists(atPath: url.path) { continue }
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = randomData(size: Int.random(in: range))
            if (try? data.write(to: url, options: .atomic)) != nil {
                created += 1
                totalBytes += Int64(data.count)
            }
        }

        let tip: String
        if created == 0 {
            tip = "未写入任何缓存（权限或路径不可写）"
        } else {
            tip = "已随机新增 \(created) 个缓存文件（约 \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))）\n目录含 Library/Caches、VideoCache、tmp 等\n未改动 mmkv / Aweme.db / AWEStorage 等账号文件\n请划掉抖音后重开"
        }
        return .init(ok: created > 0, created: created, bytes: totalBytes, message: tip)
    }

    private static func isForbidden(_ rel: String) -> Bool {
        let r = rel.replacingOccurrences(of: "\\", with: "/")
        for p in forbiddenPrefixes {
            if r == p || r.hasPrefix(p) || r.hasPrefix(p + "/") { return true }
        }
        let name = (r as NSString).lastPathComponent
        if name == ".com.apple.mobile_container_manager.metadata.plist" { return true }
        return false
    }

    private static func randomDirName() -> String {
        switch Int.random(in: 0...3) {
        case 0:
            return String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
        case 1:
            return "v\(Int.random(in: 1...9))_\(Int.random(in: 1000...9999))"
        case 2:
            return "img_\(Int.random(in: 10_000...99_999))"
        default:
            return String(format: "part_%02x%02x", Int.random(in: 0...255), Int.random(in: 0...255))
        }
    }

    private static func randomFileName() -> String {
        let exts = ["dat", "cache", "tmp", "bin", "jpg", "mp4", "0", "1"]
        let ext = exts.randomElement()!
        let a = UInt32.random(in: 0...UInt32.max)
        let b = UInt32.random(in: 0...UInt32.max)
        switch Int.random(in: 0...4) {
        case 0:
            return String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)).lowercased() + "." + ext
        case 1:
            return String(format: "%08x%08x.%@", a, b, ext)
        case 2:
            return "f_\(Int.random(in: 1_000_000...9_999_999)).\(ext)"
        case 3:
            return "cache_\(Int.random(in: 100...999)).\(ext)"
        default:
            return "\(Int(Date().timeIntervalSince1970))_\(Int.random(in: 10...99)).\(ext)"
        }
    }

    private static func randomData(size: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0..<size {
            bytes[i] = UInt8.random(in: 0...255)
        }
        // 夹一点可读头，避免全 0 被当空洞
        let stamp = Array("DYHC\(Int.random(in: 1000...9999))".utf8)
        for (i, b) in stamp.enumerated() where i < size {
            bytes[i] = b
        }
        return Data(bytes)
    }
}
