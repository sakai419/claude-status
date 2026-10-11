import SwiftUI

@main
struct ClaudeStatusApp: App {
    @State private var store = SessionStore()

    var body: some Scene {
        Window("Claude Status", id: MainWindow.id) {
            MainWindow(store: store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)

        // メニューバーには件数だけ出し、クリックでウィンドウを呼び出せるようにする
        MenuBarExtra {
            StatusMenu(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// メニューバーのアイコン。手当てが要るもの（質問中）を最優先で数字付きで出す。
struct MenuBarLabel: View {
    let store: SessionStore

    var body: some View {
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("ウィンドウを開く") {
            openWindow(id: MainWindow.id)
            NSApp.activate()
        }
        .keyboardShortcut("o")
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
