import SwiftUI

/// 1セッションの詳細。一覧では短縮しているプロンプトの全文と、エージェントの返答を読む。
struct SessionDetailView: View {
    let store: SessionStore
    let session: Session
    let onBack: () -> Void

    @State private var replies: [String] = []
    @State private var loading = true
    @State private var transcriptMissing = false
    @State private var confirming = false

    private var group: SessionGroup { store.group(of: session) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heading
                    meta
                    section("プロンプト") {
                        if session.lastPrompt.isEmpty {
                            placeholder("記録がありません")
                        } else {
                            Text(session.lastPrompt)
                                .font(.system(size: 12.5))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    section(session.state == .completed ? "返答" : "返答（進行中）") {
                        if loading && replies.isEmpty {
                            ProgressView().controlSize(.small)
                        } else if transcriptMissing {
                            placeholder("transcript が見つかりません")
                        } else if replies.isEmpty {
                            placeholder("まだ返答がありません")
                        } else {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(replies.enumerated()), id: \.offset) { i, text in
                                    if i > 0 { Divider() }
                                    MarkdownText(text)
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        // 返答はセッションが更新されるたびに読み直す
        .task(id: session.updatedEpoch) { await loadReplies() }
        .onKeyPress(.escape) {
            onBack()
            return .handled
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Label("一覧", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            Spacer()
            if confirming {
                Text("一覧から消しますか？")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("やめる") { confirming = false }.controlSize(.small)
                Button("消す", role: .destructive) { store.dismiss(session) }.controlSize(.small)
            } else {
                if TerminalJump.canJump(session) {
                    Button {
                        TerminalJump.jump(session)
                    } label: {
                        Label("ターミナルで開く", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
                IconButton(symbol: "xmark", help: "一覧から消す") { confirming = true }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: group.symbol)
                Text(group == .idle ? "アイドル（\(session.state.label)）" : group.title)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(group.color)

            Text(session.projectName)
                .font(.system(size: 17, weight: .semibold))
                .textSelection(.enabled)
            Text(session.parentPath + "/")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private var meta: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            GridRow {
                metaLabel("更新")
                Text("\(session.updatedAt)  ·  \(relativeTime(from: session.updatedDate, now: store.now))")
                    .monospacedDigit()
            }
            if !session.intent.isEmpty {
                GridRow {
                    metaLabel("意図")
                    Text(session.intent).textSelection(.enabled)
                }
            }
            if session.state == .subagent, session.subagentCount > 0 {
                GridRow {
                    metaLabel("サブ")
                    Text("\(session.subagentCount)件" + (session.subagentTypes.isEmpty ? "" : " · \(session.subagentTypes)"))
                }
            }
        }
        .font(.system(size: 11.5))
    }

    private func metaLabel(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(.tertiary)
    }

    private func loadReplies() async {
        loading = true
        let session = self.session
        let result: [String]? = await Task.detached(priority: .userInitiated) {
            guard let path = Transcript.path(for: session) else { return nil }
            return Transcript.replies(at: path)
        }.value
        transcriptMissing = result == nil
        replies = result ?? []
        loading = false
    }
}
