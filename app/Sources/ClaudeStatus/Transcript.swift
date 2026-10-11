import Foundation

/// セッションの transcript（~/.claude/projects/<slug>/<session_id>.jsonl）から、
/// 最後のユーザー発話より後ろの assistant の返答を拾う。ターミナル版の read_reply と同じ規則。
enum Transcript {
    /// 長時間セッションの transcript は数百MBになるので末尾だけ読む
    static let tailBytes = 4 * 1024 * 1024
    static let maxReplies = 30

    static func path(for session: Session) -> String? {
        let fm = FileManager.default
        if !session.transcriptPath.isEmpty, fm.fileExists(atPath: session.transcriptPath) {
            return session.transcriptPath
        }
        // hook が記録していない古いセッション向け: session_id で探す
        let projects = NSHomeDirectory() + "/.claude/projects"
        let name = (session.id as NSString).lastPathComponent + ".jsonl"
        for dir in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
            let candidate = "\(projects)/\(dir)/\(name)"
            if fm.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func replies(at path: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        // 途中で切れた先頭行は JSON として読めないので自然に捨てられる
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)

        var replies: [String] = []
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if obj["isSidechain"] as? Bool == true || obj["isMeta"] as? Bool == true { continue }
            guard let kind = obj["type"] as? String, kind == "user" || kind == "assistant" else { continue }
            let text = Self.text(of: obj)
            if text.isEmpty { continue }  // ツール呼び出し・ツール結果だけの行
            if kind == "user" { break }
            replies.append(text)
            if replies.count >= maxReplies { break }
        }
        return replies.reversed()
    }

    private static func text(of obj: [String: Any]) -> String {
        let message = obj["message"] as? [String: Any] ?? [:]
        if let s = message["content"] as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return "" }
        return blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
