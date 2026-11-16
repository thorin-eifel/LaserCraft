import Foundation

public struct KeyModifiers: OptionSet, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1)
    public static let option = KeyModifiers(rawValue: 2)
    public static let control = KeyModifiers(rawValue: 4)
    public static let shift = KeyModifiers(rawValue: 8)
}

/// A key with modifiers: `key` is "left", "right", "up", "down", "pageup", "pagedown", "return", "space"
/// or one lower-case character.
public struct KeyCombo: Codable, Hashable {
    public var key: String
    public var modifiers: KeyModifiers

    public init(_ key: String, _ modifiers: KeyModifiers = []) { self.key = key.lowercased(); self.modifiers = modifiers }

    /// Builds the combo of a key event. Shift only counts for letters and named keys: for "+" or "?" the character already says it.
    public static func make(characters: String, keyCode: UInt16, modifiers: KeyModifiers) -> KeyCombo? {
        let named: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 116: "pageup", 121: "pagedown", 36: "return", 49: "space", 51: "delete"]
        var mods = modifiers
        if let n = named[keyCode] { return KeyCombo(n, mods) }
        guard let c = characters.lowercased().first else { return nil }
        let ch = String(c)
        if !(c.isLetter || c.isNumber) { mods.remove(.shift) }
        return KeyCombo(ch, mods)
    }

    /// "⌃↑", "⌥←", "+", "[".
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let names = ["left": "←", "right": "→", "up": "↑", "down": "↓", "pageup": "⇞", "pagedown": "⇟", "return": "↩", "space": "␣", "delete": "⌫"]
        return s + (names[key] ?? key.uppercased())
    }
}

public enum HotkeyAction: String, Codable, CaseIterable, Hashable {
    case jogUp, jogDown, jogLeft, jogRight
    case jogUpLeft, jogUpRight, jogDownLeft, jogDownRight
    case bigUp, bigDown, bigLeft, bigRight
    case zUp, zDown
    case stepUp, stepDown, speedUp, speedDown
    case powerUp, powerDown
    case button1, button2, button3, button4, button5, button6, button7, button8, button9

    /// The nine custom buttons in order.
    public static let buttons: [HotkeyAction] = [.button1, .button2, .button3, .button4, .button5, .button6, .button7, .button8, .button9]
    public var buttonIndex: Int? { HotkeyAction.buttons.firstIndex(of: self) }

    /// English title (also the localisation key).
    public var title: String {
        switch self {
        case .jogUp: return "Jog up"
        case .jogDown: return "Jog down"
        case .jogLeft: return "Jog left"
        case .jogRight: return "Jog right"
        case .jogUpLeft: return "Jog up left"
        case .jogUpRight: return "Jog up right"
        case .jogDownLeft: return "Jog down left"
        case .jogDownRight: return "Jog down right"
        case .bigUp: return "Big step up"
        case .bigDown: return "Big step down"
        case .bigLeft: return "Big step left"
        case .bigRight: return "Big step right"
        case .zUp: return "Z axis up"
        case .zDown: return "Z axis down"
        case .stepUp: return "Larger jog step"
        case .stepDown: return "Smaller jog step"
        case .speedUp: return "Faster jog speed"
        case .speedDown: return "Slower jog speed"
        case .powerUp: return "Power override +10 %"
        case .powerDown: return "Power override −10 %"
        default: return "Custom button"
        }
    }

    /// Jog actions move the head; holding the key can jog continuously.
    public var isJog: Bool {
        switch self {
        case .jogUp, .jogDown, .jogLeft, .jogRight, .jogUpLeft, .jogUpRight, .jogDownLeft, .jogDownRight, .bigUp, .bigDown, .bigLeft, .bigRight, .zUp, .zDown: return true
        default: return false
        }
    }

    public var direction: JogDirection? {
        switch self {
        case .jogUp, .bigUp: return .n
        case .jogDown, .bigDown: return .s
        case .jogLeft, .bigLeft: return .w
        case .jogRight, .bigRight: return .e
        case .jogUpLeft: return .nw
        case .jogUpRight: return .ne
        case .jogDownLeft: return .sw
        case .jogDownRight: return .se
        case .zUp: return .zUp
        case .zDown: return .zDown
        default: return nil
        }
    }

    public var isBigStep: Bool { self == .bigUp || self == .bigDown || self == .bigLeft || self == .bigRight }
}

/// Which key does what. Keys are only used when no text field has the focus.
public struct HotkeyMap: Codable, Equatable {
    public private(set) var bindings: [HotkeyAction: KeyCombo]

    public static var defaults: HotkeyMap {
        var m: [HotkeyAction: KeyCombo] = [
            .jogUp: KeyCombo("up"), .jogDown: KeyCombo("down"), .jogLeft: KeyCombo("left"), .jogRight: KeyCombo("right"),
            .bigUp: KeyCombo("up", .option), .bigDown: KeyCombo("down", .option), .bigLeft: KeyCombo("left", .option), .bigRight: KeyCombo("right", .option),
            .zUp: KeyCombo("pageup"), .zDown: KeyCombo("pagedown"),
            .stepUp: KeyCombo("+"), .stepDown: KeyCombo("-"),
            .speedUp: KeyCombo("]"), .speedDown: KeyCombo("["),
            .powerUp: KeyCombo("up", .control), .powerDown: KeyCombo("down", .control),
        ]
        for (i, a) in HotkeyAction.buttons.enumerated() { m[a] = KeyCombo(String(i + 1), .control) }
        return HotkeyMap(bindings: m)
    }

    public init(bindings: [HotkeyAction: KeyCombo] = [:]) { self.bindings = bindings }

    public func combo(for a: HotkeyAction) -> KeyCombo? { bindings[a] }

    public func action(for combo: KeyCombo) -> HotkeyAction? {
        bindings.first { $0.value == combo }?.key
    }

    /// The other action that already uses this combo.
    public func conflict(for combo: KeyCombo, except a: HotkeyAction) -> HotkeyAction? {
        bindings.first { $0.key != a && $0.value == combo }?.key
    }

    /// Binds a combo; with `steal` the action that had it becomes unbound. Returns the action that was in the way.
    @discardableResult
    public mutating func set(_ combo: KeyCombo?, for a: HotkeyAction, steal: Bool = false) -> HotkeyAction? {
        guard let combo = combo else { bindings[a] = nil; return nil }
        let other = conflict(for: combo, except: a)
        if other != nil && !steal { return other }
        if let o = other { bindings[o] = nil }
        bindings[a] = combo
        return other
    }

    public mutating func reset() { self = .defaults }

    // JSON with plain string keys
    enum CodingKeys: String, CodingKey { case bindings }
    public init(from d: Decoder) throws {
        let raw = try d.container(keyedBy: CodingKeys.self).decode([String: KeyCombo].self, forKey: .bindings)
        var b: [HotkeyAction: KeyCombo] = [:]
        for (k, v) in raw { if let a = HotkeyAction(rawValue: k) { b[a] = v } }
        bindings = b
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) }), forKey: .bindings)
    }
}
