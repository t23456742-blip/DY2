import Foundation
import Combine
import SwiftUI
import UIKit

@MainActor
final class MigrateViewModel: ObservableObject {
    enum Panel: String, Identifiable {
        case result, diagnosis
        var id: String { rawValue }
    }

    @Published var isBusy = false
    @Published var sourceOK = false
    @Published var sourcePath = ""
    @Published var installedIDs: Set<String> = []
    @Published var panel: Panel?
    @Published var results: [InstallDocMigrator.Outcome] = []
    @Published var summary = ""
    @Published var headerText = ""

    @Published var diagnosisText = ""

    var targets: [TargetApp] { AppContainerLocator.allTargets }

    var installedCount: Int { installedIDs.count }

    func isInstalled(_ app: TargetApp) -> Bool { installedIDs.contains(app.id) }

    /// 刷新：检测抖音票据目录 + 各目标 App 是否已安装（一次索引，共用）
    func refresh() {
        Task.detached(priority: .userInitiated) {
            let index = AppContainerLocator.containerIndex()
            let src = InstallDocMigrator.locateSource()
            var installed = Set<String>()
            for app in AppContainerLocator.allTargets where AppContainerLocator.isInstalled(app, index: index) {
                installed.insert(app.id)
            }
            let path = src?.path ?? ""
            let hasSource = (src != nil)
            await MainActor.run {
                self.sourceOK = hasSource
                self.sourcePath = path
                self.installedIDs = installed
            }
        }
    }

    /// 诊断报告
    func runDiagnosis() {
        isBusy = true
        Task.detached(priority: .userInitiated) {
            let text = AppContainerLocator.diagnosisText()
            await MainActor.run {
                self.isBusy = false
                self.diagnosisText = text
                self.panel = .diagnosis
            }
        }
    }

    /// 单个迁移
    func migrate(to target: TargetApp) {
        guard !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) {
            let outcome = InstallDocMigrator.migrate(to: target)
            await MainActor.run {
                self.isBusy = false
                self.results = [outcome]
                self.summary = outcome.ok ? "成功" : "失败"
                self.headerText = target.title
                self.panel = .result
                if !outcome.ok { self.refresh() }
            }
        }
    }

    /// 一键迁移：任务内部现检测一次，避免界面状态未刷新导致“未检测到已安装”
    func migrateAll() {
        guard !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) {
            let index = AppContainerLocator.containerIndex()
            var installed = Set<String>()
            for app in AppContainerLocator.allTargets where AppContainerLocator.isInstalled(app, index: index) {
                installed.insert(app.id)
            }

            let outcomes = InstallDocMigrator.migrateInstalled()
            let needDiagnosis = outcomes.isEmpty
            let diag = needDiagnosis ? AppContainerLocator.diagnosisText() : ""
            let okCount = outcomes.filter { $0.ok }.count
            let total = outcomes.count

            await MainActor.run {
                self.isBusy = false
                self.installedIDs = installed
                self.results = outcomes
                self.headerText = "一键迁移"
                if needDiagnosis {
                    self.summary = "未检测到已安装的目标 App"
                } else if okCount == total {
                    self.summary = "全部成功（\(okCount)/\(total)）"
                } else if okCount == 0 {
                    self.summary = "全部失败（0/\(total)）"
                } else {
                    self.summary = "部分成功（\(okCount)/\(total)）"
                }
                if needDiagnosis {
                    self.diagnosisText = diag
                    self.panel = .diagnosis
                } else {
                    self.panel = .result
                }
            }
        }
    }
}

/// 结果弹窗
struct ResultSheet: View {
    let title: String
    let summary: String
    let results: [InstallDocMigrator.Outcome]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(summary)
                        .font(.headline)
                        .padding(.top, 4)

                    ForEach(results) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(item.ok ? Color(red: 0.15, green: 0.78, blue: 0.55) : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline.weight(.semibold))
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    Text("迁移完成后请先划掉（杀死）目标 App 再重新打开，票据才会生效。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 6)
                }
                .padding(16)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// 诊断弹窗（可复制）
struct DiagnosisSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .textSelection(.enabled)
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("复制") { UIPasteboard.general.string = text }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
