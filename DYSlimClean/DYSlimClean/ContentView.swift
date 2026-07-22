import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = CleanViewModel()

    private let accent = Color(red: 0.15, green: 0.85, blue: 0.78)
    private let danger = Color(red: 1.0, green: 0.35, blue: 0.40)
    private let card = Color(red: 0.11, green: 0.14, blue: 0.20)
    private let bgTop = Color(red: 0.05, green: 0.07, blue: 0.12)
    private let bgBottom = Color(red: 0.08, green: 0.10, blue: 0.16)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    header
                    statusCard
                    sizeCompareCard
                    statsRow
                    actionButtons
                    if !model.logLines.isEmpty {
                        logBox
                    }
                    Spacer(minLength: 56)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }

            wechatBadge
                .padding(.trailing, 14)
                .padding(.bottom, 14)
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .alert("确认删除", isPresented: $model.showConfirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除多余文件", role: .destructive) {
                model.deleteExtras()
            }
        } message: {
            Text("将删除 \(model.extraCount) 个多余文件（约 \(model.extraSizeText)）。建议先备份；是否掉登录取决于白名单。")
        }
        .onAppear { model.bootstrap() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.05, green: 0.25, blue: 0.35), Color(red: 0.08, green: 0.12, blue: 0.28)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                VStack(spacing: 0) {
                    Text("DY").font(.system(size: 16, weight: .black)).foregroundColor(.white)
                    Text("瘦身").font(.system(size: 10, weight: .bold)).foregroundColor(accent)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("DY瘦身")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("抖音沙盒精简 · 巨魔 / 多巴胺 RootHide")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: model.containerFound ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(model.containerFound ? accent : .orange)
                Text(model.containerFound ? "已定位抖音容器" : "未找到抖音容器")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("白名单 \(model.keepCount)")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.18))
                    .foregroundColor(accent)
                    .clipShape(Capsule())
            }
            Text(model.containerPath.isEmpty ? "应用：抖音 Aweme · 须巨魔安装本软件" : model.containerPath)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.45))
                .lineLimit(2)
        }
        .padding(14)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var sizeCompareCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("体积对比")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white.opacity(0.9))

            HStack(spacing: 10) {
                sizeBlock(title: "优化前", value: model.beforeSizeText, color: .orange)
                Image(systemName: "arrow.right")
                    .foregroundColor(.white.opacity(0.35))
                sizeBlock(title: model.hasCleaned ? "优化后" : "优化后(预估)", value: model.afterSizeText, color: accent)
            }

            HStack {
                Text(model.hasCleaned ? "已释放" : "可释放")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Text(model.savedSizeText)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(danger)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.16, blue: 0.24), card],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(0.25), lineWidth: 1)
        )
    }

    private func sizeBlock(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(color)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            stat("总文件", "\(model.totalCount)", .white)
            stat("可保留", "\(model.keepHitCount)", accent)
            stat("多余", "\(model.extraCount)", danger)
        }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(title)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                model.scan()
            } label: {
                HStack(spacing: 8) {
                    if model.isBusy && model.busyText.contains("扫描") {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(model.isBusy ? model.busyText : "扫描抖音沙盒")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(colors: [accent, Color(red: 0.2, green: 0.65, blue: 1.0)], startPoint: .leading, endPoint: .trailing)
                )
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(model.isBusy)

            Button {
                model.showConfirmDelete = true
            } label: {
                HStack(spacing: 8) {
                    if model.isBusy && model.busyText.contains("删除") {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "trash.fill")
                    }
                    Text("一键删除多余文件")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(model.extraCount > 0 && !model.isBusy ? danger : Color.gray.opacity(0.45))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(model.extraCount == 0 || model.isBusy)
        }
    }

    private var logBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("运行日志")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.55))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(12)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var wechatBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "message.fill")
                .font(.caption2)
            Text("微信 pw68699")
                .font(.caption2.weight(.semibold))
        }
        .foregroundColor(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

#Preview {
    ContentView()
}
