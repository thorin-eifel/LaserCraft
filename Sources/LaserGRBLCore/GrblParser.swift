import Foundation

public enum MachineState: String, CaseIterable {
    case disconnected = "Disconnected", connecting = "Connecting"
    case idle = "Idle", run = "Run", hold = "Hold", door = "Door", home = "Home"
    case alarm = "Alarm", check = "Check", jog = "Jog", sleep = "Sleep", tool = "Tool"
    case cooling = "Cooling", autoHold = "AutoHold"
}

public struct Point3: Equatable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) { self.x = x; self.y = y; self.z = z }
    public static func - (a: Point3, b: Point3) -> Point3 { Point3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func + (a: Point3, b: Point3) -> Point3 { Point3(a.x + b.x, a.y + b.y, a.z + b.z) }
}

/// Everything that can be read out of one real-time status report ("<Idle|MPos:...>").
public struct StatusReport {
    public var state: MachineState = .idle
    public var subState: Int?
    public var mpos: Point3?
    public var wpos: Point3?
    public var wco: Point3?
    public var overrides: (feed: Int, rapid: Int, spindle: Int)?
    public var buffer: (blocks: Int, bytes: Int)?
    public var feed: Double?
    public var spindle: Double?
}

public struct GrblVersion: Comparable, CustomStringConvertible {
    public var major: Int, minor: Int, build: Character
    public init(major: Int, minor: Int, build: Character = " ") { self.major = major; self.minor = minor; self.build = build }
    public static func < (a: GrblVersion, b: GrblVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        return (a.build.asciiValue ?? 0) < (b.build.asciiValue ?? 0)
    }
    public static func == (a: GrblVersion, b: GrblVersion) -> Bool {
        a.major == b.major && a.minor == b.minor && a.build == b.build
    }
    public var description: String { "\(major).\(minor)\(build == " " ? "" : String(build))" }
}

public enum GrblMessage: Equatable {
    case ok
    case error(Int)
    case alarm(Int)
    case welcome(String)           // "Grbl 1.1h ['$' for help]"
    case status(String)            // raw "<...>" including brackets
    case setting(Int, String)      // "$30=1000"
    case info(String)              // "[MSG:...]", "[VER:..]", "[OPT:..]", other bracketed lines
    case other(String)
}

