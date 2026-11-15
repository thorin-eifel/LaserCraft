import Foundation

// MARK: - Path optimisation

public struct PathOptimizeOptions: Codable, Equatable {
    /// Re-order the shapes so that the laser travels less between them (nearest neighbour, then 2-opt).
    public var reorder = true
    /// Closed shapes inside other closed shapes are processed first (so that cut-out pieces fall out last).
    public var insideFirst = true
    /// Closed shapes may start at any of their points, open ones may be run in either direction.
    public var flexibleStart = true
    public init() {}
}

public enum PathOptimizer {
    /// Total length of the travel moves (laser off) when the shapes are run in the given order, starting at `start`.
    public static func travelLength(_ lines: [Polyline], from start: Pt = Pt(0, 0)) -> Double {
        var pos = start, total = 0.0
        for l in lines {
            guard let f = l.first, let e = l.last else { continue }
            total += pos.distance(to: f)
            pos = e
        }
        return total
    }

    /// How many closed shapes enclose each shape (0 = outermost).
    public static func depths(_ lines: [Polyline]) -> [Int] {
        let boxes = lines.map { VectorMath.bounds([$0]) }
        var out = [Int](repeating: 0, count: lines.count)
        for i in 0..<lines.count {
            guard let p = lines[i].points.first else { continue }
            var d = 0
            for j in 0..<lines.count where j != i && lines[j].closed {
                let b = boxes[j]
                guard p.x >= b.minX, p.x <= b.maxX, p.y >= b.minY, p.y <= b.maxY else { continue }
                // a shape cannot be inside a smaller one
                if lines[i].closed, abs(lines[i].signedArea) >= abs(lines[j].signedArea) { continue }
                if VectorMath.contains(lines[j], p) { d += 1 }
            }
            out[i] = d
        }
        return out
    }

    public static func optimize(_ input: [Polyline], options o: PathOptimizeOptions = PathOptimizeOptions(), start: Pt = Pt(0, 0)) -> [Polyline] {
        let lines = input.filter { $0.points.count > 1 }
        guard o.reorder || o.insideFirst, lines.count > 1 else { return lines }
        var groups: [[Polyline]]
        if o.insideFirst, lines.count <= 3000 {
            let d = depths(lines)
            let maxD = d.max() ?? 0
            groups = (0...maxD).reversed().map { level in zip(lines, d).filter { $0.1 == level }.map { $0.0 } }
        } else { groups = [lines] }
        var result: [Polyline] = []
        var pos = start
        for g in groups where !g.isEmpty {
            var ordered = o.reorder ? nearestNeighbour(g, from: pos, flexible: o.flexibleStart) : g
            if o.reorder, ordered.count > 2, ordered.count <= 1500 { twoOpt(&ordered, from: pos) }
            result += ordered
            if let l = ordered.last?.last { pos = l }
        }
        return result
    }

    static func nearestNeighbour(_ lines: [Polyline], from start: Pt, flexible: Bool) -> [Polyline] {
        var rest = lines
        var out: [Polyline] = []
        out.reserveCapacity(lines.count)
        var pos = start
        while !rest.isEmpty {
            var best = 0, bestD = Double.infinity, bestRev = false, bestShift = 0
            for (i, l) in rest.enumerated() {
                if l.closed && flexible {
                    for (k, p) in l.points.enumerated() {
                        let d = pos.distance(to: p)
                        if d < bestD { bestD = d; best = i; bestShift = k; bestRev = false }
                    }
                } else {
                    let d0 = pos.distance(to: l.points[0])
                    if d0 < bestD { bestD = d0; best = i; bestRev = false; bestShift = 0 }
                    if flexible && !l.closed {
                        let d1 = pos.distance(to: l.points[l.points.count - 1])
                        if d1 < bestD { bestD = d1; best = i; bestRev = true; bestShift = 0 }
                    }
                }
            }
            var l = rest.remove(at: best)
            if l.closed && bestShift > 0 { l.points = Array(l.points[bestShift...] + l.points[..<bestShift]) }
            if bestRev { l = l.reversed() }
            out.append(l)
            pos = l.last ?? pos
        }
        return out
    }

    /// 2-opt: reverse stretches of the order (and the direction of each shape inside it) while that shortens the travel.
    /// Closed shapes keep their start point, so they are only re-ordered, not reversed.
    static func twoOpt(_ lines: inout [Polyline], from start: Pt) {
        let n = lines.count
        var improved = true
        var passes = 0
        let deadline = Date().addingTimeInterval(1.5)
        func entry(_ i: Int) -> Pt { lines[i].points[0] }
        func exit(_ i: Int) -> Pt { lines[i].closed ? lines[i].points[0] : lines[i].points[lines[i].points.count - 1] }
        while improved, passes < 30, Date() < deadline {
            improved = false; passes += 1
            for i in 0..<(n - 1) {
                for j in (i + 1)..<n {
                    // can the stretch i...j be reversed? only if every open shape in it can run backwards (always) and
                    // closed shapes are traversed from their start point either way
                    let before = i == 0 ? start : exit(i - 1)
                    let oldA = before.distance(to: entry(i))
                    let oldB = j == n - 1 ? 0 : exit(j).distance(to: entry(j + 1))
                    // after reversing: arrive at the old exit of j, leave from the old entry of i
                    let newA = before.distance(to: exit(j))
                    let newB = j == n - 1 ? 0 : entry(i).distance(to: entry(j + 1))
                    if newA + newB < oldA + oldB - 1e-9 {
                        var seg = Array(lines[i...j].reversed())
                        for k in 0..<seg.count where !seg[k].closed { seg[k] = seg[k].reversed() }
                        lines.replaceSubrange(i...j, with: seg)
                        improved = true
                    }
                }
            }
        }
    }
}

