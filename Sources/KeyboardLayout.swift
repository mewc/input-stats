import Foundation
import Carbon.HIToolbox
import Cocoa

/// Tracks the active keyboard input source and can translate key codes into the characters they
/// produce *on that layout*, so the heatmap reads correctly on AZERTY/Dvorak/etc. rather than
/// assuming ANSI US.
final class KeyboardLayoutTracker {
    static let shared = KeyboardLayoutTracker()

    private(set) var current: LayoutKey = LayoutKey(id: "unknown", name: "Unknown")
    /// Cleared whenever the input source changes, so labels follow the active layout.
    private var labelCache: [Int: String] = [:]

    private init() {
        refresh()
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        current = LayoutKey(id: Self.string(source, kTISPropertyInputSourceID) ?? "unknown",
                            name: Self.localizedName(source))
        labelCache.removeAll(keepingCapacity: true)
    }

    /// The character a key produces with no modifiers ("a", "7", ","), or a symbolic name for keys
    /// that produce none ("⏎", "⇥"). Cached per key code for the active layout.
    func label(for keyCode: Int) -> String {
        if let cached = labelCache[keyCode] { return cached }
        let label = Self.symbolicNames[keyCode] ?? Self.translate(keyCode: keyCode) ?? ""
        labelCache[keyCode] = label
        return label
    }

    private static func string(_ source: TISInputSource, _ key: CFString!) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private static func localizedName(_ source: TISInputSource) -> String {
        string(source, kTISPropertyLocalizedName) ?? "Unknown"
    }

    /// Ask the active layout what an unmodified press of `keyCode` produces.
    private static func translate(keyCode: Int) -> String? {
        // The *keyboard* layout source: the current source can be an input method (e.g. Pinyin)
        // that carries no layout data, in which case ASCII-capable is the right fallback.
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source,
              let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout,
                                  UInt16(keyCode),
                                  UInt16(kUCKeyActionDisplay),
                                  0,                      // no modifiers
                                  UInt32(LMGetKbdType()),
                                  UInt32(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState,
                                  chars.count,
                                  &length,
                                  &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    /// Keys that produce no character — labelled with their glyph instead.
    private static let symbolicNames: [Int: String] = [
        kVK_Return: "⏎", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "space",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "esc",
        kVK_Command: "⌘", kVK_RightCommand: "⌘", kVK_Shift: "⇧", kVK_RightShift: "⇧",
        kVK_Option: "⌥", kVK_RightOption: "⌥", kVK_Control: "⌃", kVK_RightControl: "⌃",
        kVK_CapsLock: "⇪", kVK_Function: "fn",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// The physical key grid the heatmap draws: rows of (key code, relative width).
/// ANSI positions — the *labels* come from the active layout, so a non-US layout shows its own
/// characters in these positions, which is exactly how the physical keyboard looks.
enum KeyboardGrid {
    struct Key {
        let code: Int
        let width: Double
    }

    static let rows: [[Key]] = [
        [k(kVK_Escape, 1.4), k(kVK_F1), k(kVK_F2), k(kVK_F3), k(kVK_F4), k(kVK_F5), k(kVK_F6),
         k(kVK_F7), k(kVK_F8), k(kVK_F9), k(kVK_F10), k(kVK_F11), k(kVK_F12)],
        [k(kVK_ANSI_Grave), k(kVK_ANSI_1), k(kVK_ANSI_2), k(kVK_ANSI_3), k(kVK_ANSI_4), k(kVK_ANSI_5),
         k(kVK_ANSI_6), k(kVK_ANSI_7), k(kVK_ANSI_8), k(kVK_ANSI_9), k(kVK_ANSI_0),
         k(kVK_ANSI_Minus), k(kVK_ANSI_Equal), k(kVK_Delete, 1.8)],
        [k(kVK_Tab, 1.5), k(kVK_ANSI_Q), k(kVK_ANSI_W), k(kVK_ANSI_E), k(kVK_ANSI_R), k(kVK_ANSI_T),
         k(kVK_ANSI_Y), k(kVK_ANSI_U), k(kVK_ANSI_I), k(kVK_ANSI_O), k(kVK_ANSI_P),
         k(kVK_ANSI_LeftBracket), k(kVK_ANSI_RightBracket), k(kVK_ANSI_Backslash, 1.3)],
        [k(kVK_CapsLock, 1.8), k(kVK_ANSI_A), k(kVK_ANSI_S), k(kVK_ANSI_D), k(kVK_ANSI_F), k(kVK_ANSI_G),
         k(kVK_ANSI_H), k(kVK_ANSI_J), k(kVK_ANSI_K), k(kVK_ANSI_L), k(kVK_ANSI_Semicolon),
         k(kVK_ANSI_Quote), k(kVK_Return, 2.0)],
        [k(kVK_Shift, 2.3), k(kVK_ANSI_Z), k(kVK_ANSI_X), k(kVK_ANSI_C), k(kVK_ANSI_V), k(kVK_ANSI_B),
         k(kVK_ANSI_N), k(kVK_ANSI_M), k(kVK_ANSI_Comma), k(kVK_ANSI_Period), k(kVK_ANSI_Slash),
         k(kVK_RightShift, 2.3)],
        [k(kVK_Function, 1.2), k(kVK_Control, 1.2), k(kVK_Option, 1.2), k(kVK_Command, 1.4),
         k(kVK_Space, 5.5), k(kVK_RightCommand, 1.4), k(kVK_RightOption, 1.2),
         k(kVK_LeftArrow), k(kVK_UpArrow), k(kVK_DownArrow), k(kVK_RightArrow)],
    ]

    private static func k(_ code: Int, _ width: Double = 1.0) -> Key { Key(code: code, width: width) }
}
