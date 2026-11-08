import Foundation
import Combine
import SwiftUI

@MainActor
final class MigrateViewModel: ObservableObject {
    @Published var isBusy = false
    @Published var sourceOK = false
    @Published var sourcePath = ""
    @Published var installedIDs: Set<String> = []
    @Published var showResult = false
    @Published var results: [InstallDocMigrator.Outcome] = []
    @Published var summary = ""
    @Published var headerText = ""

    var targets: [TargetApp] { AppContainerLocator.allTargets }

    var installedCount: Int { installedIDs.count }

    func isInstalled(_ app: TargetApp) -> Bool { installedIDs.contains(app.id) }

    /// 刷新：检测抖音票据目录 + 各目标 App 是否已安装
    func refresh() {
        Task.detached(priority: .userInitiated) {
            let src = InstallDocMigrator.locateSource()
            var installed = Set<String>()
            for app in AppContainerLocator.allTargets where AppContainerLocator.isInstalled(app) {
                installed.insert(app.id)
            }
            let path = src?.path ?? ""
            await MainActor.run {
                self.sourceOK = (src != nil)
                self.sourcePath = path
                self.installedIDs = installed
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
                self.showResult = true
            }
        }
    }

    /// 一键迁移：只处理已安装 App
    func migrateAll() {
        guard !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) {
            let outcomes = InstallDocMigrator.migrateInstalled()
            let okCount = outcomes.filter { $0.ok }.count
            let total = outcomes.count
            await MainActor.run {
                self.isBusy = false
                self.results = outcomes
                self.headerText = "一键迁移 · 已安装 \(total) 个"
                self.summary = total == 0 ? "未检测到已安装的目标 App"
                    : (okCount == total ? "全部成功（\(okCount)/\(total)）"
                       : (okCount == 0 ? "全部失败（0/\(total)）" : "部分成功（\(okCount)/\(total)）"))
                self.showResult = true
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
                        .foregroundColor(.primary)
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
