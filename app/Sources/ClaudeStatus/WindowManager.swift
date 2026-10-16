import AppKit
import Observation
import SwiftUI

/// メインウィンドウの出し入れと表示のしかた（ショートカットでの呼び出し・オーバーレイ表示）を受け持つ。
/// 設定は UserDefaults に残し、次の起動でも同じにする。
@MainActor
@Observable
final class WindowManager {
    /// ウィンドウを呼び出すショートカット。nil なら使わない。
    var shortcut: KeyCombo? {
        didSet {
            UserDefaults.standard.set(shortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.shortcutKey)
            registerShortcut()
        }
    }
    /// 登録できなかったとき（他のアプリが使っている等）に true
    private(set) var shortcutFailed = false

    /// 他のウィンドウより手前に出し続け、どのデスクトップ（フルスクリーンのアプリの上も含む）にも出す
    var overlay: Bool {
        didSet {
            UserDefaults.standard.set(overlay, forKey: Self.overlayKey)
            apply()
        }
    }
    /// オーバーレイ中のウィンドウの不透明度
    var overlayOpacity: Double {
        didSet {
            UserDefaults.standard.set(overlayOpacity, forKey: Self.opacityKey)
            apply()
        }
    }

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private weak var settingsWindow: NSWindow?
    @ObservationIgnored private var openWindow: OpenWindowAction?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?

    private static let shortcutKey = "windowShortcut"
    private static let overlayKey = "overlay"
    private static let opacityKey = "overlayOpacity"

    init() {
        let defaults = UserDefaults.standard
        shortcut = defaults.data(forKey: Self.shortcutKey).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
        overlay = defaults.bool(forKey: Self.overlayKey)
        overlayOpacity = defaults.object(forKey: Self.opacityKey) as? Double ?? 0.9
        hotKey = GlobalHotKey { [weak self] in self?.toggle() }
        registerShortcut()
    }

    /// ショートカットを記録している間は、いまのショートカットを外しておく（押しても呼び出しが起きないように）
    func suspendShortcut(_ suspended: Bool) {
        if suspended { hotKey?.register(nil) } else { registerShortcut() }
    }

    private func registerShortcut() {
        shortcutFailed = !(hotKey?.register(shortcut) ?? true)
    }

    /// 閉じたウィンドウを開き直すための手段。SwiftUI の環境からしか取れないので、ビューから渡してもらう。
    func setOpenWindow(_ action: OpenWindowAction) {
        openWindow = action
    }

    /// メインウィンドウができたら呼ぶ。閉じたら手放し、次は開き直す。
    func attach(_ window: NSWindow) {
        guard window !== self.window else { return }
        self.window = window
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.window = nil }
        }
        apply()
    }

    /// 設定ウィンドウができたら呼ぶ。オーバーレイ中のメインウィンドウの下に隠れないよう、同じ高さに出す。
    func attachSettings(_ window: NSWindow) {
        settingsWindow = window
        window.level = overlay ? .floating : .normal
    }

    /// ショートカットで呼ばれる。前面で使っている最中なら引っ込め、そうでなければ呼び出す。
    func toggle() {
        if let window, window.isVisible, window.isKeyWindow, NSApp.isActive {
            NSApp.hide(nil)
        } else {
            show()
        }
    }

    func show() {
        NSApp.unhide(nil)
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: MainWindow.id)
        }
        NSApp.activate()
    }

    private func apply() {
        applyToMain()
        // メインウィンドウの後で上げ、設定を開いたまま切り替えても設定が上に残るようにする
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.level = overlay ? .floating : .normal
            settingsWindow.orderFront(nil)
        }
    }

    private func applyToMain() {
        guard let window else { return }
        window.level = overlay ? .floating : .normal
        window.alphaValue = overlay ? overlayOpacity : 1
        // ふだんは呼び出したデスクトップへウィンドウを連れてくる。
        // オーバーレイ中はすべてのデスクトップとフルスクリーンのアプリの上に出す。
        var behavior = window.collectionBehavior
        behavior.remove([.moveToActiveSpace, .canJoinAllSpaces, .fullScreenAuxiliary])
        behavior.insert(overlay ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace])
        window.collectionBehavior = behavior
    }
}

/// ビューが載っている NSWindow を取り出す
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}
