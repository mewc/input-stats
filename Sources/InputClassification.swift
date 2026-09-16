import Foundation

// MARK: - Key composition

/// Coarse class of a pressed key, derived from the layout-independent virtual key code.
/// Only aggregate counts per class are ever stored — never which key, never the order.
enum KeyClass: CaseIterable {
    case letter, digit, space, enter, backspace, navigation, other

    var kind: EventKind {
        switch self {
        case .letter: return .keyLetter
        case .digit: return .keyDigit
        case .space: return .keySpace
        case .enter: return .keyEnter
        case .backspace: return .keyBackspace
        case .navigation: return .keyNavigation
        case .other: return .keyOther
        }
    }

    // macOS virtual key codes (Carbon kVK_*). Positions are ANSI; other layouts map to the same codes.
    private static let letterCodes: Set<Int> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
        31, 32, 34, 35, 37, 38, 40, 45, 46,
    ]
    private static let digitCodes: Set<Int> = [
        18, 19, 20, 21, 22, 23, 25, 26, 28, 29,          // top row 1-0
        82, 83, 84, 85, 86, 87, 88, 89, 91, 92,          // keypad 0-9
    ]
    private static let enterCodes: Set<Int> = [36, 76]   // Return, keypad Enter
    private static let backspaceCodes: Set<Int> = [51, 117]  // Delete, Forward Delete
    private static let navigationCodes: Set<Int> = [
        48,                       // Tab
        115, 116, 119, 121,       // Home, Page Up, End, Page Down
        123, 124, 125, 126,       // arrows
    ]

    static func classify(keyCode: Int) -> KeyClass {
        if letterCodes.contains(keyCode) { return .letter }
        if digitCodes.contains(keyCode) { return .digit }
        if keyCode == 49 { return .space }
        if enterCodes.contains(keyCode) { return .enter }
        if backspaceCodes.contains(keyCode) { return .backspace }
        if navigationCodes.contains(keyCode) { return .navigation }
        return .other
    }
}

// MARK: - Modifier presses

/// Detects modifier key *presses* from consecutive flagsChanged snapshots: a press is any
/// modifier bit that is set now and wasn't before. Releases (bits clearing) are ignored.
/// Caps Lock is excluded — it toggles, so only every other press would register.
struct ModifierPressDetector {
    /// Device-independent flag bits for Shift, Control, Option, Command and Fn (CGEventFlags raw values).
    static let trackedMask: UInt64 = 0x0002_0000 | 0x0004_0000 | 0x0008_0000 | 0x0010_0000 | 0x0080_0000

    private(set) var lastFlags: UInt64 = 0

    /// Feed the new flags; returns the number of modifiers that were just pressed.
    mutating func pressesOnUpdate(flags: UInt64) -> Int {
        let newlySet = (flags & ~lastFlags) & Self.trackedMask
        lastFlags = flags
        return newlySet.nonzeroBitCount
    }
}
