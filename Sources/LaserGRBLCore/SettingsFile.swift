import Foundation

/// The text file of Grbl settings (`$100=250.000`, one per line) that the configuration window exports and imports.
public enum GrblSettingsFile {
    /// The lines of `text` that are plain numbered settings, trimmed. Everything else is left out on purpose: a file the
    /// person got from somewhere must not be able to send `$RST=*` (erases the whole configuration), `$H`, `$J=…`, `$SLP`
    /// or ordinary G-code to the machine just because the line contains an equals sign.
    public static func settingLines(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^\$\d{1,3}=[0-9.+-]{1,24}$"#, options: .regularExpression) != nil }
    }

    /// The text written by the export: `$n=value` for every setting that is known, in order.
    public static func text(settings: [Int: String], keys: [Int]) -> String {
        keys.compactMap { k in settings[k].map { "$\(k)=\($0)" } }.joined(separator: "\n") + "\n"
    }
}
