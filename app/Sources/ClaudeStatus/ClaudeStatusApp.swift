import SwiftUI

@main
struct ClaudeStatusApp: App {
    @State private var store = SessionStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
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
