import Foundation
import Combine

struct RuleNode: Identifiable, Hashable {
    let id: String
    let name: String
    let isDirectory: Bool
    let depth: Int
    var hint: String?
}

@MainActor
final class RulesViewModel: ObservableObject {
    @Published var nodes: [RuleNode] = []
    @Published var checked: Set<String> = []
    @Published var expanded: Set<String> = ["Documents", "Library"]
    @Published var statusText = ""
    @Published var isBusy = false
    @Published var toast = ""
    @Published var profiles: [RuleProfile] = []
    @Published var activeId: String = "builtin.default.slim"
    @Published var editMode: RuleMode = .defaultSlim
    @Published var showSaveAs = false
    @Published var saveAsName = ""
    @Published var saveAsFavorite = true

    private let cleaner = SlimCleaner()
    private var childrenCache: [String: [RuleNode]] = [:]

    private static let folderHints: [String: String] = [
        "Documents": "用户文档/数据库/mmkv 等",
        "Library": "缓存、偏好设置、资源",
        "tmp": "临时文件，精简时通常可删",
        "Documents/mmkv": "关键配置存储，商城相关强制保留",
        "Documents/_ttinstall_document": "安装票据，强制保留不可取消",
        "Documents/_bdticketguard_document": "票据防护，默认保留",
        "Library/Preferences": "偏好设置，移机/粘贴相关，默认保留",
        "Library/Caches": "缓存目录；商城 aweecom / WebKit 子树强制保留",
        "Library/Application Support": "商城 gurd/gecko/电商资源，强制保留",
        "Library/Pitaya": "商城/搜索包，强制保留",
        "Library/WebKit": "商城 H5/搜索 WebView，强制保留",
        "Library/AWEIMRoot": "私信/表情等资源"
    ]

    func bootstrap() {
        reloadProfiles()
        applyProfileToEditor(RulesStore.shared.activeProfile)
        refreshTree()
    }

    func reloadProfiles() {
        profiles = RulesStore.shared.profiles
        activeId = RulesStore.shared.activeProfileId
    }

    func selectProfile(_ id: String) {
        RulesStore.shared.selectProfile(id: id)
        reloadProfiles()
        applyProfileToEditor(RulesStore.shared.activeProfile)
        toast = "已切换规则：\(RulesStore.shared.activeProfile.name)"
    }

    private func applyProfileToEditor(_ p: RuleProfile) {
        editMode = p.mode
        switch p.mode {
        case .defaultSlim:
            checked = cleaner.defaultCheckedPathsFull()
        case .defaultPlus:
            checked = cleaner.defaultCheckedPathsFull().union(p.paths)
        case .fullCustom:
            checked = Set(p.paths)
        }
        checked.insert("Documents/_ttinstall_document")
        statusText = statusLine()
    }

    private func statusLine() -> String {
        let name = RulesStore.shared.activeProfile.name
        switch editMode {
        case .defaultSlim:
            return "当前选用「\(name)」· 默认精简 · 勾选=保留 不勾选=删除"
        case .defaultPlus:
            return "当前选用「\(name)」· 默认精简+额外保留 · 勾选=保留"
        case .fullCustom:
            return "当前选用「\(name)」· 完全自定义 · 勾选=保留 不勾选=删除"
        }
    }

    func refreshTree() {
        isBusy = true
        statusText = "正在读取抖音全部目录…"
        let hints = Self.folderHints
        Task.detached(priority: .userInitiated) { [cleaner] in
            guard let container = cleaner.locateAwemeContainer() else {
                await MainActor.run {
                    self.nodes = []
                    self.isBusy = false
                    self.statusText = "未找到抖音容器，请确认已安装抖音且本软件为巨魔安装"
                }
                return
            }
            let top = Self.listChildren(of: "", under: container, depth: 0, hints: hints)
            await MainActor.run {
                self.childrenCache = ["": top]
                // 预加载 Documents / Library 一层，方便看到「所有目录」
                for pre in ["Documents", "Library", "tmp"] {
                    if top.contains(where: { $0.id == pre }) {
                        self.childrenCache[pre] = Self.listChildren(
                            of: pre,
                            under: container,
                            depth: 1,
                            hints: hints
                        )
                        self.expanded.insert(pre)
                    }
                }
                self.rebuildVisible()
                self.isBusy = false
                self.statusText = self.statusLine() + " · 已列出 \(self.nodes.count) 项（可展开）"
            }
        }
    }

