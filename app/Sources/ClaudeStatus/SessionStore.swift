import Foundation
import Observation

/// ~/.claude/status/sessions/*.json を読み、変化を追いかける。
/// 書き手は hook（シェルスクリプト）だけで、アプリは読むのと「一覧から消す」だけ。
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [Session] = []
    private(set) var now = Date()

    /// 更新がこれだけ止まったらアイドル扱い（ターミナル版の CS_IDLE_SECS と同じ既定値）
    let idleAfter: TimeInterval = 1800

    let root: URL
    private var sessionsDir: URL { root.appendingPathComponent("sessions") }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?

    init() {
        let env = ProcessInfo.processInfo.environment["CS_STATUS_ROOT"]
        root = URL(fileURLWithPath: env ?? NSHomeDirectory() + "/.claude/status")
        reload()
        // 変化はディレクトリ監視で拾う。監視が張れない間（ディレクトリがまだ無い等）と
        // 相対時刻の更新のために、2秒ごとにも読み直す（ファイルは数KBなので軽い）。
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        now = Date()
        watchIfNeeded()
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Session] = []
        for url in files where url.pathExtension == "json" {
            // 書き込み途中・削除競合のファイルは1件ずつ読み飛ばす
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = Session(json: obj)
            else { continue }
            loaded.append(session)
        }
        loaded.sort { $0.updatedEpoch > $1.updatedEpoch }
        if loaded != sessions { sessions = loaded }
    }

    func group(of session: Session) -> SessionGroup {
        SessionGroup.of(session, now: now, idleAfter: idleAfter)
    }

    /// 表示順に並べた区分ごとのセッション。空の区分は含めない。
    var grouped: [(group: SessionGroup, sessions: [Session])] {
        let byGroup = Dictionary(grouping: sessions) { group(of: $0) }
        return SessionGroup.allCases.compactMap { g in
            guard let list = byGroup[g], !list.isEmpty else { return nil }
            return (g, list)
        }
    }

    func count(_ g: SessionGroup) -> Int {
        sessions.filter { group(of: $0) == g }.count
    }

    /// 一覧から外す。JSON を消して status.md も作り直す（ターミナル版の x と同じ）。
    /// プロセスは止めないので、そのセッションがまた動けば次の hook で戻ってくる。
    func dismiss(_ session: Session) {
        let name = (session.id as NSString).lastPathComponent
        try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent(name + ".json"))
        reload()
        if let render = Self.binURL?.appendingPathComponent("claude-status-render.sh") {
            Task.detached { _ = try? Shell.run(render, arguments: []) }
        }
    }

    /// この repo の bin/。build.sh が Info.plist に書き込む。
    static var binURL: URL? {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "ClaudeStatusBin") as? String,
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func watchIfNeeded() {
        guard watcher == nil else { return }
        let fd = open(sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // ディレクトリごと消された・移されたら張り直す
                if let w = self.watcher, w.data.contains(.delete) || w.data.contains(.rename) {
                    w.cancel()
                    self.watcher = nil
                }
                self.reload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}

enum Shell {
    /// 外部コマンドを実行して標準出力を返す。シェルを経由しない。
    @discardableResult
    static func run(_ executable: URL, arguments: [String], environment: [String: String]? = nil) throws -> String {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        if let environment {
            p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
