import SwiftUI

struct ContentView: View {
    @StateObject private var model = MigrateViewModel()

    private let accent = Color(red: 0.15, green: 0.85, blue: 0.78)
    private let card = Color(red: 0.11, green: 0.14, blue: 0.20)
    private let tile = Color(red: 0.16, green: 0.22, blue: 0.32)
    private let bgTop = Color(red: 0.05, green: 0.07, blue: 0.12)
    private let bgBottom = Color(red: 0.08, green: 0.10, blue: 0.16)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    header
                    sourceCard
                    oneClickButton
                    targetGrid
                    hintCard
                    Spacer(minLength: 48)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }

            Text("微信 pw68699")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(14)
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .onAppear { model.refresh() }
        .sheet(isPresented: $model.showResult) {
            ResultSheet(title: model.headerText, summary: model.summary, results: model.results)
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("票据迁移")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                Text("v2.0")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accent.opacity(0.16))
                    .clipShape(Capsule())
            }
            Text("抖音票据 → 红果 / 番茄 / 头条 等 · 巨魔专用")
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 源状态

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: model.sourceOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(model.sourceOK ? accent : .orange)
                Text(model.sourceOK ? "抖音票据目录可用" : "未检测到抖音票据目录")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Spacer()
                Button("刷新") { model.refresh() }
                    .font(.caption.weight(.bold))
                    .foregroundColor(accent)
            }
            if model.sourceOK, !model.sourcePath.isEmpty {
                Text(model.sourcePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text("请先在抖音登录并打开一次，让 App 生成 _ttinstall_document 目录。")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.45))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 一键迁移

    private var oneClickButton: some View {
        Button {
            model.migrateAll()
        } label: {
            HStack(spacing: 8) {
                if model.isBusy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.right.doc.on.clipboard")
                }
                Text(model.isBusy ? "迁移中…" : "一键迁移（已安装 \(model.installedCount) 个）")
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.2, green: 0.78, blue: 0.52), Color(red: 0.13, green: 0.55, blue: 0.92)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .disabled(model.isBusy || !model.sourceOK)
        .opacity(model.sourceOK ? 1 : 0.45)
    }

    // MARK: - 目标列表

    private var targetGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("单独迁移")
                .font(.caption)
                .foregroundColor(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(model.targets) { app in
                    targetTile(app)
                }
            }
        }
    }

    private func targetTile(_ app: TargetApp) -> some View {
        let installed = model.isInstalled(app)
        return Button {
            model.migrate(to: app)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(installed ? accent : Color.white.opacity(0.18))
                        .frame(width: 6, height: 6)
                    if let badge = app.badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(accent)
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                Text(app.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(installed ? "已安装 · 点击迁移" : "未安装")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(installed ? 0.5 : 0.28))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(installed ? tile : Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(installed ? Color.white.opacity(0.06) : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(model.isBusy || !installed)
    }

    // MARK: - 提示

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("使用步骤")
                .font(.caption.weight(.bold))
                .foregroundColor(.white.opacity(0.75))
            Text("① 抖音登录好 → ② 打开红果短剧等目标 App 一次（让容器生成） → ③ 回来点一键迁移 → ④ 杀掉目标 App 再打开")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview {
    ContentView()
}
