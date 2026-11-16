import Foundation

public enum LineEnding: String, Codable, CaseIterable {
    case lf, crlf
    public var text: String { self == .lf ? "\n" : "\r\n" }
}

/// What *Save G-code* writes.
public struct SaveOptions: Codable, Equatable {
    public var includeHeader = true
    public var includeFooter = true
    public var passes = 1
    public var lineEnding: LineEnding = .lf
    public init() {}
}

public enum GCodeExporter {
    /// The file contents: header, the program repeated `passes` times, footer.
    public static func text(program: GCodeProgram, header: String, footer: String, options o: SaveOptions) -> String {
        var lines: [String] = []
        if o.includeHeader { lines += header.split(whereSeparator: \.isNewline).map(String.init) }
        for _ in 0..<max(1, o.passes) { lines += program.commands }
        if o.includeFooter { lines += footer.split(whereSeparator: \.isNewline).map(String.init) }
        return lines.joined(separator: o.lineEnding.text) + o.lineEnding.text
    }
}

/// Which console lines are shown.
public struct ConsoleFilter: Equatable {
    public var sent = true, received = true, info = true, errors = true
    public var search = ""
    public init() {}

    public var isActive: Bool { !(sent && received && info && errors) || !search.isEmpty }

    public func matches(_ line: ConsoleLine) -> Bool {
        switch line.kind {
        case .sent: guard sent else { return false }
        case .received: guard received else { return false }
        case .info: guard info else { return false }
        case .error: guard errors else { return false }
        }
        return search.isEmpty || line.text.localizedCaseInsensitiveContains(search)
    }

    public func apply(_ lines: [ConsoleLine]) -> [ConsoleLine] { isActive ? lines.filter(matches) : lines }
}
