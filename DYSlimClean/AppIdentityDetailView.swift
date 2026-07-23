import SwiftUI

/// 工具箱同款：应用详情 — 四项可单独点，也可一键四项
struct AppIdentityDetailView: View {
    let app: TargetApp
    @ObservedObject var cleanModel: CleanViewModel

    private let accent = Color(red: 0.15, green: 0.85, blue: 0.78)
    private let card = Color(red: 0.11, green: 0.14, blue: 0.20)

    private var resolved: (bundleID: String, path: String)? {
        if let hit = AppContainerLocator.locateContainer(bundleIDs: app.bundleIDs) {
            return (hit.bundleID, hit.url.path)
        }
        return nil
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(app.title)
                        .font(.title3.weight(.bold))
                        .foregroundColor(.white)
                    Text(resolved?.bundleID ?? app.bundleIDs.first ?? app.id)
                        .font(.caption.monospaced())
                        .foregroundColor(.white.opacity(0.55))
                    if let path = resolved?.path {
                        Text(path)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(3)
                    } else {
                        Text("未找到数据容器（未安装或 RootHide 路径不可见）")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(card)
            } header: {
                Text("应用信息").foregroundColor(accent)
            }

            Section {
                actionRow(
                    title: "刷新容器",
                    subtitle: "换该 App 的 Data 容器 UUID（工具箱 refreshId）",
                    color: accent
                ) {
                    cleanModel.runIdentityAction(.container, app: app, allFour: false)
                }
                actionRow(
                    title: "清钥匙串",
                    subtitle: "SecItem 删除该 Bundle 钥匙串项（cleanKeychainForBundleId）",
                    color: Color.orange
                ) {
                    cleanModel.runIdentityAction(.keychain, app: app, allFour: false)
                }
                actionRow(
                    title: "刷新标识符",
                    subtitle: "只改 lsdidentifiers 里该 App 的 Vendor/IDFV",
                    color: Color(red: 0.35, green: 0.75, blue: 1.0)
                ) {
                    cleanModel.runIdentityAction(.vendor, app: app, allFour: false)
                }
                actionRow(
                    title: "刷新广告符",
                    subtitle: "刷新 Advertisers/IDFA（AdvertisingIdentifierManager）",
                    color: Color(red: 0.7, green: 0.45, blue: 1.0)
                ) {
                    cleanModel.runIdentityAction(.advertiser, app: app, allFour: false)
                }
            } header: {
                Text("单项（与工具箱一致）").foregroundColor(.white.opacity(0.5))
            }

            Section {
                Button {
                    cleanModel.runIdentityAction(nil, app: app, allFour: true)
                } label: {
                    HStack {
                        if cleanModel.isBusy {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: cleanModel.oneTapSucceeded ? "checkmark.circle.fill" : "bolt.fill")
                        }
                        Text(cleanModel.oneTapSucceeded ? "再跑 · 一键刷新四项" : "一键刷新四项")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        cleanModel.oneTapSucceeded
                        ? Color.green
                        : LinearGradient(
                            colors: [Color(red: 0.15, green: 0.75, blue: 0.45), Color(red: 0.1, green: 0.55, blue: 0.35)],
                            startPoint: .leading,
                            endPoint: .trailing
                          )
                    )
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(cleanModel.isBusy || resolved == nil)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                Text("顺序：刷新容器 → 清钥匙串 → 刷新标识符 → 刷新广告符。四项都是针对「当前这个 App」。")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.45))
                    .listRowBackground(Color.clear)
            } header: {
                Text("一键（你要的合并）").foregroundColor(accent)
            }

            if !cleanModel.oneTapStepTexts.isEmpty {
                Section {
                    ForEach(Array(cleanModel.oneTapStepTexts.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundColor(.white.opacity(0.7))
                            .listRowBackground(card)
                    }
                } header: {
                    Text("最近结果").foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .listStyle(.plain)
        .onAppear {
            UITableView.appearance().backgroundColor = .clear
            UITableViewCell.appearance().backgroundColor = .clear
        }
        .navigationTitle(app.title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .alert("改机结果", isPresented: $cleanModel.showOneTapResult) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(cleanModel.oneTapResultText)
        }
    }

    private func actionRow(title: String, subtitle: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(color.opacity(0.25))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.bold))
                            .foregroundColor(color)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.45))
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.vertical, 4)
        }
        .disabled(cleanModel.isBusy || resolved == nil)
        .listRowBackground(card)
    }
}
