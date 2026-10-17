import Foundation
import SwiftUI

/// hook が ~/.claude/status/sessions/<session_id>.json に書く1セッション分の状態。
/// 書き手はシェルスクリプトなので、型が揺れても読めるよう緩く読む。
struct Session: Identifiable, Hashable {
    let id: String
    let cwd: String
    let status: String
    let updatedAt: String
    let updatedEpoch: TimeInterval
    let intent: String
    let transcriptPath: String
    let subagentCount: Int
    let subagentTypes: String
    let shellCount: Int
    let shellDescs: String
    let cronCount: Int
    let cronDescs: String
    let lastPrompt: String
    /// あえて残しているという手動の印。アイドルになるとアイドルではなくキープに入る。
    let kept: Bool

    init?(json: [String: Any]) {
        func str(_ key: String) -> String {
            switch json[key] {
            case let s as String: return s
            case let n as NSNumber: return n.stringValue
            default: return ""
            }
        }
        func num(_ key: String) -> Double {
            switch json[key] {
            case let n as NSNumber: return n.doubleValue
            case let s as String: return Double(s) ?? 0
            default: return 0
            }
        }
        let sid = str("session_id")
        guard !sid.isEmpty else { return nil }
        id = sid
        cwd = str("cwd")
        status = str("status")
        updatedAt = str("updated_at")
        updatedEpoch = num("updated_epoch")
        intent = str("intent")
        transcriptPath = str("transcript_path")
        subagentCount = Int(num("subagent_count"))
        subagentTypes = str("subagent_types")
        shellCount = Int(num("shell_count"))
        shellDescs = str("shell_descs")
        cronCount = Int(num("cron_count"))
        cronDescs = str("cron_descs")
        lastPrompt = str("last_prompt")
        kept = (json["kept"] as? Bool) ?? false
    }

    /// cwd の末尾（プロジェクト名）。ホームディレクトリそのものは ~ と出す。
    var projectName: String {
        if cwd == NSHomeDirectory() { return "~" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "(不明)" : name
    }

    /// cwd の親ディレクトリ。ホームは ~ に縮める。cwd がホームなら空。
    var parentPath: String {
        if cwd == NSHomeDirectory() { return "" }
        let parent = (cwd as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        if parent == home { return "~" }
        if parent.hasPrefix(home + "/") { return "~" + parent.dropFirst(home.count) }
        return parent
    }

    var state: SessionState { SessionState(rawValue: status) ?? .unknown }

    /// 一覧に出す直近のプロンプト。サブエージェントの完了通知も UserPromptSubmit で
    /// 記録されるので、タグの羅列ではなく何が起きたかだけを出す。
    var promptSummary: String {
        let text = lastPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<task-notification>") { return "（バックグラウンドタスクの完了通知）" }
        // 2行に収めるので、空行で行数を使わないよう連続する改行は1つにまとめる
        return text.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
    }

    var updatedDate: Date { Date(timeIntervalSince1970: updatedEpoch) }

    /// 待ち受けている shell / cron の内訳。待受中とサブ待ちのときだけ意味を持つ。
    var watches: [Watch] {
        guard state == .watching || state == .subagent else { return [] }
        return [
            Watch(kind: "shell", count: shellCount, descs: shellDescs),
            Watch(kind: "cron", count: cronCount, descs: cronDescs),
        ].filter { $0.count > 0 }
    }
}

/// セッションが待ち受けているもの（バックグラウンドの shell と Monitor、cron の予約）。
struct Watch: Hashable {
    let kind: String
    let count: Int
    let descs: String
}

/// hook が記録する状態。
enum SessionState: String {
    case waiting, watching, subagent, running, completed, unknown

    var label: String {
        switch self {
        case .waiting: "質問中"
        case .watching: "待受中"
        case .subagent: "サブ待ち"
        case .running: "実行中"
        case .completed: "完了"
        case .unknown: "不明"
        }
    }
}

/// 一覧での区分。状態に加えて「更新が止まっている」アイドルと、そのうち印の付いたキープを持つ。
/// 並び順はターミナル版（claude-status-render.sh）と揃えている。
enum SessionGroup: Int, CaseIterable, Identifiable {
    case waiting, idle, kept, completed, watching, subagent, running, unknown

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .waiting: "質問中"
        case .idle: "アイドル"
        case .kept: "キープ"
        case .completed: "完了"
        case .watching: "待受中"
        case .subagent: "サブ待ち"
        case .running: "実行中"
        case .unknown: "不明"
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "exclamationmark.bubble.fill"
        case .idle: "moon.zzz.fill"
        // ピンはウィンドウ固定のボタンと紛らわしいので、しおりにする
        case .kept: "bookmark.fill"
        case .completed: "checkmark.circle.fill"
        case .watching: "antenna.radiowaves.left.and.right"
        case .subagent: "person.2.fill"
        case .running: "circle.dotted.circle"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .waiting: .orange
        case .idle: .gray
        case .kept: .indigo
        case .completed: .green
        case .watching: .blue
        case .subagent: .purple
        case .running: .cyan
        case .unknown: .pink
        }
    }

    static func of(_ session: Session, now: Date, idleAfter: TimeInterval) -> SessionGroup {
        let state = session.state
        // 質問中は手当てが必要なのでアイドルに降格しない
        if state != .waiting, now.timeIntervalSince(session.updatedDate) >= idleAfter {
            return session.kept ? .kept : .idle
        }
        switch state {
        case .waiting: return .waiting
        case .watching: return .watching
        case .subagent: return .subagent
        case .running: return .running
        case .completed: return .completed
        case .unknown: return .unknown
        }
    }
}

/// 相対時刻の表示。時刻が刻まれるたびに、行や詳細の全体ではなくこの文字だけを描き直す。
struct RelativeTimeText: View {
    let store: SessionStore
    let date: Date
    var suffix = ""

    var body: some View {
        Text(relativeTime(from: date, now: store.now) + suffix)
    }
}

/// 「3分前」のような相対時刻。ターミナル版と同じ刻み。
func relativeTime(from date: Date, now: Date) -> String {
    let d = Int(now.timeIntervalSince(date))
    if d < 0 { return "たった今" }
    if d < 60 { return "\(d)秒前" }
    if d < 3600 { return "\(d / 60)分前" }
    if d < 86400 { return "\(d / 3600)時間前" }
    return "\(d / 86400)日前"
}
