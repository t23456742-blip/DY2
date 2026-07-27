import Foundation
import Combine

@MainActor
final class CleanViewModel: ObservableObject {
    @Published var containerFound = false
    @Published var containerPath = ""
    @Published var containerSizeText = "—"
    @Published var keepCount = 0
    @Published var totalCount = 0
    @Published var keepHitCount = 0
    @Published var extraCount = 0
    @Published var extraSizeText = "0 字节"
    @Published var beforeSizeText = "—"
    @Published var afterSizeText = "—"
    @Published var savedSizeText = "—"
    @Published var beforeBytes: Int64 = 0
    @Published var afterBytes: Int64 = 0
    @Published var hasScanned = false
    @Published var hasCleaned = false
    @Published var isBusy = false
    @Published var busyText = "处理中…"
    @Published var showConfirmDelete = false
    @Published var showConfirmBackupDelete = false
    @Published var showCleanResult = false
    @Published var cleanResultText = ""
    @Published var showMigrateResult = false
    @Published var migrateResultText = ""
    @Published var showInstallMigrateResult = false
    @Published var installMigrateText = ""
    @Published var offerCleanAfterScan = false
    @Published var logLines: [String] = []

    /// 一键搞定（容器→钥匙串→标识符→广告符）
    @Published var oneTapSucceeded = false
    @Published var oneTapStepTexts: [String] = [
        "1. 刷新容器",
        "2. 清钥匙串",
        "3. 刷新标识符",
        "4. 刷新广告符"
    ]
    @Published var showOneTapResult = false
    @Published var oneTapResultText = ""
    @Published var showCachePackResult = false
    @Published var cachePackResultText = ""
    @Published var showConfirmSeedCache = false
    @Published var showProbeResult = false
    @Published var probeResultText = ""
    @Published var showCookieExportResult = false
    @Published var cookieExportResultText = ""
    @Published var showAccountQueryResult = false
    @Published var accountQueryText = ""
    @Published var accountQueryRows: [(String, String)] = []
    /// 本机查询来源（仅 Application 容器）
    @Published var accountQuerySource = ""
    /// 雷神备份查询结果（与本机查询分开显示）
    @Published var thorQueryRows: [(String, String)] = []
    @Published var thorQuerySource = ""
    @Published var thorQueryText = ""
    @Published var showParamExtractResult = false
    @Published var paramExtractText = ""
    @Published var thorBackups: [ThorBackupIndex.Entry] = []
    @Published var showThorExtractResult = false
    @Published var thorExtractText = ""
    /// 雷蛇 RAZER 备份
    @Published var razerBackups: [RazerBackupIndex.Entry] = []
    @Published var razerInstalled = false
    @Published var razerQueryRows: [(String, String)] = []
    @Published var razerQuerySource = ""
    @Published var razerQueryText = ""
    @Published var showRazerExtractResult = false
    @Published var razerExtractText = ""
    @Published var shellPath: String = UserDefaults.standard.string(forKey: "dyshell.path")
        ?? "/var/mobile/Media/dyclean.sh"
    @Published var showShellResult = false
    @Published var shellResultText = ""

