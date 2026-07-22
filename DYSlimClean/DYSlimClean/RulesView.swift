import SwiftUI

struct RulesView: View {
    @StateObject private var model = RulesViewModel()

    private let accent = Color(red: 0.15, green: 0.85, blue: 0.78)
    private let danger = Color(red: 1.0, green: 0.35, blue: 0.40)
    private let card = Color(red: 0.11, green: 0.14, blue: 0.20)
    private let bgTop = Color(red: 0.05, green: 0.07, blue: 0.12)
    private let bgBottom = Color(red: 0.08, green: 0.10, blue: 0.16)

    var body: some View {
        ZStack {
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                explainCard
                profileBar
                modeBar
                actionBar
                Text(model.statusText)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)

                if model.isBusy {
                    ProgressView("正在加载抖音目录…")
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
                        .background(Color.black.opacity(0.82))
                        .clipShape(Capsule())
                        .padding(.bottom, 28)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { model.toast = "" }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.bootstrap() }
        .alert("永久保存为新规则", isPresented: $model.showSaveAs) {
            TextField("规则名称", text: $model.saveAsName)
            Button("取消", role: .cancel) {}
            Button("保存") { model.confirmSaveAs() }
        } message: {
            Text(model.saveAsFavorite ? "将写入本机永久收藏规则" : "将永久保存，可在上方切换选用")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("功能选项 · 规则")
                    .font(.title3.weight(.bold))
                    .foregroundColor(.white)
                Text("显示抖音沙盒全部目录/文件")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
            Button {
                model.toggleFavoriteActive()
            } label: {
                Image(systemName: (model.profiles.first(where: { $0.id == model.activeId })?.isFavorite == true) ? "star.fill" : "star")
                    .foregroundColor(.yellow)
                    .padding(8)
                    .background(card)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var explainCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("说明")
                .font(.caption.weight(.bold))
                .foregroundColor(accent)
            Text("✓ 勾选 = 瘦身时保留　　○ 不勾选 = 瘦身时删除")
                .font(.caption)
                .foregroundColor(.white.opacity(0.85))
            Text("默认精简 = 指定 Documents 文件夹 + 精简包白名单；可在其上追加保留，或完全自定义。保存规则会永久写入本机。")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
            Text("_ttinstall_document 强制保留（橙色勾），无法取消。")
                .font(.caption2)
                .foregroundColor(.orange.opacity(0.9))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var profileBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("规则选用（含收藏）")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.45))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.profiles) { p in
                        Button {
                            model.selectProfile(p.id)
                        } label: {
                            HStack(spacing: 4) {
                                if p.isFavorite {
                                    Image(systemName: "star.fill").font(.caption2)
                                }
                                Text(p.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(p.id == model.activeId ? accent.opacity(0.25) : card)
                            .foregroundColor(p.id == model.activeId ? accent : .white)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(p.id == model.activeId ? accent.opacity(0.6) : Color.clear, lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 8)
    }

    private var modeBar: some View {
        HStack(spacing: 8) {
            modeChip("默认精简", selected: model.editMode == .defaultSlim) {
                model.useDefaultSlim()
            }
            modeChip("精简+追加", selected: model.editMode == .defaultPlus) {
                model.switchToDefaultPlusEditing()
            }
            modeChip("完全自定义", selected: model.editMode == .fullCustom) {
                model.switchToFullCustomEditing()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func modeChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(selected ? Color.orange.opacity(0.28) : card)
                .foregroundColor(selected ? .orange : .white.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                toolBtn("刷新目录", "arrow.clockwise") { model.refreshTree() }
                toolBtn("永久保存", "square.and.arrow.down.fill") { model.saveCurrent() }
                toolBtn("另存/收藏", "star.circle") { model.beginSaveAs(favorite: true) }
            }
            HStack(spacing: 8) {
                toolBtn("另存普通", "doc.badge.plus") { model.beginSaveAs(favorite: false) }
                toolBtn("回默认精简", "arrow.counterclockwise") { model.useDefaultSlim() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func toolBtn(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
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
            .padding(.bottom, 28)
        }
    }

    private func row(_ node: RuleNode) -> some View {
        let kept = model.isEffectivelyChecked(node.id)
        return HStack(spacing: 8) {
            Color.clear.frame(width: CGFloat(node.depth) * 12)

            Button {
                model.toggleCheck(node.id)
            } label: {
                Image(systemName: kept ? "checkmark.square.fill" : "square")
                    .foregroundColor(model.isForced(node.id) ? .orange : (kept ? accent : danger.opacity(0.85)))
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: node.isDirectory
                          ? (model.expanded.contains(node.id) ? "folder.fill" : "folder")
                          : "doc")
                        .foregroundColor(node.isDirectory ? Color(red: 1.0, green: 0.75, blue: 0.2) : .white.opacity(0.45))
                    if node.isDirectory {
                        Button {
                            model.toggleExpand(node.id)
                        } label: {
                            Text(node.name)
                                .font(.subheadline)
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(node.name)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(kept ? "保留" : "删除")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(kept ? accent : danger)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((kept ? accent : danger).opacity(0.15))
                        .clipShape(Capsule())
                }
                if let hint = node.hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.leading, 22)
                }
            }

            if node.isDirectory {
                Button {
                    model.toggleExpand(node.id)
                } label: {
                    Image(systemName: model.expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.35))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

#Preview {
    RulesView()
}
