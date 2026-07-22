import Foundation
import Combine

struct RuleNode: Identifiable, Hashable {
    let id: String          // relative path
    let name: String
    let isDirectory: Bool
    let depth: Int
}

@MainActor
final class RulesViewModel: ObservableObject {
    @Published var nodes: [RuleNode] = []
    @Published var checked: Set<String> = []
    @Published var expanded: Set<String> = []
    @Published var statusText = "点击刷新加载抖音目录"
    @Published var useCustom = false
    @Published var isBusy = false
    @Published var toast = ""

    private let cleaner = SlimCleaner()
    private var childrenCache: [String: [RuleNode]] = [:]

    func bootstrap() {
        useCustom = RulesStore.shared.useCustomRules
        if useCustom {
            checked = RulesStore.shared.customPaths
            statusText = "当前：自定义规则（\(checked.count) 项）"
        } else {
            checked = SlimCleaner.defaultCheckedPaths()
            statusText = "当前：默认规则（Documents 指定项 + 精简包白名单）"
        }
        // _ttinstall 强制勾选且不可取消在 UI 层处理
        checked.insert("Documents/_ttinstall_document")
        refreshTree()
    }

    func refreshTree() {
        isBusy = true
        statusText = "正在读取抖音目录…"
        Task.detached(priority: .userInitiated) { [cleaner] in
            guard let container = cleaner.locateAwemeContainer() else {
                await MainActor.run {
                    self.nodes = []
                    self.isBusy = false
                    self.statusText = "未找到抖音容器"
                }
                return
            }
            let top = Self.listChildren(of: "", under: container, depth: 0)
            await MainActor.run {
                self.childrenCache[""] = top
                self.rebuildVisible()
                self.isBusy = false
                self.statusText = self.useCustom
                    ? "自定义规则 · 已加载 \(top.count) 个顶层项"
                    : "默认规则 · 已加载 \(top.count) 个顶层项 · 可勾选后保存为自定义"
            }
        }
    }

    func toggleExpand(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
            rebuildVisible()
            return
        }
        expanded.insert(path)
        if childrenCache[path] == nil, let container = cleaner.locateAwemeContainer() {
            childrenCache[path] = Self.listChildren(of: path, under: container, depth: path.split(separator: "/").count)
        }
        rebuildVisible()
    }

    func toggleCheck(_ path: String) {
        // 强制保留
        if path == "Documents/_ttinstall_document" || path.hasPrefix("Documents/_ttinstall_document/") {
            checked.insert(path == "Documents/_ttinstall_document" ? path : "Documents/_ttinstall_document")
            toast = "_ttinstall_document 不可取消"
            return
        }
        if checked.contains(path) {
            checked.remove(path)
        } else {
            checked.insert(path)
        }
    }

    func isForced(_ path: String) -> Bool {
        path == "Documents/_ttinstall_document" || path.hasPrefix("Documents/_ttinstall_document/")
    }

    func isEffectivelyChecked(_ path: String) -> Bool {
        if isForced(path) { return true }
        if checked.contains(path) { return true }
        var parts = path.split(separator: "/").map(String.init)
        while parts.count > 1 {
            parts.removeLast()
            if checked.contains(parts.joined(separator: "/")) { return true }
        }
        return false
    }

    func saveRules() {
        var set = checked
        set.insert("Documents/_ttinstall_document")
        RulesStore.shared.saveCustom(paths: set)
        useCustom = true
        toast = "已保存自定义规则（\(set.count) 项）"
        statusText = "当前：自定义规则（\(set.count) 项）"
    }

    func applyDefault() {
        RulesStore.shared.restoreDefault()
        useCustom = false
        checked = SlimCleaner.defaultCheckedPaths()
        checked.insert("Documents/_ttinstall_document")
        toast = "已恢复默认规则"
        statusText = "当前：默认规则（Documents 指定项 + 精简包白名单）"
    }

    private func rebuildVisible() {
        var result: [RuleNode] = []
        func walk(_ parent: String) {
            let kids = childrenCache[parent] ?? []
            for n in kids {
                result.append(n)
                if n.isDirectory, expanded.contains(n.id) {
                    if childrenCache[n.id] == nil, let container = cleaner.locateAwemeContainer() {
                        childrenCache[n.id] = Self.listChildren(of: n.id, under: container, depth: n.depth + 1)
                    }
                    walk(n.id)
                }
            }
        }
        walk("")
        nodes = result
    }

    nonisolated private static func listChildren(of relativeParent: String, under container: URL, depth: Int) -> [RuleNode] {
        let fm = FileManager.default
        let dirURL: URL
        if relativeParent.isEmpty {
            dirURL = container
        } else {
            dirURL = container.appendingPathComponent(relativeParent)
        }
        guard let names = try? fm.contentsOfDirectory(atPath: dirURL.path) else { return [] }

        var nodes: [RuleNode] = []
        for name in names.sorted() {
            if name == ".com.apple.mobile_container_manager.metadata.plist" { continue }
            let rel = relativeParent.isEmpty ? name : relativeParent + "/" + name
            var isDir: ObjCBool = false
            fm.fileExists(atPath: dirURL.appendingPathComponent(name).path, isDirectory: &isDir)
            nodes.append(RuleNode(id: rel, name: name, isDirectory: isDir.boolValue, depth: depth))
        }
        // 文件夹在前
        nodes.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return nodes
    }
}
