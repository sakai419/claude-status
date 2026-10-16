import SwiftUI

@main
struct ClaudeStatusApp: App {
    @State private var store = SessionStore()
    @State private var windows = WindowManager()

    var body: some Scene {
        Window("Claude Status", id: MainWindow.id) {
            MainWindow(store: store, windows: windows)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)

        // メニューバーには件数だけ出し、クリックでウィンドウを呼び出せるようにする
        MenuBarExtra {
            StatusMenu(store: store, windows: windows)
        } label: {
            MenuBarLabel(store: store, windows: windows)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(windows: windows)
        }
    }
}

/// メニューバーのアイコン。手当てが要るもの（質問中）を最優先で数字付きで出す。
/// メニューバーは常に出ているので、ウィンドウを閉じた後でも開き直せるよう、ここから開く手段を渡す。
struct MenuBarLabel: View {
    let store: SessionStore
    let windows: WindowManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        icon.onAppear { windows.setOpenWindow(openWindow) }
    }

    @ViewBuilder
    private var icon: some View {
        let waiting = store.count(.waiting)
        let active = store.count(.running) + store.count(.subagent)
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
    @Bindable var windows: WindowManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("ウィンドウを開く") { windows.show() }
            .keyboardShortcut("o")
        Toggle("オーバーレイで表示", isOn: $windows.overlay)
        Button("設定…") {
            openSettings()
            NSApp.activate()
        }
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
