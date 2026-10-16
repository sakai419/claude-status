import SwiftUI

@main
struct ClaudeStatusApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        // メインウィンドウと設定は AppKit のウィンドウ（WindowManager）。メニューバーには件数だけ出す
        MenuBarExtra {
            StatusMenu(store: app.store, windows: app.windows)
        } label: {
            MenuBarLabel(store: app.store)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("設定…") { app.windows.showSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: SessionStore
    let windows: WindowManager

    override init() {
        store = SessionStore()
        windows = WindowManager(store: store)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        windows.show()
    }

    /// Dock のアイコンを押したとき
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.show()
        return false
    }
}

/// メニューバーのアイコン。手当てが要るもの（質問中）を最優先で数字付きで出す。
struct MenuBarLabel: View {
    let store: SessionStore

    var body: some View {
        let waiting = store.count(.waiting)
        let active = store.count(.running) + store.count(.subagent) + store.count(.watching)
        if waiting > 0 {
            Label("\(waiting)", systemImage: "exclamationmark.bubble.fill")
                .labelStyle(.titleAndIcon)
        } else if active > 0 {
            Label("\(active)", systemImage: "ellipsis.bubble.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "bubble.left")
        }
    }
}

struct StatusMenu: View {
    let store: SessionStore
    let windows: WindowManager

    var body: some View {
        Button("ウィンドウを開く") { windows.show() }
            .keyboardShortcut("o")
        Button("設定…") { windows.showSettings() }
            .keyboardShortcut(",")
        Divider()
        if store.sessions.isEmpty {
            Text("動いているセッションはありません")
        } else {
            ForEach(store.grouped, id: \.group) { entry in
                Text("\(entry.group.title)  \(entry.sessions.count)")
            }
        }
        Divider()
        Button("終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
