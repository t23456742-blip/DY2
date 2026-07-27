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
                    accountQueryCard
                    thorBackupCard
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
        .alert("随机新增缓存", isPresented: $model.showConfirmSeedCache) {
            Button("取消", role: .cancel) {}
            Button("开始生成") { model.seedRandomCache() }
        } message: {
            Text("按扫描到的缓存目录，随机写入一批新缓存文件（不改 mmkv/Aweme.db/AWEStorage 等账号文件）。建议先扫描再点。")
        }
        .alert("精简缓存", isPresented: $model.showCachePackResult) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.cachePackResultText)
        }
        .alert("执行 SH", isPresented: $model.showShellResult) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.shellResultText)
        }
        .alert("账号 / 商城检测", isPresented: $model.showProbeResult) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.probeResultText)
        }
        .alert("导出 CK（PC网页）", isPresented: $model.showCookieExportResult) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.cookieExportResultText)
        }
        .alert("抖音查询", isPresented: $model.showAccountQueryResult) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.accountQueryText)
        }
        .alert("提参", isPresented: $model.showParamExtractResult) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.paramExtractText)
        }
        .alert("雷神备份提参", isPresented: $model.showThorExtractResult) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(model.thorExtractText)
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
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "14.1")")
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
                if model.containerFound {
                    Text(model.containerSizeText)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.18))
                        .foregroundColor(accent)
                        .clipShape(Capsule())
                } else {
                    Text("规则已加固·商城优先")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.18))
                        .foregroundColor(accent)
                        .clipShape(Capsule())
                }
            }
            if model.containerFound {
                HStack(spacing: 6) {
                    Text("数据大小")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.white.opacity(0.45))
                    Text(model.containerSizeText)
                        .font(.caption.weight(.bold))
                        .foregroundColor(.white.opacity(0.92))
                }
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

    private var accountQueryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本机抖音查询")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Text("Application 容器")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.18))
                    .foregroundColor(accent)
                    .clipShape(Capsule())
            }
            Text("只查本机：/var/mobile/Containers/Data/Application/<UUID>\n（与下方雷神备份无关）")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.45))

            if !model.accountQuerySource.isEmpty {
                Text(model.accountQuerySource)
                    .font(.caption2.monospaced())
                    .foregroundColor(accent.opacity(0.9))
                    .lineLimit(4)
            }

            if !model.accountQueryRows.isEmpty {
                queryRowsView(model.accountQueryRows)
            }

            HStack(spacing: 10) {
                Button {
                    model.queryDouyinAccountV3()
                } label: {
                    HStack(spacing: 8) {
                        if model.isBusy && model.busyText.contains("本机查询") {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "magnifyingglass.circle.fill")
                        }
                        Text(model.isBusy && model.busyText.contains("本机查询") ? model.busyText : "查询当前抖音号")
                            .fontWeight(.bold)
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.35, green: 0.55, blue: 1.0), Color(red: 0.2, green: 0.75, blue: 0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(model.isBusy)

                Button {
                    model.extractAwemeParams()
                } label: {
                    HStack(spacing: 8) {
                        if model.isBusy && model.busyText.contains("提参") && !model.busyText.contains("备份") {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "doc.text.fill")
                        }
                        Text(model.isBusy && model.busyText.contains("提参") && !model.busyText.contains("备份") ? model.busyText : "本机提参")
                            .fontWeight(.bold)
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.95, green: 0.45, blue: 0.35), Color(red: 0.85, green: 0.25, blue: 0.45)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(model.isBusy || !model.containerFound)
            }

            Text("本机提参 → /private/var/mobile/Media/{抖音号}.txt")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(14)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(0.22), lineWidth: 1)
        )
    }

    private func queryRowsView(_ rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                HStack(alignment: .top) {
                    Text(row.0)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.45))
                        .frame(width: 72, alignment: .leading)
                    Text(row.1)
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 7)
                if idx < rows.count - 1 {
                    Divider().background(Color.white.opacity(0.08))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var thorBackupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("雷神备份查询")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Text("Backups 包")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.22))
                    .foregroundColor(Color.orange)
                    .clipShape(Capsule())
                Button {
                    model.reloadThorBackups()
                } label: {
                    Text("刷新")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.18))
                        .foregroundColor(accent)
                        .clipShape(Capsule())
                }
                .disabled(model.isBusy)
            }
            Text("索引：/private/var/mobile/Media/Thor/Backups/backup_index.plist\n列表每项 → 对应备份文件夹/com.ss.iphone.ugc.Aweme（不查本机 Application）")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.45))

            if !model.thorQuerySource.isEmpty {
                Text(model.thorQuerySource)
                    .font(.caption2.monospaced())
                    .foregroundColor(Color.orange.opacity(0.95))
                    .lineLimit(4)
            }
            if !model.thorQueryRows.isEmpty {
                queryRowsView(model.thorQueryRows)
            }

            if model.thorBackups.isEmpty {
                Text("未找到雷神索引：/private/var/mobile/Media/Thor/Backups/backup_index.plist")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                Text("共 \(model.thorBackups.count) 个备份包")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Color.orange.opacity(0.95))

                VStack(spacing: 8) {
                    ForEach(model.thorBackups) { entry in
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name)
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                                if !entry.createdAt.isEmpty {
                                    Text(entry.createdAt)
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.45))
                                        .lineLimit(1)
                                }
                                Text(entry.displayPath)
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.white.opacity(0.35))
                                    .lineLimit(2)
                                Text(entry.sizeText)
                                    .font(.caption2)
                                    .foregroundColor(accent.opacity(0.85))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                model.queryFromThorBackup(entry)
                            } label: {
                                Text("查备份")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(Color(red: 0.35, green: 0.55, blue: 1.0))
                                    .foregroundColor(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .disabled(model.isBusy)

                            Button {
                                model.extractFromThorBackup(entry)
                            } label: {
                                Text("提参")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(Color(red: 0.95, green: 0.45, blue: 0.35))
                                    .foregroundColor(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .disabled(model.isBusy)
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
        .padding(14)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    private var migrateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("一键迁移")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white.opacity(0.9))
            Text("极速版 / 火山版 / 商城 / 抖省省 / 头条 / 多闪 / 番茄小说 / 随变 / 精选 / 汽水 / 西瓜 / AI抖音")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.45))

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

            HStack(spacing: 10) {
                Button {
                    model.exportSlimCache()
                } label: {
                    HStack(spacing: 6) {
                        if model.isBusy && model.busyText.contains("导出") {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.up.on.square")
                        }
                        Text("导出精简缓存").fontWeight(.bold).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.35, green: 0.55, blue: 1.0), Color(red: 0.2, green: 0.4, blue: 0.9)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(model.isBusy || !model.containerFound)

                Button {
                    model.showConfirmSeedCache = true
                } label: {
                    HStack(spacing: 6) {
                        if model.isBusy && model.busyText.contains("随机") {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "plus.square.on.square")
                        }
                        Text("随机新增缓存").fontWeight(.bold).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.55, green: 0.4, blue: 0.95), Color(red: 0.35, green: 0.25, blue: 0.75)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(model.isBusy || !model.containerFound)
            }

            Text("随机新增：在 Caches/VideoCache/tmp 等目录生成随机文件；不动账号关键数据。")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))

            VStack(alignment: .leading, spacing: 8) {
                Text("自定义 SH")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
                TextField("脚本绝对路径，如 /var/mobile/Media/dyclean.sh", text: $model.shellPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .padding(10)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundColor(.white)

                Button {
                    model.runCustomShell()
                } label: {
                    HStack(spacing: 8) {
                        if model.isBusy && model.busyText.contains("SH") {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "terminal.fill")
                        }
                        Text(model.isBusy && model.busyText.contains("SH") ? model.busyText : "执行 SH")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.2, green: 0.65, blue: 0.45), Color(red: 0.08, green: 0.45, blue: 0.38)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(model.isBusy || model.shellPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("用 /bin/sh 跑你填的脚本路径（工具箱清理本身是原生删路径，不是外置 .sh）。路径会记住。")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))

            Button {
                model.probeAccountAndMall()
            } label: {
                HStack(spacing: 8) {
                    if model.isBusy && model.busyText.contains("检测") {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                    }
                    Text(model.isBusy && model.busyText.contains("检测") ? model.busyText : "检测账号·商城·网络")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.85, blue: 0.35), Color(red: 0.95, green: 0.65, blue: 0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(model.isBusy)

            Text("不打开抖音：读沙盒 plist 账号 + gurd 商城资源 + DY助手自测网络/token。")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))

            Button {
                model.exportCookiesForPC()
            } label: {
                HStack(spacing: 8) {
                    if model.isBusy && model.busyText.contains("导出 CK") {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "globe")
                    }
                        Text("导出全量CK(Safari+抖音)")
                            .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.25, green: 0.55, blue: 0.95), Color(red: 0.15, green: 0.35, blue: 0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(model.isBusy || !model.containerFound)

            Text("先用手机 Safari 登录 creator.douyin.com，再导出。ZIP→Media/dyck/*_dyck.zip，PC注入器全量导入。")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))

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
