import ServiceManagement
import SwiftUI

/// メインウィンドウ。左にセッション一覧、右に選んだセッションの詳細。
/// ↑↓ / j k で選択を動かせる（ターミナル版の cs と同じキー）。
struct MainWindow: View {
    static let id = "main"

    let store: SessionStore
    @State private var selectedID: String?

    /// 表示順に並べた全セッション（キー操作の移動先を決めるのに使う）
    private var ordered: [Session] { store.grouped.flatMap(\.sessions) }

    private var selected: Session? {
        guard let id = selectedID else { return nil }
        return store.sessions.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            SessionListPane(store: store, selectedID: $selectedID)
                .frame(width: 360)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                if let session = selected {
                    SessionDetailView(store: store, session: session)
                        .id(session.id)
                } else {
                    EmptyDetail()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 460)
        .background(Theme.background)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, "j", "k"]) { press in
            move(press.key == .upArrow || press.key == "k" ? -1 : 1)
            return .handled
        }
        .onAppear(perform: keepSelection)
        .onChange(of: store.sessions) { keepSelection() }
    }

    /// 選択中のセッションが消えたら（または未選択なら）先頭を選ぶ
    private func keepSelection() {
        if let id = selectedID, store.sessions.contains(where: { $0.id == id }) { return }
        selectedID = ordered.first?.id
    }

    private func move(_ delta: Int) {
        let list = ordered
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), list.count - 1)
        selectedID = list[next].id
    }
}

private struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 30, weight: .light))
            Text("セッションを選ぶと、プロンプトと返答が表示されます")
                .font(.system(size: 12.5))
        }
        .foregroundStyle(Theme.textTertiary)
    }
}

// MARK: - 一覧

private struct SessionListPane: View {
    let store: SessionStore
    @Binding var selectedID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            if store.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 26, weight: .light))
                    Text("動いているセッションはありません")
                        .font(.system(size: 12.5))
                }
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(store.grouped, id: \.group) { entry in
                                GroupSection(store: store, group: entry.group,
                                             sessions: entry.sessions, selectedID: $selectedID)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            ListFooter()
        }
    }

    /// 上端はタイトルバーを隠しているので、信号機ボタンの分だけ左を空ける
    private var header: some View {
        HStack(spacing: 6) {
            ForEach(store.grouped, id: \.group) { entry in
                CountChip(group: entry.group, count: entry.sessions.count)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 84)
        .padding(.trailing, 14)
        .frame(height: 48)
    }
}

private struct CountChip: View {
    let group: SessionGroup
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: group.symbol)
                .font(.system(size: 9.5))
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(group.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(group.color.opacity(0.16), in: Capsule())
        .help(group.title)
    }
}

private struct GroupSection: View {
    let store: SessionStore
    let group: SessionGroup
    let sessions: [Session]
    @Binding var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(group.color).frame(width: 6, height: 6)
                Text(group.title.uppercased())
                    .foregroundStyle(Theme.textSecondary)
                Text("\(sessions.count)")
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.leading, 4)

            ForEach(sessions) { session in
                SessionRow(store: store, session: session, group: group,
                           selected: session.id == selectedID) { selectedID = session.id }
                    .id(session.id)
            }
        }
    }
}

private struct SessionRow: View {
    let store: SessionStore
    let session: Session
    let group: SessionGroup
    let selected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(group.color)
                .frame(width: 3)
                .opacity(selected ? 1 : 0.75)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if group == .idle {
                        Text(session.state.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    Text(relativeTime(from: session.updatedDate, now: store.now))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(session.parentPath.isEmpty ? " " : session.parentPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)

                if !session.promptSummary.isEmpty {
                    Text(session.promptSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text.opacity(0.8))
                        .lineLimit(2)
                        .padding(.top, 2)
                }
                if !session.intent.isEmpty {
                    Label(session.intent, systemImage: "flag.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if session.state == .subagent, session.subagentCount > 0 {
                    Label("サブエージェント \(session.subagentCount)件", systemImage: "person.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SessionGroup.subagent.color)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.surfaceSelected : hovering ? Theme.surfaceHover : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? group.color.opacity(0.55) : .clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("パスをコピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.cwd, forType: .string)
            }
            Divider()
            Button("一覧から消す", role: .destructive) { store.dismiss(session) }
        }
    }
}

// MARK: - フッタ

private struct ListFooter: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        HStack(spacing: 10) {
            Toggle("ログイン時に起動", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
            if let loginError {
                Text(loginError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
            Text("↑↓ で選択")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "設定できませんでした"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// 小さなアイコンボタン。ホバーで背景が出る。
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(hovering ? 0.12 : 0))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}