public enum GrblParser {
    public static func classify(_ rawLine: String) -> GrblMessage {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line == "ok" { return .ok }
        if line.hasPrefix("error:"), let n = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) { return .error(n) }
        if line.hasPrefix("ALARM:"), let n = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) { return .alarm(n) }
        if line.hasPrefix("<") && line.hasSuffix(">") { return .status(line) }
        if line.hasPrefix("Grbl ") { return .welcome(line) }
        if line.hasPrefix("$"), let eq = line.firstIndex(of: "="),
           let n = Int(line[line.index(after: line.startIndex)..<eq]) {
            return .setting(n, String(line[line.index(after: eq)...]))
        }
        if line.hasPrefix("[") { return .info(line) }
        return .other(line)
    }

    /// "Grbl 1.1h ['$' for help]" -> 1.1h
    public static func parseWelcome(_ line: String) -> GrblVersion? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "Grbl" else { return nil }
        let v = Array(parts[1])
        guard v.count >= 3, let maj = Int(String(v[0])), v[1] == ".", let min = Int(String(v[2])) else { return nil }
        return GrblVersion(major: maj, minor: min, build: v.count > 3 ? v[3] : " ")
    }

    private static func triple(_ s: Substring) -> Point3? {
        let n = s.split(separator: ",").compactMap { Double($0) }
        guard n.count >= 2 else { return nil }
        return Point3(n[0], n[1], n.count > 2 ? n[2] : 0)
    }

    public static func parseStatus(_ raw: String) -> StatusReport? {
        guard raw.hasPrefix("<"), raw.hasSuffix(">") else { return nil }
        let body = String(raw.dropFirst().dropLast())
        var r = StatusReport()

        func parseState(_ s: String) -> Bool {
            var name = s
            if let c = s.firstIndex(of: ":") {
                r.subState = Int(s[s.index(after: c)...])
                name = String(s[..<c])
            }
            guard let st = MachineState(rawValue: name) else { return false }
            r.state = st
            return true
        }

        if body.contains("|") {   // Grbl >= 1.1
            let fields = body.split(separator: "|", omittingEmptySubsequences: true).map(String.init)
            guard let first = fields.first, parseState(first) else { return nil }
            for f in fields.dropFirst() {
                guard let c = f.firstIndex(of: ":") else { continue }
                let key = f[..<c], val = f[f.index(after: c)...]
                switch key {
                case "MPos": r.mpos = triple(val)
                case "WPos": r.wpos = triple(val)
                case "WCO": r.wco = triple(val)
                case "Ov":
                    let n = val.split(separator: ",").compactMap { Int($0) }
                    if n.count == 3 { r.overrides = (n[0], n[1], n[2]) }
                case "Bf":
                    let n = val.split(separator: ",").compactMap { Int($0) }
                    if n.count == 2 { r.buffer = (n[0], n[1]) }
                case "FS":
                    let n = val.split(separator: ",").compactMap { Double($0) }
                    if n.count >= 1 { r.feed = n[0] }
                    if n.count >= 2 { r.spindle = n[1] }
                case "F":
                    r.feed = Double(val)
                default: break
                }
            }
            return r
        } else {                  // Grbl 0.9: <Idle,MPos:0.000,0.000,0.000,WPos:0.000,0.000,0.000>
            let parts = body.split(separator: ",").map(String.init)
            guard let first = parts.first, parseState(first) else { return nil }
            if parts.count >= 4, parts[1].hasPrefix("MPos:"),
               let x = Double(parts[1].dropFirst(5)), let y = Double(parts[2]), let z = Double(parts[3]) {
                r.mpos = Point3(x, y, z)
            }
            if parts.count >= 7, parts[4].hasPrefix("WPos:"),
               let x = Double(parts[4].dropFirst(5)), let y = Double(parts[5]), let z = Double(parts[6]) {
                r.wpos = Point3(x, y, z)
            }
            return r
        }
    }

    public static func describeError(_ n: Int) -> String {
        guard let e = CodeTables.errors[n] else { return "error:\(n)" }
        let title = Loc.optional("grbl.error.\(n).title") ?? e.title
        let detail = Loc.optional("grbl.error.\(n).detail") ?? e.detail
        return "error:\(n) \(title) — \(detail)"
    }

    public static func describeAlarm(_ n: Int) -> String {
        guard let a = CodeTables.alarms[n] else { return "ALARM:\(n)" }
        let title = Loc.optional("grbl.alarm.\(n).title") ?? a.title
        let detail = Loc.optional("grbl.alarm.\(n).detail") ?? a.detail
        return "ALARM:\(n) \(title) — \(detail)"
    }

    /// Name, units and description of a `$` setting in the current language.
    public static func describeSetting(_ n: Int) -> (name: String, units: String, detail: String)? {
        guard let s = CodeTables.settings[n] else { return nil }
        return (Loc.optional("grbl.setting.\(n).name") ?? s.name,
                Loc.optional("grbl.unit.\(s.units)") ?? s.units,
                Loc.optional("grbl.setting.\(n).detail") ?? s.detail)
    }

    /// Strips comments and whitespace the way Grbl expects before sending.
    public static func cleanLine(_ line: String) -> String {
        var out = ""
        var depth = 0
        for ch in line {
            if ch == ";" && depth == 0 { break }
            if ch == "(" { depth += 1; continue }
            if ch == ")" { if depth > 0 { depth -= 1 }; continue }
            if depth == 0 && ch != " " && ch != "\t" && ch != "\r" && ch != "\n" { out.append(ch) }
        }
        return out
    }
}
