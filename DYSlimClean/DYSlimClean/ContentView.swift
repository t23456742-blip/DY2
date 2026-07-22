import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = CleanViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                statusCard
                statsRow
                actionButtons
                if !model.logLines.isEmpty {
                    logBox
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("抖音精简清理")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .alert("确认删除", isPresented: $model.showConfirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除多余文件", role: .destructive) {
                model.deleteExtras()
            }
        } message: {
            Text("将删除 \(model.extraCount) 个不在白名单中的文件（约 \(model.extraSizeText)）。是否掉登录取决于白名单是否保留相关数据，建议先备份。")
        }
        .onAppear { model.bootstrap() }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.containerFound ? "已定位抖音容器" : "未找到抖音容器", systemImage: model.containerFound ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(model.containerFound ? .green : .orange)
            Text(model.containerPath.isEmpty ? "应用标识：抖音 · 多巴胺 RootHide 越狱" : "路径：\(model.containerPath)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(3)
            Text("白名单：\(model.keepCount) 条 · 须用巨魔安装本软件")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            stat("总文件", "\(model.totalCount)")
            stat("可保留", "\(model.keepHitCount)")
            stat("多余", "\(model.extraCount)")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3).bold()
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                model.scan()
            } label: {
                HStack {
                    if model.isBusy { ProgressView().tint(.white) }
                    Text(model.isBusy ? model.busyText : "扫描抖音沙盒")
                        .bold()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(model.isBusy)

            Button {
                model.showConfirmDelete = true
            } label: {
                Text("一键删除多余文件")
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(model.extraCount > 0 && !model.isBusy ? Color.red : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(model.extraCount == 0 || model.isBusy)
        }
    }

    private var logBox: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: 220)
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }
}

#Preview {
    ContentView()
}
