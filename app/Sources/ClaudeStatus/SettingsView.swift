import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 設定ウィンドウ（⌘,）。ウィンドウを呼び出すショートカットと、ウィンドウの出し方。
struct SettingsView: View {
    @Bindable var windows: WindowManager

    var body: some View {
        Form {
            Section {
                LabeledContent("ウィンドウを呼び出す") {
                    ShortcutRecorder(windows: windows)
                }
                if windows.shortcutFailed {
                    Text("このショートカットは登録できませんでした。他のアプリが使っていないか確かめて、別の組み合わせにしてください。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("どのアプリを使っていても（フルスクリーンでも）、このキーでいま見ている画面の手前にウィンドウを出せます。前に出ているときに押すと引っ込みます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("よそをクリックしても引っ込めない", isOn: $windows.pinned)
                LabeledContent("不透明度") {
                    HStack {
                        Slider(value: $windows.opacity, in: 0.3...1)
                        Text("\(Int((windows.opacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } footer: {
                Text("ウィンドウは他のウィンドウより常に手前に出ます。固定は一覧の右上のピンでも切り替えられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}

/// クリックしてから押したキーを、ショートカットとして記録する。
/// Esc でやめ、⌫ で消す。
private struct ShortcutRecorder: View {
    let windows: WindowManager
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { recording ? stop() : start() }) {
                Text(label)
                    .monospaced(windows.shortcut != nil && !recording)
                    .frame(minWidth: 130)
            }
            .foregroundStyle(recording ? Color.accentColor : .primary)
            if windows.shortcut != nil, !recording {
                Button {
                    windows.shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("ショートカットを消す")
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording { return hint ?? "キーを押してください…" }
        return windows.shortcut?.display ?? "クリックして記録"
    }

    private func start() {
        recording = true
        hint = nil
        windows.suspendShortcut(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.isEmpty, Int(event.keyCode) == kVK_Escape {
            stop()
        } else if mods.isEmpty, Int(event.keyCode) == kVK_Delete {
            windows.shortcut = nil
            stop()
        } else if let combo = KeyCombo(event: event) {
            windows.shortcut = combo
            stop()
        } else {
            hint = "⌘ ⌃ ⌥ のどれかと一緒に押してください"
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        hint = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windows.suspendShortcut(false)
    }
}
