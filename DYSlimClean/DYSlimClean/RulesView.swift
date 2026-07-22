import SwiftUI

struct RulesView: View {
    @StateObject private var model = RulesViewModel()

    private let accent = Color(red: 0.15, green: 0.85, blue: 0.78)
    private let card = Color(red: 0.11, green: 0.14, blue: 0.20)
    private let bgTop = Color(red: 0.05, green: 0.07, blue: 0.12)
    private let bgBottom = Color(red: 0.08, green: 0.10, blue: 0.16)

    var body: some View {
        ZStack {
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                toolbar
                Text(model.statusText)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                if model.isBusy {
                    ProgressView("加载中…")
                        .tint(accent)
                        .foregroundColor(.white)
                        .padding(.top, 40)
                    Spacer()
                } else {
                    list
                }
            }

            if !model.toast.isEmpty {
                VStack {
                    Spacer()
                    Text(model.toast)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.8))
                        .clipShape(Capsule())
                        .padding(.bottom, 24)
                }
                .transition(.opacity)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        model.toast = ""
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.bootstrap() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("功能选项 · 规则")
                    .font(.title3.weight(.bold))
                    .foregroundColor(.white)
                Text(model.useCustom ? "自定义保留（打钩=保留）" : "默认规则可改勾后保存")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
            Text(model.useCustom ? "自定义" : "默认")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(model.useCustom ? Color.orange.opacity(0.25) : accent.opacity(0.2))
                .foregroundColor(model.useCustom ? .orange : accent)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            toolBtn("刷新目录", icon: "arrow.clockwise") { model.refreshTree() }
            toolBtn("保存规则", icon: "square.and.arrow.down") { model.saveRules() }
            toolBtn("默认规则", icon: "arrow.counterclockwise") { model.applyDefault() }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func toolBtn(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(card)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.nodes) { node in
                    row(node)
                    Divider().background(Color.white.opacity(0.06))
                }
            }
            .background(card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func row(_ node: RuleNode) -> some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: CGFloat(node.depth) * 14)

            Button {
                model.toggleCheck(node.id)
            } label: {
                Image(systemName: model.isEffectivelyChecked(node.id)
                      ? "checkmark.square.fill" : "square")
                    .foregroundColor(model.isForced(node.id) ? .orange : accent)
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)

            if node.isDirectory {
                Button {
                    model.toggleExpand(node.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.expanded.contains(node.id) ? "folder.fill" : "folder")
                            .foregroundColor(Color(red: 1.0, green: 0.75, blue: 0.2))
                        Text(node.name)
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Spacer()
                        Image(systemName: model.expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "doc")
                    .foregroundColor(.white.opacity(0.45))
                Text(node.name)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

#Preview {
    RulesView()
}
