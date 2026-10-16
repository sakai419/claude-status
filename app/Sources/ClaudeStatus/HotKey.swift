import AppKit
import Carbon.HIToolbox

/// グローバルショートカットに使うキーの組み合わせ。
/// 修飾キーは NSEvent のものを持ち、登録時に Carbon の形に直す。
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    /// 記録したときのキーの表示（"S"、"Space" など）
    var key: String

    /// 何も登録していないときに使う ⌥S
    static let defaultShortcut = KeyCombo(keyCode: UInt16(kVK_ANSI_S),
                                          modifiers: NSEvent.ModifierFlags.option.rawValue, key: "S")

    private var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// "⌃⌥⌘S" のような表示（修飾キーは macOS のメニューと同じ順に並べる）
    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    var carbonModifiers: UInt32 {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }
}

extension KeyCombo {
    /// 押されたキーから作る。修飾キーなしでは他のアプリの入力を奪ってしまうので、
    /// ⌘ ⌃ ⌥ のどれかを含むもの（F キーは単独でも可）だけを受け付ける。
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let isFunctionKey = Self.functionKeys[Int(event.keyCode)] != nil
        guard isFunctionKey || !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        keyCode = event.keyCode
        modifiers = flags.rawValue
        if let name = Self.namedKeys[Int(event.keyCode)] ?? Self.functionKeys[Int(event.keyCode)] {
            key = name
        } else if let chars = event.characters(byApplyingModifiers: []), !chars.isEmpty {
            key = chars.uppercased()
        } else {
            return nil
        }
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

/// アプリが前面になくても効くショートカット。
/// Carbon の RegisterEventHotKey は、アクセシビリティの許可なしで使える。
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// 'CSST'。他のアプリのホットキーと取り違えないための目印
    private static let signature: OSType = 0x4353_5354

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == GlobalHotKey.signature, let userData else { return OSStatus(eventNotHandledErr) }
            // Carbon のイベントはメインスレッドで届く
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// 登録し直す。nil なら外すだけ。他のアプリが使っている等で登録できなければ false。
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        guard let combo else { return true }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }
}
