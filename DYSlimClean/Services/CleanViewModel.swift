import Foundation
import Combine

@MainActor
final class CleanViewModel: ObservableObject {
    @Published var containerFound = false
    @Published var containerPath = ""
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
    @Published var floatEnabled = false
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
    @Published var showConfirmSessionRestore = false
    @Published var showSessionResult = false
    @Published var sessionResultText = ""
    @Published var showProbeResult = false
    @Published var probeResultText = ""
    @Published var showCookieExportResult = false
    @Published var cookieExportResultText = ""

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
        if let url = cleaner.locateAwemeContainer() {
            containerFound = true
            containerPath = url.path
            log("已找到抖音容器")
        } else {
            containerFound = false
            containerPath = ""
            log("未找到抖音数据容器（请确认已安装抖音，且本软件已用巨魔安装）")
        }
    }

    func scan(fromFloat: Bool = false) {
        guard !isBusy else { return }
        isBusy = true
        busyText = "扫描中…"
        log("开始扫描…")
        if fromFloat {
            NotificationCenter.default.post(name: Notification.Name("dy.slim.float.status"), object: "后台扫描中…")
        }

        Task.detached(priority: .userInitiated) { [cleaner] in
            let result = cleaner.scan()
            await MainActor.run {
                self.applyScan(result, isPostClean: false)
                self.isBusy = false
                if let err = result.error {
                    self.log("扫描失败：\(err)")
                    self.offerCleanAfterScan = false
                    if fromFloat {
                        NotificationCenter.default.post(name: Notification.Name("dy.slim.float.status"), object: "扫描失败")
                    }
                } else {
                    self.log("扫描完成：共 \(result.total) 个 · 可保留 \(result.keepHits) 个 · 多余 \(result.extras.count) 个")
                    self.log("优化前占用：\(Self.formatBytes(result.totalBytes)) · 可释放：\(Self.formatBytes(result.extraBytes))")
                    if fromFloat {
                        NotificationCenter.default.post(
                            name: Notification.Name("dy.slim.float.status"),
                            object: result.extras.isEmpty ? "扫描完成·无多余" : "扫描完成"
                        )
                    }
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

    /// 悬浮球触发：后台清理，不弹确认、不抢前台
    func requestSlimFromFloat() {
        guard !isBusy else {
            NotificationCenter.default.post(name: Notification.Name("dy.slim.float.status"), object: "正在处理中")
            return
        }
        NotificationCenter.default.post(name: Notification.Name("dy.slim.float.status"), object: "后台清理中…")
        if extraCount > 0 {
            deleteExtrasSilentFromFloat()
        } else {
            // 先扫再删，全程后台
            offerCleanAfterScan = false
            isBusy = true
            busyText = "扫描中…"
            log("悬浮：后台扫描后清理…")
            Task.detached(priority: .userInitiated) { [cleaner] in
                let result = cleaner.scan()
                await MainActor.run {
                    self.applyScan(result, isPostClean: false)
                    if let err = result.error {
                        self.isBusy = false
                        self.log("悬浮扫描失败：\(err)")
                        NotificationCenter.default.post(name: Notification.Name("dy.slim.float.status"), object: "扫描失败")
                        return
                    }
                    if result.extras.isEmpty {
                        self.isBusy = false
                        self.log("悬浮：没有可删文件")
                        NotificationCenter.default.post(name: Notification.Name("dy.slim.float.status"), object: "无需清理")
                    } else {
                        self.deleteExtrasSilentFromFloat()
                    }
                }
            }
        }
    }

    private func deleteExtrasSilentFromFloat() {
        guard !extras.isEmpty else {
            NotificationCenter.default.post(name: Notification.Name("dy.slim.float.status"), object: "无需清理")
            return
        }
        isBusy = true
        busyText = "删除中…"
        let snapshotBefore = beforeBytes
        let targets = extras
        log("悬浮：后台删除 \(targets.count) 个多余文件…")
        Task.detached(priority: .userInitiated) { [cleaner] in
            let summary = cleaner.delete(urls: targets)
            let afterScan = cleaner.scan()
            await MainActor.run {
                self.applyScan(afterScan, isPostClean: true)
                self.hasCleaned = true
                if snapshotBefore > 0 {
                    self.beforeBytes = snapshotBefore
                    self.beforeSizeText = Self.formatBytes(snapshotBefore)
                }
                self.isBusy = false
                self.log("悬浮清理完成：删 \(summary.deleted) · 失败 \(summary.failed)")
                NotificationCenter.default.post(
                    name: Notification.Name("dy.slim.float.status"),
                    object: summary.failed == 0 ? "清理完成" : "清理部分失败"
                )
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
                self.log(result.ok ? "票据迁移成功 → \(target.title)" : "票据迁移失败 → \(target.title)")
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
                self.log(result.ok ? "一键票据迁移完成" : "一键票据迁移失败")
            }
        }
    }

    /// 工具箱同款：应用详情单项 / 一键四项
    func runIdentityAction(
        _ action: DouyinOneTapReset.Action?,
        app: TargetApp,
        allFour: Bool,
        fromFloat: Bool = false
    ) {
        guard !isBusy else {
            if fromFloat {
                NotificationCenter.default.post(name: Notification.Name("dy.slim.float.status"), object: "正在处理中")
            }
            return
        }
        isBusy = true
        oneTapSucceeded = false
        let title = allFour ? "一键四项" : (action?.rawValue ?? "操作")
        busyText = "\(app.title)·\(title)…"
        log("开始 \(app.title) · \(title)")
        if fromFloat {
            NotificationCenter.default.post(name: Notification.Name("dy.slim.float.status"), object: "\(title)中…")
        }

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
                if fromFloat {
                    self.oneTapResultText = result.ok ? "成功" : "失败"
                    self.showOneTapResult = false
                    NotificationCenter.default.post(
                        name: Notification.Name("dy.slim.float.status"),
                        object: result.ok ? "成功" : "失败"
                    )
                } else {
                    self.oneTapResultText = result.message
                    self.showOneTapResult = true
                }
                if let path = result.newContainerPath,
                   app.bundleIDs.contains(where: { $0.caseInsensitiveCompare(SlimCleaner.awemeBundleID) == .orderedSame }) {
                    self.containerFound = true
                    self.containerPath = path
                }
                self.log(result.ok ? "\(displayName)·\(title) 成功" : "\(displayName)·\(title) 失败/部分失败")
                for s in result.steps {
                    self.log("\(s.ok ? "✓" : "✗") \(s.name)：\(s.detail)")
                }
            }
        }
    }

    /// 抖音一键四项（悬浮球 / 兼容旧入口）
    func runOneTapReset(fromFloat: Bool = false) {
        runIdentityAction(nil, app: AppContainerLocator.douyin, allFour: true, fromFloat: fromFloat)
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

    /// 精简会话备份：改机参数 + Keychain + 抖音登录号料
    func backupSession() {
        guard !isBusy else { return }
        isBusy = true
        busyText = "备份会话…"
        log("开始精简会话备份（参数+钥匙串+号料）…")
        Task.detached(priority: .userInitiated) { [cleaner] in
            let r = DouyinSessionBackup.backup(cleaner: cleaner)
            await MainActor.run {
                self.isBusy = false
                self.sessionResultText = r.message
                self.showSessionResult = true
                self.log(r.message)
                if r.ok {
                    self.containerFound = true
                }
            }
        }
    }

    /// 还原最近一份会话包（先杀抖音再写入）
    func restoreSession() {
        guard !isBusy else { return }
        isBusy = true
        busyText = "还原会话…"
        log("开始还原精简会话…")
        Task.detached(priority: .userInitiated) { [cleaner] in
            let r = DouyinSessionBackup.restore(into: cleaner)
            await MainActor.run {
                self.isBusy = false
                self.sessionResultText = r.message
                self.showSessionResult = true
                self.log(r.message)
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

    /// 提取抖音 Cookies，导出给 PC Chrome Cookie-Editor 导入（网页端）
    func exportCookiesForPC() {
        guard !isBusy else { return }
        isBusy = true
        busyText = "导出 CK…"
        log("开始导出抖音 Cookies（PC 网页）…")
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
