import Foundation

/// 自定义保留规则（打钩保存）；关闭自定义时走默认规则
final class RulesStore {
    static let shared = RulesStore()

    private let customKey = "dy.slim.customKeepPaths"
    private let enabledKey = "dy.slim.useCustomRules"

    private(set) var useCustomRules: Bool
    private(set) var customPaths: Set<String>

    private init() {
        useCustomRules = UserDefaults.standard.bool(forKey: enabledKey)
        if let arr = UserDefaults.standard.array(forKey: customKey) as? [String] {
            customPaths = Set(arr)
        } else {
            customPaths = []
        }
    }

    func saveCustom(paths: Set<String>) {
        customPaths = paths
        useCustomRules = true
        UserDefaults.standard.set(Array(paths).sorted(), forKey: customKey)
        UserDefaults.standard.set(true, forKey: enabledKey)
    }

    /// 恢复默认规则（取消自定义）
    func restoreDefault() {
        useCustomRules = false
        customPaths = []
        UserDefaults.standard.set(false, forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: customKey)
    }

    func isKeptByCustom(_ rel: String) -> Bool {
        if customPaths.contains(rel) { return true }
        for p in customPaths {
            if rel.hasPrefix(p + "/") { return true }
        }
        return false
    }
}
