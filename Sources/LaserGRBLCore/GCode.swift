import Foundation

/// One straight piece of tool path, in millimetres.
public struct PathSegment {
    public var x0: Float, y0: Float, x1: Float, y1: Float
    /// Laser power requested by S (raw value); 0 means travel without burning.
    public var power: Float
    /// Index into `GCodeProgram.commands` of the line that produced it.
    public var command: Int32
}

public struct Bounds {
    public var minX = Double.infinity, minY = Double.infinity
    public var maxX = -Double.infinity, maxY = -Double.infinity
    public var isEmpty: Bool { minX > maxX }
    public var width: Double { isEmpty ? 0 : maxX - minX }
    public var height: Double { isEmpty ? 0 : maxY - minY }
    public init() {}
    public mutating func add(_ x: Double, _ y: Double) {
        minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
        minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
    }
}

/// A loaded G-code job: the lines to send, the path to preview and a time estimate.
public final class GCodeProgram {
    /// Lines ready to send (comments/whitespace removed, empty lines dropped).
    public private(set) var commands: [String] = []
    public private(set) var segments: [PathSegment] = []
    public private(set) var burnBounds = Bounds()
    public private(set) var travelBounds = Bounds()
    public private(set) var maxPower: Float = 0
    /// Highest feed rate (mm/min) used by a cutting move, and whether the job uses M3 / M4.
    public private(set) var maxFeed: Double = 0
    public private(set) var usesM3 = false
    public private(set) var usesM4 = false
    public private(set) var estimatedSeconds: Double = 0
    /// Cumulative estimated seconds at the end of each command (for progress / time left).
    public private(set) var cumulativeSeconds: [Float] = []
    public private(set) var burnLength: Double = 0
    /// Seconds with the laser on (estimate) and the same weighted by power (S), per command, cumulative.
    public private(set) var cumulativeBurnSeconds: [Float] = []
    public private(set) var cumulativeBurnPowerSeconds: [Double] = []
    public var burnSeconds: Double { Double(cumulativeBurnSeconds.last ?? 0) }
    /// Sum of seconds × S over the whole job; divide by the machine's S maximum for "full power equivalent" seconds.
    public var burnPowerSeconds: Double { cumulativeBurnPowerSeconds.last ?? 0 }
    public var name: String

    public init(text: String, name: String = "Untitled", rapidRate: Double = 2000) {
        self.name = name
        parse(text, rapidRate: rapidRate)
    }

    public convenience init(contentsOf url: URL, rapidRate: Double = 2000) throws {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        self.init(text: text, name: url.lastPathComponent, rapidRate: rapidRate)
    }

    public var isEmpty: Bool { commands.isEmpty }

    public var text: String { commands.joined(separator: "\n") }

    // MARK: parsing

    struct Word { var letter: Character; var value: Double }

