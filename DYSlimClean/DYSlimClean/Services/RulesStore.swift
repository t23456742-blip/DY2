import Foundation

enum RuleMode: String, Codable, CaseIterable {
    case defaultSlim   // 默认精简
    case defaultPlus   // 默认精简 + 额外保留
    case fullCustom    // 完全按勾选（勾选保留/不勾选删除）
}

struct RuleProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var mode: RuleMode
    /// fullCustom：全部保留项；defaultPlus：在默认精简之上额外保留的项
    var paths: [String]
    var isFavorite: Bool
    var updatedAt: Date

    static func makeDefaultSlim() -> RuleProfile {
        RuleProfile(
            id: "builtin.default.slim",
            name: "默认精简",
            mode: .defaultSlim,
            paths: [],
            isFavorite: true,
            updatedAt: Date()
        )
    }
}

/// 永久保存多套规则 + 收藏 + 当前选用
final class RulesStore {
    static let shared = RulesStore()

    private(set) var profiles: [RuleProfile] = []
    private(set) var activeProfileId: String

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("DYSlimClean", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("rule_profiles.json")
    }

    private init() {
        activeProfileId = UserDefaults.standard.string(forKey: "dy.slim.activeProfileId") ?? "builtin.default.slim"
        load()
        migrateLegacyIfNeeded()
        ensureBuiltin()
        if profiles.first(where: { $0.id == activeProfileId }) == nil {
            activeProfileId = "builtin.default.slim"
        }
    }

    var activeProfile: RuleProfile {
        profiles.first(where: { $0.id == activeProfileId }) ?? .makeDefaultSlim()
    }

    var useCustomRules: Bool {
        activeProfile.mode != .defaultSlim
    }

    var customPaths: Set<String> {
        Set(activeProfile.paths)
    }

    func selectProfile(id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileId = id
        UserDefaults.standard.set(id, forKey: "dy.slim.activeProfileId")
        persist()
    }

    /// 永久保存/覆盖当前规则内容
    func saveActive(name: String? = nil, mode: RuleMode, paths: Set<String>, favorite: Bool? = nil) {
        var set = paths
        set.insert("Documents/_ttinstall_document")
        if var p = profiles.first(where: { $0.id == activeProfileId }) {
            if p.id == "builtin.default.slim" {
                // 内置默认不允许改成别的内容；若用户要保存，另存
                let neu = RuleProfile(
                    id: UUID().uuidString,
                    name: name ?? "精简扩展 \(shortStamp())",
                    mode: mode == .defaultSlim ? .defaultPlus : mode,
                    paths: Array(set).sorted(),
                    isFavorite: favorite ?? false,
                    updatedAt: Date()
                )
                profiles.append(neu)
                activeProfileId = neu.id
            } else {
                if let name { p.name = name }
                p.mode = mode
                p.paths = Array(set).sorted()
                if let favorite { p.isFavorite = favorite }
                p.updatedAt = Date()
                if let idx = profiles.firstIndex(where: { $0.id == p.id }) {
                    profiles[idx] = p
                }
            }
        } else {
            let neu = RuleProfile(
                id: UUID().uuidString,
                name: name ?? "我的规则",
                mode: mode,
                paths: Array(set).sorted(),
                isFavorite: favorite ?? false,
                updatedAt: Date()
            )
            profiles.append(neu)
            activeProfileId = neu.id
        }
        UserDefaults.standard.set(activeProfileId, forKey: "dy.slim.activeProfileId")
        persist()
    }

    /// 另存为新规则（永久）
    func saveAsNew(name: String, mode: RuleMode, paths: Set<String>, favorite: Bool) {
        var set = paths
        set.insert("Documents/_ttinstall_document")
        let neu = RuleProfile(
            id: UUID().uuidString,
            name: name,
            mode: mode,
            paths: Array(set).sorted(),
            isFavorite: favorite,
            updatedAt: Date()
        )
        profiles.append(neu)
        activeProfileId = neu.id
        UserDefaults.standard.set(activeProfileId, forKey: "dy.slim.activeProfileId")
        persist()
    }

    func toggleFavorite(id: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        if profiles[idx].id == "builtin.default.slim" {
            profiles[idx].isFavorite = true
            persist()
            return
        }
        profiles[idx].isFavorite.toggle()
        profiles[idx].updatedAt = Date()
        persist()
    }

    func deleteProfile(id: String) {
        guard id != "builtin.default.slim" else { return }
        profiles.removeAll { $0.id == id }
        if activeProfileId == id {
            activeProfileId = "builtin.default.slim"
            UserDefaults.standard.set(activeProfileId, forKey: "dy.slim.activeProfileId")
        }
        persist()
    }

    func restoreDefaultSlim() {
        activeProfileId = "builtin.default.slim"
        UserDefaults.standard.set(activeProfileId, forKey: "dy.slim.activeProfileId")
        persist()
    }

    func isKeptByActiveRules(_ rel: String, defaultKeep: (String) -> Bool) -> Bool {
        if rel == "Documents/_ttinstall_document" || rel.hasPrefix("Documents/_ttinstall_document/") {
            return true
        }
        let p = activeProfile
        switch p.mode {
        case .defaultSlim:
            return defaultKeep(rel)
        case .defaultPlus:
            if defaultKeep(rel) { return true }
            return matched(rel, in: Set(p.paths))
        case .fullCustom:
            return matched(rel, in: Set(p.paths))
        }
    }

    private func matched(_ rel: String, in paths: Set<String>) -> Bool {
        if paths.contains(rel) { return true }
        for p in paths where rel.hasPrefix(p + "/") { return true }
        return false
    }

    private func ensureBuiltin() {
        if !profiles.contains(where: { $0.id == "builtin.default.slim" }) {
            profiles.insert(.makeDefaultSlim(), at: 0)
        } else if let idx = profiles.firstIndex(where: { $0.id == "builtin.default.slim" }) {
            profiles[idx].name = "默认精简"
            profiles[idx].mode = .defaultSlim
            profiles[idx].isFavorite = true
        }
        persist()
    }

    private func migrateLegacyIfNeeded() {
        let enabledKey = "dy.slim.useCustomRules"
        let customKey = "dy.slim.customKeepPaths"
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        if let arr = UserDefaults.standard.array(forKey: customKey) as? [String], !arr.isEmpty {
            let neu = RuleProfile(
                id: UUID().uuidString,
                name: "旧版自定义",
                mode: .fullCustom,
                paths: arr.sorted(),
                isFavorite: false,
                updatedAt: Date()
            )
            if !profiles.contains(where: { $0.name == "旧版自定义" }) {
                profiles.append(neu)
                activeProfileId = neu.id
            }
        }
        UserDefaults.standard.set(false, forKey: enabledKey)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([RuleProfile].self, from: data) else {
            profiles = [.makeDefaultSlim()]
            return
        }
        profiles = decoded
    }

    private func persist() {
        profiles.sort { a, b in
            if a.id == "builtin.default.slim" { return true }
            if b.id == "builtin.default.slim" { return false }
            if a.isFavorite != b.isFavorite { return a.isFavorite && !b.isFavorite }
            return a.updatedAt > b.updatedAt
        }
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: fileURL, options: .atomic)
        }
        UserDefaults.standard.set(activeProfileId, forKey: "dy.slim.activeProfileId")
    }

    private func shortStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMdd-HHmm"
        return f.string(from: Date())
    }
}
