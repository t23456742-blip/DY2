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
    @Published var isBusy = false
    @Published var busyText = "处理中…"
    @Published var showConfirmDelete = false
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
            log("已找到抖音容器：\(url.path)")
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
                self.apply(result)
                self.isBusy = false
                if let err = result.error {
                    self.log("扫描失败：\(err)")
                } else {
                    self.log("扫描完成：共 \(result.total) 个 · 可保留 \(result.keepHits) 个 · 多余 \(result.extras.count) 个")
                }
            }
        }
    }

    func deleteExtras() {
        guard !isBusy, !extras.isEmpty else { return }
        isBusy = true
        busyText = "删除中…"
        let targets = extras
        log("开始删除 \(targets.count) 个多余文件…")

        Task.detached(priority: .userInitiated) { [cleaner] in
            let summary = cleaner.delete(urls: targets)
            await MainActor.run {
                self.isBusy = false
                let freed = Self.formatBytes(summary.freedBytes)
                self.log("删除完成：成功 \(summary.deleted) 个 · 失败 \(summary.failed) 个 · 释放 \(freed)")
                self.scan()
            }
        }
    }

    private func apply(_ result: SlimCleaner.ScanResult) {
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
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        // Force Chinese-friendly output regardless of system language
        sizeFormatter.formattingContext = .standalone
        let raw = sizeFormatter.string(fromByteCount: bytes)
        return raw
            .replacingOccurrences(of: "bytes", with: "字节")
            .replacingOccurrences(of: "byte", with: "字节")
            .replacingOccurrences(of: "Bytes", with: "字节")
            .replacingOccurrences(of: "Byte", with: "字节")
            .replacingOccurrences(of: " KB", with: " KB")
            .replacingOccurrences(of: " MB", with: " MB")
            .replacingOccurrences(of: " GB", with: " GB")
    }

    private func log(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logLines.append("[\(stamp)] \(line)")
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
    }
}
