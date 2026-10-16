import AppKit
import Observation
import SwiftUI

/// メインウィンドウ（iTerm2 のホットキーウィンドウのようなパネル）の出し入れを受け持つ。
/// ショートカットで、いま見ている画面（フルスクリーンのアプリの上も含む）の手前に出し、
/// よそをクリックしたら引っ込める。ピンで固定している間は引っ込めない。
/// 設定は UserDefaults に残し、次の起動でも同じにする。
@MainActor
@Observable
final class WindowManager {
    /// ウィンドウを呼び出すショートカット。nil なら使わない。
    var shortcut: KeyCombo? {
        didSet {
            // 消したことも覚えておく（何も無いときは既定のショートカットを使うので、空のデータを置く）
            UserDefaults.standard.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(),
                                      forKey: Self.shortcutKey)
            registerShortcut()
        }
    }
    /// 登録できなかったとき（他のアプリが使っている等）に true
    private(set) var shortcutFailed = false

    /// よそをクリックしても引っ込めない
    var pinned: Bool {
        didSet { UserDefaults.standard.set(pinned, forKey: Self.pinnedKey) }
    }
    var opacity: Double {
        didSet {
            UserDefaults.standard.set(opacity, forKey: Self.opacityKey)
            panel?.alphaValue = opacity
        }
    }

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var hotKey: GlobalHotKey?

    private static let shortcutKey = "windowShortcut"
    private static let pinnedKey = "pinned"
    private static let opacityKey = "opacity"
    /// 以前の SwiftUI のウィンドウと同じ名前にして、位置と大きさを引き継ぐ
    private static let frameName = "main"

    init(store: SessionStore) {
        self.store = store
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.shortcutKey) {
            shortcut = try? JSONDecoder().decode(KeyCombo.self, from: data)
        } else {
            shortcut = .defaultShortcut
        }
        pinned = defaults.bool(forKey: Self.pinnedKey)
        opacity = defaults.object(forKey: Self.opacityKey) as? Double ?? 0.9
        hotKey = GlobalHotKey { [weak self] in self?.toggle() }
        registerShortcut()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.pinned else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    /// ショートカットを記録している間は、いまのショートカットを外しておく（押しても呼び出しが起きないように）
    func suspendShortcut(_ suspended: Bool) {
        if suspended { hotKey?.register(nil) } else { registerShortcut() }
    }

    private func registerShortcut() {
        shortcutFailed = !(hotKey?.register(shortcut) ?? true)
    }

    /// ショートカットで呼ばれる。前面で使っている最中なら引っ込め、そうでなければ呼び出す。
    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow, NSApp.isActive {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = Self.activeScreen() { move(panel, to: screen) }
        NSApp.unhide(nil)
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate()
    }

    /// 引っ込めて、前に使っていたアプリに戻す
    func hide() {
        panel?.orderOut(nil)
        NSApp.hide(nil)
    }

    /// 設定ウィンドウを、メインウィンドウと同じ画面の真ん中に出す
    func showSettings() {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        if !window.isVisible, let screen = panel?.screen ?? Self.activeScreen() {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2,
                                          y: area.midY - window.frame.height / 2))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(windows: self)))
        window.title = "設定"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // メインウィンドウは常に手前に出るので、設定がその下に隠れないよう同じ高さにする。
        // 手前に浮いたまま残らないよう、よそのアプリに移ったら隠す
        window.level = .floating
        window.hidesOnDeactivate = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return window
    }

    private func makePanel() -> NSPanel {
        // ノンアクティベーティングのパネルにすると、フルスクリーンのアプリの上にもデスクトップを移らずに出せる
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .black
        panel.alphaValue = opacity
        panel.contentMinSize = NSSize(width: 760, height: 460)
        panel.contentView = NSHostingView(rootView: MainWindow(store: store, windows: self))
        if !panel.setFrameUsingName(Self.frameName) { panel.center() }
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    /// 別の画面にいたら、画面内での位置関係を保ったまま移す（はみ出す分は縮める）
    private func move(_ panel: NSPanel, to screen: NSScreen) {
        guard let current = panel.screen, current != screen else { return }
        let from = current.visibleFrame
        let to = screen.visibleFrame
        var frame = panel.frame
        frame.size.width = min(frame.width, to.width)
        frame.size.height = min(frame.height, to.height)
        // 余白のうち、左と下にどれだけ寄っていたかの割合で置く
        let rx = from.width > frame.width ? (frame.minX - from.minX) / (from.width - frame.width) : 0.5
        let ry = from.height > frame.height ? (frame.minY - from.minY) / (from.height - frame.height) : 0.5
        frame.origin.x = to.minX + (to.width - frame.width) * min(max(rx, 0), 1)
        frame.origin.y = to.minY + (to.height - frame.height) * min(max(ry, 0), 1)
        panel.setFrame(frame, display: false)
    }

    /// いま作業している画面。前面のアプリのいちばん手前のウィンドウがある画面を選び、
    /// ウィンドウが無ければ（デスクトップを触っている等）マウスのある画面にする。
    private static func activeScreen() -> NSScreen? {
        if NSApp.isActive, let screen = NSApp.keyWindow?.screen { return screen }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let bounds = frontWindowBounds(of: pid),
           let screen = screen(containing: CGPoint(x: bounds.midX, y: bounds.midY)) {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    /// そのアプリのいちばん手前の通常のウィンドウの位置（画面の座標系に直したもの）。
    /// 位置と持ち主は、画面収録の許可がなくても読める。
    private static func frontWindowBounds(of pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        // 手前から順に並んでいる
        for info in list {
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width > 40, rect.height > 40
            else { continue }
            // CoreGraphics は主画面の左上が原点で下向き。AppKit は左下が原点で上向き
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}