// MARK: - G-code from shapes

public enum VectorMode: String, Codable { case line, fill, lineAndFill }

/// How shapes are burnt. Power is in percent of the machine's S range.
public struct VectorSettings: Codable, Equatable {
    public var mode: VectorMode = .line
    public var speed = 1000.0                 // mm/min
    public var powerPercent = 100.0
    public var passes = 1
    public var dynamicPower = true            // M4 (needs laser mode $32=1) instead of M3
    public var fillSpacing = 0.1              // mm between hatch lines
    public var fillAngle = 0.0                // degrees
    public var fillBothDirections = true      // serpentine
    public var optimize = PathOptimizeOptions()
    public init() {}
}

public enum VectorJob {
    static func fmt(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    /// Hatch lines that fill the closed shapes (even-odd rule), for engraving areas.
    public static func hatch(_ lines: [Polyline], spacing: Double, angle: Double, serpentine: Bool) -> [Polyline] {
        let closed = lines.filter { $0.closed && $0.points.count > 2 }
        guard !closed.isEmpty, spacing > 0.005 else { return [] }
        let rot = Affine.rotate(degrees: -angle), back = Affine.rotate(degrees: angle)
        let rotated = closed.map { Polyline($0.points.map { rot.apply($0) }, closed: true) }
        let b = VectorMath.bounds(rotated)
        guard !b.isEmpty, (b.height / spacing) < 50_000 else { return [] }
        var out: [Polyline] = []
        var y = b.minY + spacing / 2
        var forward = true
        while y < b.maxY {
            var xs: [Double] = []
            for poly in rotated {
                let v = poly.points
                var j = v.count - 1
                for i in 0..<v.count {
                    let a = v[j], c = v[i]
                    if (a.y > y) != (c.y > y) { xs.append(a.x + (y - a.y) * (c.x - a.x) / (c.y - a.y)) }
                    j = i
                }
            }
            xs.sort()
            var segs: [(Double, Double)] = []
            var k = 0
            while k + 1 < xs.count { if xs[k + 1] - xs[k] > 1e-6 { segs.append((xs[k], xs[k + 1])) }; k += 2 }
            if !forward { segs.reverse() }
            for (x0, x1) in segs {
                let p0 = Pt(forward ? x0 : x1, y), p1 = Pt(forward ? x1 : x0, y)
                out.append(Polyline([back.apply(p0), back.apply(p1)]))
            }
            if serpentine { forward.toggle() }
            y += spacing
        }
        return out
    }

    /// The shapes ready to run, in order: outlines and/or hatch lines, optimised.
    public static func toolpaths(_ lines: [Polyline], _ s: VectorSettings, start: Pt = Pt(0, 0)) -> [Polyline] {
        var paths: [Polyline] = []
        if s.mode == .fill || s.mode == .lineAndFill {
            paths += hatch(lines, spacing: s.fillSpacing, angle: s.fillAngle, serpentine: s.fillBothDirections)
        }
        if s.mode == .line || s.mode == .lineAndFill { paths += lines }
        var o = s.optimize
        // hatch lines are already ordered; keep their order unless outlines are mixed in
        if s.mode == .fill { o.reorder = false; o.insideFirst = false }
        return PathOptimizer.optimize(paths, options: o, start: start)
    }

    /// G-code for the shapes. `maxS` is the machine's S maximum ($30).
    public static func gcode(_ lines: [Polyline], _ s: VectorSettings, maxS: Double = 1000, header: Bool = true) -> [String] {
        let paths = toolpaths(lines, s)
        let power = Int((s.powerPercent / 100 * maxS).rounded())
        let on = s.dynamicPower ? "M4" : "M3"
        var out: [String] = []
        if header { out += ["G21", "G90"] }
        for pass in 0..<max(1, s.passes) {
            if s.passes > 1 { out.append("; pass \(pass + 1) of \(s.passes)") }
            for path in paths {
                guard let p0 = path.first else { continue }
                out.append("M5")
                out.append("G0 X\(fmt(p0.x)) Y\(fmt(p0.y))")
                out.append("\(on) S\(power)")
                var first = true
                for p in path.points.dropFirst() {
                    out.append("G1 X\(fmt(p.x)) Y\(fmt(p.y))" + (first ? " F\(fmt(s.speed))" : ""))
                    first = false
                }
                if path.closed, path.points.count > 2 {
                    out.append("G1 X\(fmt(p0.x)) Y\(fmt(p0.y))" + (first ? " F\(fmt(s.speed))" : ""))
                }
            }
        }
        out.append("M5")
        out.append("S0")
        return out
    }
}
