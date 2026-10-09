import SwiftUI

/// 1セッションの詳細。一覧では短縮しているプロンプトの全文と、エージェントの返答を読む。
struct SessionDetailView: View {
    let store: SessionStore
    let session: Session

    @State private var replies: [String] = []
    @State private var loading = true
    @State private var transcriptMissing = false
    @State private var confirming = false

    private var group: SessionGroup { store.group(of: session) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heading
                    section("プロンプト") {
                        if session.lastPrompt.isEmpty {
                            placeholder("記録がありません")
                        } else {
                            Text(session.lastPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
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
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(Array(replies.enumerated()), id: \.offset) { i, text in
                                    if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                                    MarkdownText(text)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        // 返答はセッションが更新されるたびに読み直す
        .task(id: session.updatedEpoch) { await loadReplies() }
    }

    /// 上端の帯。タイトルバーを隠しているので、ここがウィンドウのつまみも兼ねる。
    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: group.symbol)
                Text(group == .idle ? "アイドル（\(session.state.label)）" : group.title)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(group.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(group.color.opacity(0.14), in: Capsule())

            Text("\(relativeTime(from: session.updatedDate, now: store.now))に更新")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)

            Spacer()

            if confirming {
                Text("一覧から消しますか？")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                Button("やめる") { confirming = false }.controlSize(.small)
                Button("消す", role: .destructive) { store.dismiss(session) }.controlSize(.small)
            } else {
                IconButton(symbol: "xmark", help: "一覧から消す") { confirming = true }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.projectName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
            if !session.parentPath.isEmpty {
                Text(session.parentPath + "/")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .textSelection(.enabled)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    metaLabel("更新")
                    Text(session.updatedAt).monospacedDigit()
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
            .font(.system(size: 12))
            .foregroundStyle(Theme.text.opacity(0.85))
            .padding(.top, 8)
        }
    }

    private func metaLabel(_ s: String) -> some View {
        Text(s).foregroundStyle(Theme.textTertiary).gridColumnAlignment(.trailing)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(Theme.textTertiary)
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
