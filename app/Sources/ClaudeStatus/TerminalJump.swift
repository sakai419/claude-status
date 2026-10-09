import AppKit

/// セッションが動いているターミナルを前面に出す。
/// cmux なら CLI でワークスペースとパネルまで選び、それ以外は起動元のアプリを前面に出すだけ。
enum TerminalJump {
    static let cmuxBundleID = "com.cmuxterm.app"

    static func canJump(_ s: Session) -> Bool {
        !s.terminalApp.isEmpty || !s.cmuxWorkspace.isEmpty
    }

    static func jump(_ s: Session) {
        let bundleID = s.terminalApp.isEmpty && !s.cmuxWorkspace.isEmpty ? cmuxBundleID : s.terminalApp
        let workspace = s.cmuxWorkspace
        let panel = s.cmuxPanel
        Task.detached {
            if !workspace.isEmpty, let cli = cmuxCLI() {
                let env = ["CMUX_QUIET": "1"]
                _ = try? Shell.run(cli, arguments: ["workspace", "select", "--workspace", workspace], environment: env)
                if !panel.isEmpty {
                    _ = try? Shell.run(cli, arguments: ["focus-panel", "--panel", panel, "--workspace", workspace], environment: env)
                }
            }
            await activate(bundleID: bundleID)
        }
    }

    private static func cmuxCLI() -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cmuxBundleID) else { return nil }
        let cli = app.appendingPathComponent("Contents/Resources/bin/cmux")
        return FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
    }

    @MainActor
    private static func activate(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            running.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