    private let cleaner = SlimCleaner()
    private var extras: [URL] = []
    private var extraBytes: Int64 = 0
    /// 最近一次扫描的相对路径，随机新增缓存时参考目录
    private var lastScanRels: [String] = []

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useBytes]
        f.countStyle = .file
        f.includesUnit = true
        f.isAdaptive = true
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func bootstrap() {
        keepCount = cleaner.keepList.count
        log("已加载白名单 \(keepCount) 条")
        refreshLocatedContainer()
        reloadThorBackups()
        reloadRazerBackups()
    }

    func reloadThorBackups() {
        let list = ThorBackupIndex.load()
        thorBackups = list
        if list.isEmpty {
            log("雷神备份：未安装")
        } else {
            let src = list.first?.indexSource ?? ""
            log("雷神备份：\(list.count) 条 · 索引 \(src)")
        }
    }

    func reloadRazerBackups() {
        razerInstalled = RazerBackupIndex.isInstalled()
        let list = RazerBackupIndex.load()
        razerBackups = list
        if !razerInstalled {
            log("雷蛇备份：未安装（无 /private/var/mobile/Media/RAZER）")
        } else if list.isEmpty {
            log("雷蛇备份：已安装，暂无含 Aweme 的备份包")
        } else {
            log("雷蛇备份：\(list.count) 包 · /private/var/mobile/Media/RAZER")
        }
    }

    /// 对雷神备份包提参（不是在线查询）
    func extractFromThorBackup(_ entry: ThorBackupIndex.Entry) {
        guard !isBusy else { return }
        isBusy = true
        busyText = "备份提参…"
        let pack = entry.displayPath
        log("雷神备份提参：\(entry.name)\n\(pack)/com.ss.iphone.ugc.Aweme")
        Task.detached(priority: .userInitiated) { [cleaner] in
            guard let root = ThorBackupIndex.findAwemeDataRoot(inBackup: pack) else {
                await MainActor.run {
                    self.isBusy = false
                    self.thorExtractText = "备份包内未找到 com.ss.iphone.ugc.Aweme\n备注：\(entry.name)\n\(pack)"
                    self.showThorExtractResult = true
                    self.log(self.thorExtractText)
                }
                return
            }
            let r = DouyinParamExtractor.extractAndSave(cleaner: cleaner, container: root)
            await MainActor.run {
                self.isBusy = false
                self.thorExtractText = "备注：\(entry.name)\n来源：\(root.path)\n\(r.message)"
                self.showThorExtractResult = true
                self.paramExtractText = self.thorExtractText
                self.showParamExtractResult = true
                self.log(self.thorExtractText)
            }
        }
    }

    /// 雷神备份查询：结果详情在卡片上方，状态/在线写回列表行
    func queryFromThorBackup(_ entry: ThorBackupIndex.Entry) {
        guard !isBusy else { return }
        isBusy = true
        busyText = "备份查询…"
        let pack = entry.displayPath
        let entryID = entry.id
        log("【雷神备份查询】\(entry.accountPasswordText)")
        Task.detached(priority: .userInitiated) { [cleaner] in
            guard let root = ThorBackupIndex.findAwemeDataRoot(inBackup: pack) else {
                await MainActor.run {
                    self.isBusy = false
                    self.thorQuerySource = ""
                    self.thorQueryRows = [
                        ("账号", entry.account),
                        ("密码", entry.password.isEmpty ? "—" : entry.password),
                        ("状态", "无数据"),
                        ("是否在线", "—")
                    ]
                    self.patchThorRow(id: entryID, status: "无数据", online: "—")
                    self.log("备份包内未找到 Aweme：\(entry.name)")
                }
                return
            }
            let snap = DouyinAccountQuery.query(cleaner: cleaner, container: root)
            await MainActor.run {
                self.isBusy = false
                self.thorQuerySource = ""
                self.thorQueryRows = Self.displayQueryRows(from: snap, account: entry.account, password: entry.password)
                self.thorQueryText = snap.message
                self.patchThorRow(id: entryID, status: snap.status, online: snap.online)
                self.log(snap.message)
            }
        }
    }

    private func patchThorRow(id: String, status: String, online: String) {
        guard let i = thorBackups.firstIndex(where: { $0.id == id }) else { return }
        thorBackups[i].queryStatus = status
        thorBackups[i].queryOnline = online
    }

    /// 雷蛇备份包提参：`{RAZER}/{stamp}/com.ss.iphone.ugc.Aweme`
    func extractFromRazerBackup(_ entry: RazerBackupIndex.Entry) {
        guard !isBusy else { return }
        isBusy = true
        busyText = "雷蛇提参…"
        let pack = entry.displayPath
        log("雷蛇备份提参：\(entry.name)\n\(pack)/com.ss.iphone.ugc.Aweme")
        Task.detached(priority: .userInitiated) { [cleaner] in
            guard let root = ThorBackupIndex.findAwemeDataRoot(inBackup: pack) else {
                await MainActor.run {
                    self.isBusy = false
                    self.razerExtractText = "备份包内未找到 com.ss.iphone.ugc.Aweme\n包名：\(entry.name)\n\(pack)"
                    self.showRazerExtractResult = true
                    self.log(self.razerExtractText)
                }
                return
            }
            let r = DouyinParamExtractor.extractAndSave(cleaner: cleaner, container: root)
            await MainActor.run {
                self.isBusy = false
                self.razerExtractText = "包名：\(entry.name)\n来源：\(root.path)\n\(r.message)"
                self.showRazerExtractResult = true
                self.paramExtractText = self.razerExtractText
                self.showParamExtractResult = true
                self.log(self.razerExtractText)
            }
        }
    }

    /// 雷蛇备份查询：详情在卡片上方，状态/在线/抖音号写回列表
    func queryFromRazerBackup(_ entry: RazerBackupIndex.Entry) {
        guard !isBusy else { return }
        isBusy = true
        busyText = "雷蛇查询…"
        let pack = entry.displayPath
        let entryID = entry.id
        log("【雷蛇备份查询】\(entry.name)")
        Task.detached(priority: .userInitiated) { [cleaner] in
            guard let root = ThorBackupIndex.findAwemeDataRoot(inBackup: pack) else {
                await MainActor.run {
                    self.isBusy = false
                    self.razerQuerySource = ""
                    self.razerQueryRows = [
                        ("备份包", entry.name),
                        ("状态", "无数据"),
                        ("是否在线", "—")
                    ]
                    self.patchRazerRow(id: entryID, status: "无数据", online: "—", account: "")
                    self.log("雷蛇包内未找到 Aweme：\(entry.name)")
                }
                return
            }
            let snap = DouyinAccountQuery.query(cleaner: cleaner, container: root)
            await MainActor.run {
                self.isBusy = false
                self.razerQuerySource = ""
                var rows = Self.displayQueryRows(from: snap)
                rows.insert(("备份包", entry.name), at: 0)
                self.razerQueryRows = rows
                self.razerQueryText = snap.message
                let acct = (snap.douyinID == "—" || snap.douyinID.isEmpty) ? "" : snap.douyinID
                self.patchRazerRow(id: entryID, status: snap.status, online: snap.online, account: acct)
                self.log(snap.message)
            }
        }
    }

    private func patchRazerRow(id: String, status: String, online: String, account: String) {
        guard let i = razerBackups.firstIndex(where: { $0.id == id }) else { return }
        razerBackups[i].queryStatus = status
        razerBackups[i].queryOnline = online
        if !account.isEmpty {
            razerBackups[i].queryAccount = account
        }
    }

    /// 备份包精简：按当前瘦身规则删除 Aweme 容器内多余文件（原地瘦身）
    func slimThorBackup(_ entry: ThorBackupIndex.Entry) {
        slimBackupPack(displayName: "雷神·\(entry.accountPasswordText)", packPath: entry.displayPath)
    }

    func slimRazerBackup(_ entry: RazerBackupIndex.Entry) {
        slimBackupPack(displayName: "雷蛇·\(entry.listTitle)", packPath: entry.displayPath)
    }

    private func slimBackupPack(displayName: String, packPath: String) {
        guard !isBusy else { return }
        isBusy = true
        busyText = "备份精简…"
        log("【备份精简】\(displayName)\n\(packPath)")
        Task.detached(priority: .userInitiated) { [cleaner] in
            guard let root = ThorBackupIndex.findAwemeDataRoot(inBackup: packPath) else {
                await MainActor.run {
                    self.isBusy = false
                    self.cleanResultText = "失败"
                    self.cachePackResultText = "备份包内未找到 com.ss.iphone.ugc.Aweme\n\(packPath)"
                    self.showCachePackResult = true
                    self.log(self.cachePackResultText)
                }
                return
            }
            let scan = cleaner.scan(container: root)
            if let err = scan.error {
                await MainActor.run {
                    self.isBusy = false
                    self.cachePackResultText = "扫描失败：\(err)"
                    self.showCachePackResult = true
                    self.log(self.cachePackResultText)
                }
                return
            }
            let before = scan.totalBytes
            let summary = cleaner.delete(urls: scan.extras, relativeTo: root)
            let msg = """
            \(displayName) 精简完成
            路径：\(root.path)
            删除 \(summary.deleted) 个文件（失败 \(summary.failed)）
            释放约 \(ContainerDiskSize.format(summary.freedBytes))
            扫描前 \(ContainerDiskSize.format(before)) · 保留 \(scan.keepHits) / 共 \(scan.total)
            """
            await MainActor.run {
                self.isBusy = false
                self.cachePackResultText = msg
                self.showCachePackResult = true
                self.log(msg)
            }
        }
    }

    /// 详情只保留业务字段，去掉路径/来源
    private static func displayQueryRows(
        from snap: DouyinAccountQuery.Snapshot,
        account: String? = nil,
        password: String? = nil
    ) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let account, !account.isEmpty { rows.append(("账号", account)) }
        if let password, !password.isEmpty { rows.append(("密码", password)) }
        let skip: Set<String> = ["来源", "容器", "备份目录", "路径", "备注"]
        for (k, v) in snap.rows where !skip.contains(k) {
            rows.append((k, v))
        }
        return rows
    }

    /// 刷新已定位容器路径 + 数据体积（仅本机 Application）
    func refreshLocatedContainer() {
        if let url = cleaner.locateAwemeContainer(), Self.isLiveApplicationPath(url.path) {
            containerFound = true
            containerPath = url.path
            log("已找到本机抖音容器：\(url.path)")
            Task.detached(priority: .utility) {
                let bytes = ContainerDiskSize.byteSize(of: url)
                let text = ContainerDiskSize.format(bytes)
                await MainActor.run {
                    if self.containerPath == url.path {
                        self.containerSizeText = text
                        self.log("抖音数据大小：\(text)")
                    }
                }
            }
        } else {
            containerFound = false
            containerPath = ""
            containerSizeText = "—"
            let diag = cleaner.locateAwemeDiagnostics()
            log("未找到本机 Application 抖音容器")
            log(diag)
        }
    }

    private func refreshLocatedContainerSizeOnly(at path: String) {
        let url = URL(fileURLWithPath: path)
        Task.detached(priority: .utility) {
            let bytes = ContainerDiskSize.byteSize(of: url)
            let text = ContainerDiskSize.format(bytes)
            await MainActor.run {
                if self.containerPath == path {
                    self.containerSizeText = text
                }
            }
        }
    }

    func scan() {
        guard !isBusy else { return }
        isBusy = true
        busyText = "扫描中…"
        log("开始扫描…")

        Task.detached(priority: .userInitiated) { [cleaner] in
            let result = cleaner.scan()
            await MainActor.run {
                self.applyScan(result, isPostClean: false)
                self.isBusy = false
                if let err = result.error {
                    self.log("扫描失败：\(err)")
                    self.offerCleanAfterScan = false
                } else {
                    self.log("扫描完成：共 \(result.total) 个 · 可保留 \(result.keepHits) 个 · 多余 \(result.extras.count) 个")
                    self.log("优化前占用：\(Self.formatBytes(result.totalBytes)) · 可释放：\(Self.formatBytes(result.extraBytes))")
                    if self.offerCleanAfterScan {
                        self.offerCleanAfterScan = false
                        if result.extras.isEmpty {
                            self.log("没有可删除的多余文件")
                        } else {
                            self.showConfirmDelete = true
                        }
                    }
                }
            }
        }
    }

    func runMigratePasteFix() {
        guard !isBusy else { return }
        isBusy = true
        busyText = "移机修复中…"
        log("开始移机粘贴修复…")
        Task.detached(priority: .userInitiated) { [cleaner] in
            let result = MigratePasteFix.run(cleaner: cleaner)
            await MainActor.run {
                self.isBusy = false
                self.migrateResultText = result.message
                self.showMigrateResult = true
                self.log(result.ok ? "移机修复已执行" : "移机修复部分失败，请看说明")
            }
        }
    }

    func migrateInstallDoc(to target: TargetApp) {
        guard !isBusy else { return }
        isBusy = true
        busyText = "迁移中…"
        Task.detached(priority: .userInitiated) {
            let result = InstallDocMigrator.migrate(to: target)
            await MainActor.run {
                self.isBusy = false
                self.installMigrateText = result.message
                self.showInstallMigrateResult = true
                self.log(result.message)
            }
        }
    }

    func migrateInstallDocAll() {
        guard !isBusy else { return }
        isBusy = true
        busyText = "一键迁移中…"
        Task.detached(priority: .userInitiated) {
            let result = InstallDocMigrator.migrateAll()
            await MainActor.run {
                self.isBusy = false
                self.installMigrateText = result.message
                self.showInstallMigrateResult = true
                self.log(result.message)
            }
        }
    }

    /// 工具箱同款：应用详情单项 / 一键四项
    func runIdentityAction(
        _ action: DouyinOneTapReset.Action?,
        app: TargetApp,
        allFour: Bool
    ) {
        guard !isBusy else { return }
        isBusy = true
        oneTapSucceeded = false
        let title = allFour ? "一键四项" : (action?.rawValue ?? "操作")
        busyText = "\(app.title)·\(title)…"
        log("开始 \(app.title) · \(title)")

        let bundleIDs = app.bundleIDs
        let displayName = app.title
        Task.detached(priority: .userInitiated) { [cleaner] in
            let result: DouyinOneTapReset.Result
            if allFour {
                result = DouyinOneTapReset.runAll(bundleIDs: bundleIDs, displayName: displayName, cleaner: cleaner)
            } else if let action {
                result = DouyinOneTapReset.runAction(action, bundleIDs: bundleIDs, displayName: displayName, cleaner: cleaner)
            } else {
                result = DouyinOneTapReset.run(cleaner: cleaner)
            }
            await MainActor.run {
                self.isBusy = false
                self.oneTapStepTexts = result.steps.enumerated().map { idx, s in
                    let mark = s.ok ? "✓" : "✗"
                    return "\(idx + 1). \(mark) \(s.name) · \(s.detail)"
                }
                self.oneTapSucceeded = result.ok
                self.oneTapResultText = result.message
                self.showOneTapResult = true
                if let path = result.newContainerPath,
                   app.bundleIDs.contains(where: { $0.caseInsensitiveCompare(SlimCleaner.awemeBundleID) == .orderedSame }) {
                    self.containerFound = true
                    self.containerPath = path
                    self.refreshLocatedContainerSizeOnly(at: path)
                }
                self.log(result.ok ? "\(displayName)·\(title) 成功" : "\(displayName)·\(title) 失败/部分失败")
                for s in result.steps {
                    self.log("\(s.ok ? "✓" : "✗") \(s.name)：\(s.detail)")
                }
            }
        }
    }

    /// 抖音一键四项
    func runOneTapReset() {
        runIdentityAction(nil, app: AppContainerLocator.douyin, allFour: true)
    }

    /// 直接清理（不备份）
    func deleteExtras() {
        deleteExtras(backupFirst: false)
    }

    /// 清理前先整包备份抖音沙盒到 Media/dybf，再删除多余文件
    func deleteExtrasWithBackup() {
        deleteExtras(backupFirst: true)
    }

    private func deleteExtras(backupFirst: Bool) {
        guard !isBusy, !extras.isEmpty else { return }
        isBusy = true
        busyText = backupFirst ? "整包备份中…" : "清理中…"
        let snapshotBefore = beforeBytes
        let targets = extras
        log(backupFirst ? "开始整包备份抖音 → /private/var/mobile/Media/dybf，再清理 \(targets.count) 个多余文件…" : "开始直接清理 \(targets.count) 个多余文件…")

        Task.detached(priority: .userInitiated) { [cleaner] in
            if backupFirst {
                guard let container = cleaner.locateAwemeContainer() else {
                    await MainActor.run {
                        self.isBusy = false
                        self.cleanResultText = "失败"
                        self.showCleanResult = true
                        self.log("备份失败：未找到抖音容器")
                    }
                    return
                }
                let backup = cleaner.backupFullContainer(container)
                if !backup.ok {
                    await MainActor.run {
                        self.isBusy = false
                        self.cleanResultText = "失败"
                        self.showCleanResult = true
                        self.log("备份失败：\(backup.error ?? "未知") · 已中止清理")
                    }
                    return
                }
                await MainActor.run {
                    self.log("备份完成：\(backup.copied) 个文件 → \(backup.backupRoot)")
                    self.busyText = "清理中…"
                }
            }

            let summary = cleaner.delete(urls: targets)
            let afterResult = cleaner.scan()
            await MainActor.run {
                self.hasCleaned = true
                self.applyScan(afterResult, isPostClean: true, forcedBefore: snapshotBefore, freed: summary.freedBytes)
                self.isBusy = false
                self.cleanResultText = "成功"
                self.showCleanResult = true
                let freed = Self.formatBytes(summary.freedBytes)
                self.log("清理完成：成功 \(summary.deleted) 个 · 失败 \(summary.failed) 个 · 释放 \(freed)")
                if let err = afterResult.error {
                    self.log("复扫提示：\(err)")
                } else {
                    self.log("优化后占用：\(Self.formatBytes(afterResult.totalBytes))")
                }
            }
        }
    }

    private func applyScan(_ result: SlimCleaner.ScanResult, isPostClean: Bool, forcedBefore: Int64? = nil, freed: Int64 = 0) {
        if let url = result.container {
            containerFound = true
            containerPath = url.path
        }
        totalCount = result.total
        keepHitCount = result.keepHits
        extras = result.extras
        lastScanRels = result.relativePaths
        extraCount = result.extras.count
        extraBytes = result.extraBytes
        extraSizeText = Self.formatBytes(extraBytes)
        hasScanned = result.error == nil

        if isPostClean {
            let before = forcedBefore ?? beforeBytes
            beforeBytes = before
            afterBytes = result.totalBytes
            beforeSizeText = Self.formatBytes(before)
            afterSizeText = Self.formatBytes(afterBytes)
            let saved = max(0, before - afterBytes)
            savedSizeText = Self.formatBytes(saved > 0 ? saved : freed)
        } else if result.error == nil {
            beforeBytes = result.totalBytes
            beforeSizeText = Self.formatBytes(result.totalBytes)
            // 预估优化后 = 可保留体积
            afterBytes = result.keepBytes
            afterSizeText = Self.formatBytes(result.keepBytes) + "（预估）"
            savedSizeText = Self.formatBytes(result.extraBytes) + "（可释放）"
        }
    }

    /// 按扫描目录随机新增缓存（不写回 zip，不动账号关键文件）
    func seedRandomCache() {
        guard !isBusy else { return }
        isBusy = true
        busyText = "随机新增缓存…"
        log("开始随机新增缓存…")
        let hints = lastScanRels
        Task.detached(priority: .userInitiated) { [cleaner] in
            guard let container = cleaner.locateAwemeContainer() else {
                await MainActor.run {
                    self.isBusy = false
                    self.cachePackResultText = "未找到抖音容器"
                    self.showCachePackResult = true
                    self.log("随机缓存失败：未找到抖音容器")
                }
                return
            }
            let r = DouyinRandomCacheSeeder.seedRandomCache(into: container, hintRels: hints)
            await MainActor.run {
                self.isBusy = false
                self.cachePackResultText = r.message
                self.showCachePackResult = true
                self.log(r.message)
                if r.ok {
                    self.containerFound = true
                    self.containerPath = container.path
                }
            }
        }
    }

    /// 按白名单把「可保留」文件打成精简缓存包（可选备份）
    func exportSlimCache() {
        guard !isBusy else { return }
        isBusy = true
        busyText = "导出精简缓存…"
        log("开始导出精简缓存包…")
        Task.detached(priority: .userInitiated) { [cleaner] in
            guard let container = cleaner.locateAwemeContainer() else {
                await MainActor.run {
                    self.isBusy = false
                    self.cachePackResultText = "未找到抖音容器"
                    self.showCachePackResult = true
                    self.log("导出失败：未找到抖音容器")
                }
                return
            }
            let r = DouyinSlimCachePack.exportKeepCache(container: container, cleaner: cleaner)
            await MainActor.run {
                self.isBusy = false
                self.cachePackResultText = r.message
                self.showCachePackResult = true
                self.log(r.message)
                if r.ok {
                    self.containerFound = true
                    self.containerPath = container.path
                }
            }
        }
    }

    /// 把最近一份精简缓存包注入当前抖音容器
    func importSlimCache() {
        guard !isBusy else { return }
        isBusy = true
        busyText = "注入精简缓存…"
        log("开始注入精简缓存…")
        Task.detached(priority: .userInitiated) { [cleaner] in
            guard let container = cleaner.locateAwemeContainer() else {
                await MainActor.run {
                    self.isBusy = false
                    self.cachePackResultText = "未找到抖音容器"
                    self.showCachePackResult = true
                    self.log("注入失败：未找到抖音容器")
                }
                return
            }
            let r = DouyinSlimCachePack.importKeepCache(into: container)
            await MainActor.run {
                self.isBusy = false
                self.cachePackResultText = r.message
                self.showCachePackResult = true
                self.log(r.message)
            }
        }
    }

    /// 自定义 SH 路径执行（posix_spawn → /bin/sh 脚本）
    func runCustomShell() {
        guard !isBusy else { return }
        let path = shellPath.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(path, forKey: "dyshell.path")
        isBusy = true
        busyText = "执行 SH…"
        log("执行 SH：\(path)")
        Task.detached(priority: .userInitiated) {
            let r = ShellScriptRunner.execute(path: path)
            await MainActor.run {
                self.isBusy = false
                self.shellResultText = r.message
                self.showShellResult = true
                self.log(r.ok ? "SH 成功 exit=\(r.exitCode)" : "SH 失败 exit=\(r.exitCode)")
            }
        }
    }

    /// 不打开抖音：读沙盒账号 + 商城本地资源 + 本机网络
    func probeAccountAndMall() {
        guard !isBusy else { return }
        isBusy = true
        busyText = "检测账号/商城…"
        log("开始检测账号与商城（不启动抖音）…")
        Task.detached(priority: .userInitiated) { [cleaner] in
            let r = DouyinAccountProbe.inspect(cleaner: cleaner)
            await MainActor.run {
                self.isBusy = false
                self.probeResultText = r.message
                self.showProbeResult = true
                self.log(r.message)
                if r.hasAccount {
                    self.containerFound = true
                }
            }
        }
    }

    /// 本机查询：只扫 `/var/mobile/Containers/Data/Application` 下抖音容器（不走雷神备份）
    func queryDouyinAccountV3() {
        guard !isBusy else { return }
        isBusy = true
        busyText = "本机查询…"
        let live = Self.liveApplicationContainer(cleaner: cleaner, cachedPath: containerPath)
        if let live {
            containerFound = true
            containerPath = live.path
        }
        log("【本机查询】/var/mobile/Containers/Data/Application …\n\(live?.path ?? "未定位")")
        Task.detached(priority: .userInitiated) { [cleaner] in
            let located = cleaner.locateAwemeContainer()
            let fallback: URL? = {
                guard let u = located, Self.isLiveApplicationPath(u.path) else { return nil }
                return u
            }()
            let container = live ?? fallback
            let snap = DouyinAccountQuery.query(cleaner: cleaner, container: container)
            await MainActor.run {
                self.isBusy = false
                self.accountQuerySource = ""
                self.accountQueryRows = Self.displayQueryRows(from: snap)
                self.accountQueryText = snap.message
                self.showAccountQueryResult = true
                if let p = container?.path {
                    self.containerPath = p
                    self.containerFound = true
                }
                if container == nil {
                    self.log(cleaner.locateAwemeDiagnostics())
                }
                self.log(snap.message)
                self.log(snap.ok ? "本机查询完成" : "本机查询完成（信息不完整）")
            }
        }
    }

    /// 缓存路径若是雷神备份则丢弃，只认 Application 容器
    nonisolated private static func liveApplicationContainer(cleaner: SlimCleaner, cachedPath: String) -> URL? {
        if !cachedPath.isEmpty, isLiveApplicationPath(cachedPath),
           FileManager.default.fileExists(atPath: cachedPath) {
            return URL(fileURLWithPath: cachedPath)
        }
        if let url = cleaner.locateAwemeContainer(), isLiveApplicationPath(url.path) {
            return url
        }
        return nil
    }

    nonisolated private static func isLiveApplicationPath(_ path: String) -> Bool {
        let p = path.lowercased()
        if p.contains("/containers/data/application/") { return true }
        if p.contains("/thor/backups/") || p.contains("/media/thor/") { return false }
        if p.contains("/media/razer/") { return false }
        return false
    }

    /// 提参：先用已定位容器提取 16 参 → `/private/var/mobile/Media/{抖音号}.txt`
    func extractAwemeParams() {
        guard !isBusy else { return }
        isBusy = true
        busyText = "提参中…"
        let preferred = Self.liveApplicationContainer(cleaner: cleaner, cachedPath: containerPath)
        log("开始本机提参 → Media/{抖音号}.txt …\n\(preferred?.path ?? "自动定位")")
        Task.detached(priority: .userInitiated) { [cleaner] in
            let r = DouyinParamExtractor.extractAndSave(cleaner: cleaner, container: preferred)
            await MainActor.run {
                self.isBusy = false
                self.paramExtractText = r.message
                self.showParamExtractResult = true
                if r.ok { self.containerFound = true }
                self.log(r.message)
            }
        }
    }

    /// 提取抖音 Cookies，导出给 PC Chrome Cookie-Editor 导入（网页端）
    func exportCookiesForPC() {
        guard !isBusy else { return }
        isBusy = true
        busyText = "导出 CK…"
        log("开始全量导出 Cookies（Safari系统浏览器 + 抖音沙盒，不过滤）…")
        Task.detached(priority: .userInitiated) { [cleaner] in
            let r = DouyinCookieExport.export(cleaner: cleaner)
            await MainActor.run {
                self.isBusy = false
                self.cookieExportResultText = r.message
                self.showCookieExportResult = true
                self.log(r.message)
            }
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        sizeFormatter.formattingContext = .standalone
        let raw = sizeFormatter.string(fromByteCount: bytes)
        return raw
            .replacingOccurrences(of: "bytes", with: "字节")
            .replacingOccurrences(of: "byte", with: "字节")
            .replacingOccurrences(of: "Bytes", with: "字节")
            .replacingOccurrences(of: "Byte", with: "字节")
    }

    private func log(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logLines.append("[\(stamp)] \(line)")
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
    }
}

/// 非 MainActor：供 Task.detached 统计容器体积
enum ContainerDiskSize {
    static func byteSize(of root: URL, budget: Int = 200_000) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        var left = budget
        for case let file as URL in en {
            left -= 1
            if left <= 0 { break }
            guard let vals = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  vals.isRegularFile == true,
                  let sz = vals.fileSize else { continue }
            total += Int64(sz)
        }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useBytes]
        f.countStyle = .file
        f.includesUnit = true
        f.isAdaptive = true
        f.formattingContext = .standalone
        return f.string(fromByteCount: bytes)
            .replacingOccurrences(of: "bytes", with: "字节")
            .replacingOccurrences(of: "byte", with: "字节")
            .replacingOccurrences(of: "Bytes", with: "字节")
            .replacingOccurrences(of: "Byte", with: "字节")
    }
}
