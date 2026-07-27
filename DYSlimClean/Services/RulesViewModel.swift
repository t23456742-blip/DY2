import Foundation
import Combine

struct RuleNode: Identifiable, Hashable {
    let id: String
    let name: String
    let isDirectory: Bool
    let depth: Int
    var hint: String?
    var sizeBytes: Int64 = 0

    var sizeText: String {
        sizeBytes > 0 ? ContainerDiskSize.format(sizeBytes) : "—"
    }
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
        // 顶层（对齐雷神/雷蛇备份包：Documents / Library / tmp）
        "Documents": "账号库、mmkv、安装票据、特效等业务数据",
        "Library": "登录态、IM、商城资源、缓存、偏好设置（体积通常最大）",
        "tmp": "临时文件；精简时通常可删",
        // Documents 关键
        "Documents/_ttinstall_document": "安装票据 · 强制保留，迁移/登录依赖",
        "Documents/_bdticketguard_document": "票据防护 · 默认保留",
        "Documents/mmkv": "键值配置（登录/商城/首页等）· 商城相关强制保留",
        "Documents/Aweme.db": "抖音主库 · 账号与业务核心",
        "Documents/tt_net_config.config": "网络/设备参数（did/iid/机型）· 查询提参用",
        "Documents/ttaccountSDKUserInfo.archiver": "账号归档 · 登录态",
        "Documents/ttaccount_token_guard_data.archiver": "Token 防护归档",
        "Documents/com.bytedance.ies": "IES 配置 · 默认保留",
        "Documents/com.bytedance.ies-effects": "特效资源 · 体积大，可精简",
        "Documents/com.bytedance.ies-effects-cache": "特效缓存 · 可删",
        "Documents/AWEIMRoot": "私信资源（表情/用户）· 体积大",
        "Documents/FeedbackRecorder": "反馈录音 · 默认可留",
        "Documents/IESPlayTimePredictModel": "播放预测模型 · 小，可留",
        "Documents/IESMLModelsPackage": "机器学习模型包 · 可精简",
        "Documents/homepage": "首页缓存 · 可删",
        "Documents/edge": "边缘计算缓存 · 可删",
        "Documents/applog.tttracker": "埋点日志 · 可删",
        "Documents/bd.turing": "图灵活体/风控模型 · 可精简",
        "Documents/AWEDanmakuResourceRootFolder": "弹幕资源 · 可删",
        "Documents/TIMXSDKWorkplace": "TIM 即时通讯工作区",
        "Documents/IMFTS": "私信全文检索索引",
        "Documents/hostcache_sync_v1": "域名/主机缓存",
        "Documents/server.json": "服务端配置缓存",
        "Documents/DBWorkspace": "DB 工作区",
        // Library 关键（备份包里最大头多在这里）
        "Library/Preferences": "偏好设置 · 移机/粘贴相关，默认保留",
        "Library/Caches": "通用缓存；商城 aweecom / WebKit 子树强制保留",
        "Library/Application Support": "商城 gurd/gecko/电商资源 · 体积最大头，关键子树强制保留",
        "Library/Application Support/gurd_cache": "Gurd 动态资源 · 商城依赖，强制保留",
        "Library/Pitaya": "商城/搜索包 · 强制保留",
        "Library/WebKit": "商城 H5 / 搜索 WebView · 强制保留",
        "Library/AWEIMRoot": "私信贴纸与用户资源",
        "Library/AWEStorage": "UnifyStorage 登录与业务库 · 体积大，默认保留",
        "Library/HTTPStorages": "HTTP 存储/Cookie · 默认保留",
        "Library/SyncedPreferences": "同步偏好 · 默认保留",
        "Library/passportStorage": "通行证/登录凭证存储",
        "Library/alog": "本地日志 · 可删",
        "Library/Heimdallr": "监控/崩溃采集 · 可删",
        "Library/tma": "小程序/容器缓存 · 可精简",
        "Library/Jato": "Jato 组件缓存 · 可精简",
        "Library/SplashBoard": "启动图缓存 · 可删",
        "Library/AWEOfflineCenter": "离线中心缓存 · 可删",
        "Library/AWEFeedCacheData": "信息流缓存 · 可删",
        "Library/AWEResource": "通用资源包 · 可精简",
        "Library/AWEFileKit": "文件工具缓存 · 可精简",
        "Library/PIAMMKV": "PIA MMKV · 可精简",
        "Library/unisus": "unisus 缓存 · 可精简",
        "Library/Cookies": "Cookie 存储",
        "Library/loginData.dat": "登录数据文件 · 默认保留",
        "Library/Better": "Better 组件数据",
        "tmp/AWEIMRoot": "临时私信资源 · 可删"
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
            let childURL = dirURL.appendingPathComponent(name)
            fm.fileExists(atPath: childURL.path, isDirectory: &isDir)
            let size = isDir.boolValue
                ? ContainerDiskSize.byteSize(of: childURL, budget: depth <= 1 ? 40_000 : 12_000)
                : ((try? fm.attributesOfItem(atPath: childURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
            nodes.append(RuleNode(
                id: rel,
                name: name,
                isDirectory: isDir.boolValue,
                depth: depth,
                hint: hints[rel] ?? hints[name],
                sizeBytes: size
            ))
        }
        nodes.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            if a.sizeBytes != b.sizeBytes { return a.sizeBytes > b.sizeBytes }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return nodes
    }
}
