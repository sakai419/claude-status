import Foundation
import Observation

/// ~/.claude/status/sessions/*.json を読み、変化を追いかける。
/// 書き手は hook（シェルスクリプト）で、アプリが書くのは「一覧から消す」とキープの印だけ。
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [Session] = []
    /// 表示順に並べた区分ごとのセッション。空の区分は含めない。中身が変わったときだけ入れ替える。
    private(set) var grouped: [SessionGroupEntry] = []
    /// 相対時刻の表示に使う今の時刻。刻むのはウィンドウが見えている間だけ。
    private(set) var now = Date()

    /// ウィンドウが見えている間 true にする。相対時刻を刻み続けるかどうか。
    var clockRunning = false {
        didSet {
            guard clockRunning != oldValue else { return }
            if clockRunning { tick() }
            scheduleTimer()
        }
    }

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
        scheduleTimer()
    }

    /// 変化はディレクトリ監視で拾う（hook の書き込みは mv / rm なので必ずディレクトリに出る）。
    /// タイマーは、相対時刻を刻む（見えている間だけ1秒ごと）のと、
    /// アイドルへの移り変わり・監視が張れない間（ディレクトリがまだ無い等）の読み直しのため（見えていなければ1分ごと）。
    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: clockRunning ? 1 : 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = clockRunning ? 0.2 : 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        if clockRunning { now = Date() }
        if watcher == nil { reload() } else { regroup() }
    }

    func reload() {
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
        regroup()
    }

    /// 区分分けをやり直す。アイドル扱いは時刻で変わるので、表示用の now ではなく本当の今で決める。
    private func regroup() {
        let current = Date()
        let byGroup = Dictionary(grouping: sessions) {
            SessionGroup.of($0, now: current, idleAfter: idleAfter)
        }
        let next = SessionGroup.allCases.compactMap { g in
            byGroup[g].map { SessionGroupEntry(group: g, sessions: $0) }
        }
        // 見ているビュー（メニューバーのアイコンも含む）を、変わったときだけ描き直させる
        if next != grouped { grouped = next }
    }

    func group(of session: Session) -> SessionGroup {
        grouped.first { $0.sessions.contains { $0.id == session.id } }?.group
            ?? SessionGroup.of(session, now: Date(), idleAfter: idleAfter)
    }

    func count(_ g: SessionGroup) -> Int {
        grouped.first { $0.group == g }?.sessions.count ?? 0
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

    /// キープの印を付ける・外す（ターミナル版の p と同じ）。
    /// updated_epoch には触れないので、アイドルかどうかは変わらない。
    func setKept(_ session: Session, _ kept: Bool) {
        let name = (session.id as NSString).lastPathComponent
        let url = sessionsDir.appendingPathComponent(name + ".json")
        guard let data = try? Data(contentsOf: url),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if kept { obj["kept"] = true } else { obj.removeValue(forKey: "kept") }
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return }
        // hook と同じく tmp→mv で置き換え、自分だけが読める権限で作る
        let tmp = url.path + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
        guard FileManager.default.createFile(atPath: tmp, contents: out, attributes: [.posixPermissions: 0o600]),
              rename(tmp, url.path) == 0
        else {
            try? FileManager.default.removeItem(atPath: tmp)
            return
        }
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

struct SessionGroupEntry: Equatable {
    let group: SessionGroup
    let sessions: [Session]
}

enum Shell {
    /// 外部コマンドを実行して標準出力を返す。シェルを経由しない。
    @discardableResult
    static func run(_ executable: URL, arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
