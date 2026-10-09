import ServiceManagement
import SwiftUI

/// メニューバーから開くパネル。一覧と詳細を同じ枠の中で切り替える。
struct ContentView: View {
    let store: SessionStore
    @State private var selectedID: String?

    private var selected: Session? {
        guard let id = selectedID else { return nil }
        return store.sessions.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session = selected {
                SessionDetailView(store: store, session: session) { selectedID = nil }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                SessionListView(store: store) { selectedID = $0.id }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Divider()
            FooterView()
        }
        .frame(width: 400)
        .frame(minHeight: 200, maxHeight: 620)
        .animation(.snappy(duration: 0.22), value: selectedID)
        // 詳細を開いている間にセッションが消えたら一覧へ戻す
        .onChange(of: store.sessions) {
            if selectedID != nil, selected == nil { selectedID = nil }
        }
    }
}

// MARK: - 一覧

struct SessionListView: View {
    let store: SessionStore
    let onSelect: (Session) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(store.grouped, id: \.group) { entry in
                            GroupSection(store: store, group: entry.group, sessions: entry.sessions, onSelect: onSelect)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Claude Code")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            ForEach(store.grouped, id: \.group) { entry in
                CountChip(group: entry.group, count: entry.sessions.count)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("動いているセッションはありません")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

struct CountChip: View {
    let group: SessionGroup
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: group.symbol)
                .font(.system(size: 10))
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(group.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(group.color.opacity(0.14), in: Capsule())
        .help(group.title)
    }
}

struct GroupSection: View {
    let store: SessionStore
    let group: SessionGroup
    let sessions: [Session]
    let onSelect: (Session) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: group.symbol)
                    .foregroundStyle(group.color)
                Text(group.title)
                    .foregroundStyle(.secondary)
                Text("\(sessions.count)")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.leading, 2)

            ForEach(sessions) { session in
                SessionRow(store: store, session: session, group: group) { onSelect(session) }
            }
        }
    }
}

// MARK: - 行

struct SessionRow: View {
    let store: SessionStore
    let session: Session
    let group: SessionGroup
    let onOpen: () -> Void

    @State private var hovering = false
    @State private var confirming = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(group.color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if group == .idle {
                        Text(session.state.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer(minLength: 4)
                    trailing
                }
                Text(session.parentPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)

                if !session.promptSummary.isEmpty {
                    Text(session.promptSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(2)
                        .padding(.top, 2)
                }
                if !session.intent.isEmpty {
                    Label(session.intent, systemImage: "flag.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if session.state == .subagent, session.subagentCount > 0 {
                    Label(subagentText, systemImage: "person.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple)
                        .lineLimit(1)
                }
                if confirming {
                    confirmBar.padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.08 : 0.04))
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { if !confirming { onOpen() } }
        .contextMenu {
            Button("詳細を見る", action: onOpen)
            if TerminalJump.canJump(session) {
                Button("ターミナルで開く") { TerminalJump.jump(session) }
            }
            Button("パスをコピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.cwd, forType: .string)
            }
            Divider()
            Button("一覧から消す", role: .destructive) { confirming = true }
        }
    }

    /// 右上。普段は相対時刻、ホバー中は操作ボタン。
    @ViewBuilder
    private var trailing: some View {
        if hovering && !confirming {
            HStack(spacing: 2) {
                if TerminalJump.canJump(session) {
                    IconButton(symbol: "arrow.up.forward.app", help: "ターミナルで開く") {
                        TerminalJump.jump(session)
                    }
                }
                IconButton(symbol: "xmark", help: "一覧から消す") { confirming = true }
            }
        } else {
            Text(relativeTime(from: session.updatedDate, now: store.now))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var confirmBar: some View {
        HStack(spacing: 8) {
            Text("一覧から消しますか？")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("やめる") { confirming = false }
                .controlSize(.small)
            Button("消す", role: .destructive) { store.dismiss(session) }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var subagentText: String {
        let types = session.subagentTypes.isEmpty ? "" : " · \(session.subagentTypes)"
        return "サブエージェント \(session.subagentCount)件\(types)"
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(hovering ? 0.12 : 0))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - フッタ

struct FooterView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        HStack(spacing: 10) {
            Toggle("ログイン時に起動", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
            if let loginError {
                Text(loginError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(loginError)
            }
            Spacer()
            Button("終了") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
