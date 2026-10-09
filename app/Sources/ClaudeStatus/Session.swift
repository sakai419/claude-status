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
    let lastPrompt: String
    let terminalApp: String
    let cmuxWorkspace: String
    let cmuxPanel: String

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
        lastPrompt = str("last_prompt")
        let term = json["terminal"] as? [String: Any] ?? [:]
        terminalApp = term["app"] as? String ?? ""
        cmuxWorkspace = term["cmux_workspace"] as? String ?? ""
        cmuxPanel = term["cmux_panel"] as? String ?? ""
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
}

/// hook が記録する状態。
enum SessionState: String {
    case waiting, subagent, running, completed, unknown

    var label: String {
        switch self {
        case .waiting: "質問中"
        case .subagent: "サブ待ち"
        case .running: "実行中"
        case .completed: "完了"
        case .unknown: "不明"
        }
    }
}

/// 一覧での区分。状態に加えて「更新が止まっている」アイドルを持つ。
/// 並び順はターミナル版（claude-status-render.sh）と揃えている。
enum SessionGroup: Int, CaseIterable, Identifiable {
    case waiting, idle, completed, subagent, running, unknown

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .waiting: "質問中"
        case .idle: "アイドル"
        case .completed: "完了"
        case .subagent: "サブ待ち"
        case .running: "実行中"
        case .unknown: "不明"
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "exclamationmark.bubble.fill"
        case .idle: "moon.zzz.fill"
        case .completed: "checkmark.circle.fill"
        case .subagent: "person.2.fill"
        case .running: "circle.dotted.circle"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .waiting: .orange
        case .idle: .gray
        case .completed: .green
        case .subagent: .purple
        case .running: .cyan
        case .unknown: .pink
        }
    }

    static func of(_ session: Session, now: Date, idleAfter: TimeInterval) -> SessionGroup {
        let state = session.state
        // 質問中は手当てが必要なのでアイドルに降格しない
        if state != .waiting, now.timeIntervalSince(session.updatedDate) >= idleAfter {
            return .idle
        }
        switch state {
        case .waiting: return .waiting
        case .subagent: return .subagent
        case .running: return .running
        case .completed: return .completed
        case .unknown: return .unknown
        }
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
