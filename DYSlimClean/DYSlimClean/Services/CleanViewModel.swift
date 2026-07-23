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
    @Published var showMigrateResult = false
    @Published var migrateResultText = ""
    @Published var showInstallMigrateResult = false
    @Published var installMigrateText = ""
    @Published var floatEnabled = false
    @Published var offerCleanAfterScan = false
    @Published var logLines: [String] = []

    private let cleaner = SlimCleaner()
    private var extras: [URL] = []
    private var extraBytes: Int64 = 0

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

    func requestSlimFromFloat() {
        if extraCount > 0 {
            showConfirmDelete = true
        } else {
            offerCleanAfterScan = true
            scan()
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

    func deleteExtras() {
        guard !isBusy, !extras.isEmpty else { return }
        isBusy = true
        busyText = "删除中…"
        let snapshotBefore = beforeBytes
        let targets = extras
        log("开始删除 \(targets.count) 个多余文件…")

        Task.detached(priority: .userInitiated) { [cleaner] in
            let summary = cleaner.delete(urls: targets)
            let afterResult = cleaner.scan()
            await MainActor.run {
                self.hasCleaned = true
                self.applyScan(afterResult, isPostClean: true, forcedBefore: snapshotBefore, freed: summary.freedBytes)
                self.isBusy = false
                let freed = Self.formatBytes(summary.freedBytes)
                self.log("删除完成：成功 \(summary.deleted) 个 · 失败 \(summary.failed) 个 · 释放 \(freed)")
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