    func toggleExpand(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            if childrenCache[path] == nil, let container = cleaner.locateAwemeContainer() {
                let depth = path.split(separator: "/").count
                childrenCache[path] = Self.listChildren(of: path, under: container, depth: depth, hints: Self.folderHints)
            }
        }
        rebuildVisible()
    }

    func toggleCheck(_ path: String) {
        if isForced(path) {
            checked.insert("Documents/_ttinstall_document")
            toast = "_ttinstall_document 强制保留，不能取消"
            return
        }
        // 在默认精简模式下改勾 → 自动变为 defaultPlus（在默认上增删展示）
        if editMode == .defaultSlim {
            editMode = .defaultPlus
            toast = "已切换为「默认精简+额外」编辑，保存后永久生效"
        }
        if checked.contains(path) {
            checked.remove(path)
            // 取消文件夹时，不强制清子项勾选（子项可能单独勾）
        } else {
            checked.insert(path)
        }
    }

    func isForced(_ path: String) -> Bool {
        if path == "Documents/_ttinstall_document" || path.hasPrefix("Documents/_ttinstall_document/") {
            return true
        }
        // 商城/搜索关键目录不允许取消
        return SlimCleaner.isMallSearchProtected(path)
    }

    func isEffectivelyChecked(_ path: String) -> Bool {
        if isForced(path) { return true }
        if checked.contains(path) { return true }
        var parts = path.split(separator: "/").map(String.init)
        while parts.count > 1 {
            parts.removeLast()
            if checked.contains(parts.joined(separator: "/")) { return true }
        }
        // 默认精简/增强：未勾但默认规则会保留的，显示为勾选态
        if editMode == .defaultSlim || editMode == .defaultPlus {
            if cleaner.defaultShouldKeep(relativePath: path) { return true }
        }
        return false
    }

    /// 保存到当前选用规则（永久）
    func saveCurrent() {
        checked.insert("Documents/_ttinstall_document")
        let mode: RuleMode
        let paths: Set<String>
        switch editMode {
        case .defaultSlim:
            RulesStore.shared.restoreDefaultSlim()
            reloadProfiles()
            applyProfileToEditor(RulesStore.shared.activeProfile)
            toast = "已使用默认精简（永久）"
            return
        case .defaultPlus:
            mode = .defaultPlus
            // 只存「超出默认」的额外项
            let base = cleaner.defaultCheckedPathsFull()
            paths = checked.subtracting(base)
        case .fullCustom:
            mode = .fullCustom
            paths = checked
        }
        RulesStore.shared.saveActive(mode: mode, paths: paths)
        reloadProfiles()
        toast = "规则已永久保存（\(RulesStore.shared.activeProfile.name)）"
        statusText = statusLine()
    }

    func beginSaveAs(favorite: Bool) {
        saveAsFavorite = favorite
        saveAsName = favorite ? "收藏规则 \(stamp())" : "我的规则 \(stamp())"
        showSaveAs = true
    }

    func confirmSaveAs() {
        let name = saveAsName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        checked.insert("Documents/_ttinstall_document")
        let mode = (editMode == .defaultSlim) ? RuleMode.defaultPlus : editMode
        let paths: Set<String> = {
            if mode == .defaultPlus {
                return checked.subtracting(cleaner.defaultCheckedPathsFull())
            }
            return checked
        }()
        RulesStore.shared.saveAsNew(name: name, mode: mode, paths: paths, favorite: saveAsFavorite)
        reloadProfiles()
        applyProfileToEditor(RulesStore.shared.activeProfile)
        showSaveAs = false
        toast = saveAsFavorite ? "已收藏并永久保存" : "已另存为永久规则"
    }

    func toggleFavoriteActive() {
        RulesStore.shared.toggleFavorite(id: activeId)
        reloadProfiles()
        toast = RulesStore.shared.activeProfile.isFavorite ? "已收藏" : "已取消收藏"
    }

    func useDefaultSlim() {
        RulesStore.shared.restoreDefaultSlim()
        reloadProfiles()
        applyProfileToEditor(RulesStore.shared.activeProfile)
        toast = "已切换为默认精简"
    }

    func switchToFullCustomEditing() {
        editMode = .fullCustom
        // 以当前有效勾选为起点
        var all = checked
        // 把默认会保留的也标上，方便用户从精简改起
        all.formUnion(cleaner.defaultCheckedPathsFull())
        checked = all
        checked.insert("Documents/_ttinstall_document")
        toast = "完全自定义：只保留打钩项，其余删除"
        statusText = statusLine()
    }

    func switchToDefaultPlusEditing() {
        editMode = .defaultPlus
        checked = cleaner.defaultCheckedPathsFull().union(checked)
        checked.insert("Documents/_ttinstall_document")
        toast = "在默认精简上追加保留：多勾的会额外留下"
        statusText = statusLine()
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMdd-HHmm"
        return f.string(from: Date())
    }

    private func rebuildVisible() {
        var result: [RuleNode] = []
        func walk(_ parent: String) {
            for n in childrenCache[parent] ?? [] {
                result.append(n)
                if n.isDirectory, expanded.contains(n.id) {
                    if childrenCache[n.id] == nil, let container = cleaner.locateAwemeContainer() {
                        childrenCache[n.id] = Self.listChildren(
                            of: n.id,
                            under: container,
                            depth: n.depth + 1,
                            hints: Self.folderHints
                        )
                    }
                    walk(n.id)
                }
            }
        }
        walk("")
        nodes = result
    }

    nonisolated private static func listChildren(
        of relativeParent: String,
        under container: URL,
        depth: Int,
        hints: [String: String]
    ) -> [RuleNode] {
        let fm = FileManager.default
        let dirURL = relativeParent.isEmpty ? container : container.appendingPathComponent(relativeParent)
        guard let names = try? fm.contentsOfDirectory(atPath: dirURL.path) else { return [] }
        var nodes: [RuleNode] = []
        for name in names.sorted() {
            if name == ".com.apple.mobile_container_manager.metadata.plist" { continue }
            let rel = relativeParent.isEmpty ? name : relativeParent + "/" + name
            var isDir: ObjCBool = false
            fm.fileExists(atPath: dirURL.appendingPathComponent(name).path, isDirectory: &isDir)
            nodes.append(RuleNode(
                id: rel,
                name: name,
                isDirectory: isDir.boolValue,
                depth: depth,
                hint: hints[rel] ?? hints[name]
            ))
        }
        nodes.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return nodes
    }
}