    static func words(of line: String) -> [Word] {
        var out: [Word] = []
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            i = line.index(after: i)
            guard ch.isLetter else { continue }
            var j = i
            while j < line.endIndex, "+-.0123456789".contains(line[j]) { j = line.index(after: j) }
            if let v = Double(line[i..<j]) { out.append(Word(letter: Character(ch.uppercased()), value: v)) }
            i = j
        }
        return out
    }

    private func parse(_ text: String, rapidRate: Double) {
        var x = 0.0, y = 0.0
        var absolute = true
        var inches = false
        var motion = 0            // 0 rapid, 1 feed, 2 cw arc, 3 ccw arc
        var feed = 1000.0
        var s = 0.0
        var laserOn = false
        var seconds = 0.0, burnSec = 0.0, burnPS = 0.0

        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let clean = GrblParser.cleanLine(String(raw))
            if clean.isEmpty { continue }
            let index = Int32(commands.count)
            commands.append(clean)

            let ws = GCodeProgram.words(of: clean.uppercased())
            var nx: Double?, ny: Double?, ni = 0.0, nj = 0.0, nr: Double?
            var dwell: Double?
            var moved = false
            for w in ws {
                switch w.letter {
                case "G":
                    switch Int(w.value) {
                    case 0: motion = 0
                    case 1: motion = 1
                    case 2: motion = 2
                    case 3: motion = 3
                    case 4: break
                    case 20: inches = true
                    case 21: inches = false
                    case 90: absolute = true
                    case 91: absolute = false
                    default: break
                    }
                    if Int(w.value) == 4 { dwell = 0 }
                case "M":
                    switch Int(w.value) {
                    case 3: laserOn = true; usesM3 = true
                    case 4: laserOn = true; usesM4 = true
                    case 5: laserOn = false
                    default: break
                    }
                case "X": nx = w.value
                case "Y": ny = w.value
                case "I": ni = w.value
                case "J": nj = w.value
                case "R": nr = w.value
                case "F": feed = w.value * (inches ? 25.4 : 1)
                case "S": s = w.value
                case "P": if dwell != nil { dwell = w.value }
                default: break
                }
            }
            if let d = dwell { seconds += d }
            let k = inches ? 25.4 : 1.0
            if nx != nil || ny != nil { moved = true }
            if moved {
                let tx = nx.map { absolute ? $0 * k : x + $0 * k } ?? x
                let ty = ny.map { absolute ? $0 * k : y + $0 * k } ?? y
                let burning = motion != 0 && laserOn && s > 0
                let power = burning ? Float(s) : 0
                var length = 0.0
                if motion >= 2 {
                    let pts = GCodeProgram.arc(from: (x, y), to: (tx, ty), i: ni * k, j: nj * k, r: nr.map { $0 * k },
                                               clockwise: motion == 2)
                    var px = x, py = y
                    for p in pts {
                        add(px, py, p.0, p.1, power, index)
                        length += hypot(p.0 - px, p.1 - py)
                        px = p.0; py = p.1
                    }
                } else {
                    add(x, y, tx, ty, power, index)
                    length = hypot(tx - x, ty - y)
                }
                if burning { burnLength += length }
                let rate = motion == 0 ? rapidRate : max(feed, 1)
                if motion != 0 { maxFeed = Swift.max(maxFeed, feed) }
                seconds += length / rate * 60
                if burning { burnSec += length / rate * 60; burnPS += length / rate * 60 * s }
                x = tx; y = ty
            }
            cumulativeSeconds.append(Float(seconds))
            cumulativeBurnSeconds.append(Float(burnSec))
            cumulativeBurnPowerSeconds.append(burnPS)
        }
        estimatedSeconds = seconds
        if travelBounds.isEmpty { travelBounds.add(0, 0) }
    }

    private func add(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ power: Float, _ cmd: Int32) {
        if x0 == x1 && y0 == y1 { return }
        segments.append(PathSegment(x0: Float(x0), y0: Float(y0), x1: Float(x1), y1: Float(y1), power: power, command: cmd))
        travelBounds.add(x0, y0); travelBounds.add(x1, y1)
        if power > 0 {
            burnBounds.add(x0, y0); burnBounds.add(x1, y1)
            maxPower = Swift.max(maxPower, power)
        }
    }

    /// Flattens an arc into short chords.
    static func arc(from a: (Double, Double), to b: (Double, Double), i: Double, j: Double, r: Double?, clockwise: Bool) -> [(Double, Double)] {
        var cx = a.0 + i, cy = a.1 + j
        if let r = r, i == 0 && j == 0 {
            let dx = b.0 - a.0, dy = b.1 - a.1
            let d = hypot(dx, dy)
            if d == 0 { return [] }
            let h = sqrt(Swift.max(r * r - d * d / 4, 0)) * (clockwise == (r < 0) ? 1 : -1)
            cx = a.0 + dx / 2 + h * (-dy / d)
            cy = a.1 + dy / 2 + h * (dx / d)
        }
        let radius = hypot(a.0 - cx, a.1 - cy)
        if radius == 0 { return [b] }
        let a0 = atan2(a.1 - cy, a.0 - cx)
        var a1 = atan2(b.1 - cy, b.0 - cx)
        var sweep = a1 - a0
        if clockwise { if sweep >= 0 { sweep -= 2 * .pi } } else { if sweep <= 0 { sweep += 2 * .pi } }
        if a.0 == b.0 && a.1 == b.1 && (i != 0 || j != 0) { sweep = clockwise ? -2 * .pi : 2 * .pi }
        a1 = a0 + sweep
        let steps = Swift.max(2, Int(abs(sweep) * radius / 0.5), Int(abs(sweep) / (.pi / 36)))
        var pts: [(Double, Double)] = []
        for n in 1...steps {
            let t = a0 + sweep * Double(n) / Double(steps)
            pts.append((cx + radius * cos(t), cy + radius * sin(t)))
        }
        pts[pts.count - 1] = b
        return pts
    }

    // MARK: resuming in the middle of a job

    /// The machine state a job leaves behind after its first `index` lines (positions in mm).
    public struct ResumeState: Equatable {
        public var x = 0.0, y = 0.0
        public var feed = 1000.0
        public var power = 0.0
        public var absolute = true
        public var inches = false
        public var motion = 0                 // 0 rapid, 1 linear (arcs count as linear)
        public var laser: Int?                // 3, 4 or nil when the laser is off
    }

    /// Replays the first `index` lines (modal state only, nothing is sent anywhere).
    public func resumeState(before index: Int) -> ResumeState {
        var st = ResumeState()
        for command in commands.prefix(max(0, index)) {
            var nx: Double?, ny: Double?
            for w in GCodeProgram.words(of: command.uppercased()) {
                switch w.letter {
                case "G":
                    switch Int(w.value) {
                    case 0: st.motion = 0
                    case 1, 2, 3: st.motion = 1
                    case 20: st.inches = true
                    case 21: st.inches = false
                    case 90: st.absolute = true
                    case 91: st.absolute = false
                    default: break
                    }
                case "M":
                    switch Int(w.value) {
                    case 3: st.laser = 3
                    case 4: st.laser = 4
                    case 5: st.laser = nil
                    default: break
                    }
                case "F": st.feed = w.value * (st.inches ? 25.4 : 1)
                case "S": st.power = w.value
                case "X": nx = w.value
                case "Y": ny = w.value
                default: break
                }
            }
            let k = st.inches ? 25.4 : 1.0
            if let v = nx { st.x = st.absolute ? v * k : st.x + v * k }
            if let v = ny { st.y = st.absolute ? v * k : st.y + v * k }
        }
        return st
    }

    /// Lines to send before `commands[index...]` so the job can continue there: laser off, go to where the
    /// previous line ended, then restore feed rate, units, motion mode, distance mode and the laser state.
    public func resumeCommands(from index: Int) -> [String] {
        guard index > 0, index < commands.count else { return [] }
        let st = resumeState(before: index)
        var out = ["M5", "G90", "G21", String(format: "G0 X%.3f Y%.3f", st.x, st.y), String(format: "F%.0f", st.feed)]
        if st.motion == 1 { out.append("G1") }
        if st.inches { out.append("G20") }
        if !st.absolute { out.append("G91") }
        if let m = st.laser { out.append("M\(m) S\(Int(st.power))") }
        else if st.power > 0 { out.append("S\(Int(st.power))") }
        return out
    }

    public static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}
