import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var model: CleanViewModel

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
                    migrateCard
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
        .alert("直接清理", isPresented: $model.showConfirmDelete) {
            Button("取消", role: .cancel) {}
            Button("直接清理", role: .destructive) {
                model.deleteExtras()
            }
        } message: {
            Text("将删除 \(model.extraCount) 个多余文件（约 \(model.extraSizeText)），不备份。")
        }
        .alert("清理前备份", isPresented: $model.showConfirmBackupDelete) {
            Button("取消", role: .cancel) {}
            Button("备份并清理", role: .destructive) {
                model.deleteExtrasWithBackup()
            }
        } message: {
            Text("先把整个抖音沙盒打包到 /private/var/mobile/Media/dybf（7z/zip），再清理多余文件。")
        }
        .alert("提示", isPresented: $model.showCleanResult) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.cleanResultText)
        }
        .alert("移机粘贴修复", isPresented: $model.showMigrateResult) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.migrateResultText)
        }
        .alert("提示", isPresented: $model.showInstallMigrateResult) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.installMigrateText)
        }
        .onAppear {
            model.floatEnabled = FloatingBallController.shared.isVisible
        }
        .onReceive(NotificationCenter.default.publisher(for: FloatingAction.didScan)) { _ in
            model.scan(fromFloat: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: FloatingAction.didSlim)) { _ in
            model.requestSlimFromFloat()
        }
        .onReceive(NotificationCenter.default.publisher(for: FloatingAction.didOneTap)) { _ in
            model.runOneTapReset(fromFloat: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: FloatingAction.visibilityChanged)) { note in
            if let on = note.object as? Bool {
                model.floatEnabled = on
            }
        }
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
                    Text("助手").font(.system(size: 10, weight: .bold)).foregroundColor(accent)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("DY助手")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "8.0")")
                        .font(.caption.weight(.bold))
                        .foregroundColor(accent)
                }
                Text("精简 · 票据迁移 · 巨魔 / 多巴胺")
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
                Text("规则已加固·商城优先")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.18))
                    .foregroundColor(accent)
                    .clipShape(Capsule())
            }
            Text(model.containerPath.isEmpty ? "优先保证抖音商城+搜索 · _ttinstall 不删 · 其余按精简包" : model.containerPath)
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

    private var migrateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("一键迁移")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white.opacity(0.9))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(AppContainerLocator.migrateTargets) { app in
                    Button {
                        model.migrateInstallDoc(to: app)
                    } label: {
                        Text("迁移到\(app.title)")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(red: 0.16, green: 0.22, blue: 0.32))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(model.isBusy)
                }
            }

            Button {
                model.migrateInstallDocAll()
            } label: {
                HStack {
                    Image(systemName: "arrow.right.doc.on.clipboard")
                    Text("一键迁移到全部目标")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.2, green: 0.75, blue: 0.55), Color(red: 0.15, green: 0.55, blue: 0.9)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(model.isBusy)
        }
        .padding(14)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(0.2), lineWidth: 1)
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
                model.showConfirmBackupDelete = true
            } label: {
                HStack(spacing: 8) {
                    if model.isBusy && (model.busyText.contains("备份") || model.busyText.contains("清理")) {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "externaldrive.badge.timemachine")
                    }
                    Text("清理前备份")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(model.extraCount > 0 && !model.isBusy
                             ? LinearGradient(colors: [Color.orange, Color(red: 1.0, green: 0.55, blue: 0.2)], startPoint: .leading, endPoint: .trailing)
                             : LinearGradient(colors: [Color.gray.opacity(0.45), Color.gray.opacity(0.45)], startPoint: .leading, endPoint: .trailing))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(model.extraCount == 0 || model.isBusy)

            Button {
                model.showConfirmDelete = true
            } label: {
                HStack(spacing: 8) {
                    if model.isBusy && model.busyText.contains("清理") && !model.busyText.contains("备份") {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "trash.fill")
                    }
                    Text("直接清理")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(model.extraCount > 0 && !model.isBusy ? danger : Color.gray.opacity(0.45))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(model.extraCount == 0 || model.isBusy)

            Button {
                FloatingBallController.shared.toggle()
                model.floatEnabled = FloatingBallController.shared.isVisible
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.floatEnabled ? "dot.circle.and.hand.point.up.left.fill" : "circle.dashed")
                    Text(model.floatEnabled ? "关闭全局悬浮" : "打开全局悬浮")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: model.floatEnabled
                            ? [Color.orange, Color(red: 1.0, green: 0.55, blue: 0.2)]
                            : [Color(red: 0.35, green: 0.45, blue: 0.95), Color(red: 0.2, green: 0.7, blue: 0.9)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(model.isBusy)

            Button {
                model.runMigratePasteFix()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                    Text("移机修复·复制粘贴")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.55, green: 0.35, blue: 0.95), Color(red: 0.3, green: 0.5, blue: 1.0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(model.isBusy)
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
    ContentView(model: CleanViewModel())
}
