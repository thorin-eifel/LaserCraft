import Foundation

/// Localization helper. Keys are the English texts, so a missing translation simply shows English.
public enum Loc {
    /// Where translations are read from; the app bundle unless a test points it at a language folder.
    public static var bundle: Bundle = .main

    private static let missing = "\u{1}missing\u{1}"

    public static func tr(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// The translation for `key`, or nil when the current language has none.
    public static func optional(_ key: String) -> String? {
        let v = bundle.localizedString(forKey: key, value: missing, table: nil)
        return v == missing ? nil : v
    }
}

/// Localized, printf-style formatted text.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Loc.tr(key)
    return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
}

extension MachineState {
    /// Status name in the current language.
    public var localizedName: String { Loc.optional("state." + rawValue) ?? rawValue }
}
