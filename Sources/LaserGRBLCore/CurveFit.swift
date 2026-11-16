import Foundation

/// A cubic Bézier segment.
public struct Bezier: Equatable {
    public var p0: Pt, p1: Pt, p2: Pt, p3: Pt
    public init(_ p0: Pt, _ p1: Pt, _ p2: Pt, _ p3: Pt) { self.p0 = p0; self.p1 = p1; self.p2 = p2; self.p3 = p3 }

    func point(_ t: Double) -> Pt {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return Pt(a * p0.x + b * p1.x + c * p2.x + d * p3.x, a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }
    func derivative(_ t: Double) -> Pt {
        let u = 1 - t
        let a = 3 * u * u, b = 6 * u * t, c = 3 * t * t
        return Pt(a * (p1.x - p0.x) + b * (p2.x - p1.x) + c * (p3.x - p2.x), a * (p1.y - p0.y) + b * (p2.y - p1.y) + c * (p3.y - p2.y))
    }
    func secondDerivative(_ t: Double) -> Pt {
        let u = 1 - t
        let a = 6 * u, b = 6 * t
        return Pt(a * (p2.x - 2 * p1.x + p0.x) + b * (p3.x - 2 * p2.x + p1.x), a * (p2.y - 2 * p1.y + p0.y) + b * (p3.y - 2 * p2.y + p1.y))
    }
}

/// Turns pixel staircases and rough polylines into smooth curves: corners are kept sharp, everything between them is fitted
/// with cubic Béziers (Schneider's algorithm) and then written out as few, evenly accurate line segments.
public enum CurveFit {

    // MARK: small vector helpers

    private static func sub(_ a: Pt, _ b: Pt) -> Pt { Pt(a.x - b.x, a.y - b.y) }
    private static func add(_ a: Pt, _ b: Pt) -> Pt { Pt(a.x + b.x, a.y + b.y) }
    private static func mul(_ a: Pt, _ k: Double) -> Pt { Pt(a.x * k, a.y * k) }
    private static func dot(_ a: Pt, _ b: Pt) -> Double { a.x * b.x + a.y * b.y }
    private static func length(_ a: Pt) -> Double { dot(a, a).squareRoot() }
    private static func unit(_ a: Pt) -> Pt { let l = length(a); return l > 1e-12 ? mul(a, 1 / l) : Pt(0, 0) }

    // MARK: public entry points

    /// The outline through `points` (a loop when `closed`) as smooth curves, flattened to a polygon. `tolerance` is how far the
    /// curve may stay away from the points, `cornerAngle` the turn (degrees) from which a point counts as a corner.
    public static func smooth(_ points: [Pt], closed: Bool, tolerance: Double = 0.6, cornerAngle: Double = 60, flatness: Double = 0.1) -> [Pt] {
        let n = points.count
        guard n >= 4 else { return points }
        let p = movingAverage(points, closed: closed, radius: 3)
        let corners = findCorners(p, closed: closed, span: 3, angle: cornerAngle)
        var segments: [Bezier] = []
        if closed {
            if corners.isEmpty {
                var loop = p; loop.append(p[0])
                let d = unit(sub(p[1], p[n - 1]))
                segments = fitCubic(loop, 0, loop.count - 1, d, mul(d, -1), tolerance * tolerance)
            } else {
                for (k, c) in corners.enumerated() {
                    let next = corners[(k + 1) % corners.count]
                    var section: [Pt] = []
                    var i = c
                    while true { section.append(p[i]); if i == next && section.count > 1 { break }; i = (i + 1) % n; if section.count > n + 1 { break } }
                    if section.count >= 2 { segments += fitSection(section, tolerance) }
                }
            }
        } else {
            var cuts = [0] + corners.filter { $0 > 0 && $0 < n - 1 } + [n - 1]
            cuts = Array(Set(cuts)).sorted()
            for k in 0..<(cuts.count - 1) { segments += fitSection(Array(p[cuts[k]...cuts[k + 1]]), tolerance) }
        }
        var out = flatten(segments, flatness: flatness)
        if closed, let f = out.first, let l = out.last, f.distance(to: l) < 1e-6 { out.removeLast() }
        return out.count >= 2 ? out : points
    }

    /// Bézier segments as points: every segment is subdivided until it is within `flatness` of a straight line.
    public static func flatten(_ segments: [Bezier], flatness: Double) -> [Pt] {
        var out: [Pt] = []
        for s in segments {
            if out.isEmpty { out.append(s.p0) }
            var tmp: [Pt] = [s.p0]
            SVGPathData.cubic(s.p0, s.p1, s.p2, s.p3, .identity, flatness, &tmp)
            out += tmp.dropFirst()
        }
        return out
    }

    // MARK: sections between corners

    private static func fitSection(_ pts: [Pt], _ tolerance: Double) -> [Bezier] {
        guard pts.count >= 2 else { return [] }
        let last = pts.count - 1
        let k = min(3, last)
        let t1 = unit(sub(pts[k], pts[0]))
        let t2 = unit(sub(pts[last - k], pts[last]))
        return fitCubic(pts, 0, last, t1, t2, tolerance * tolerance)
    }

    /// Smooth the staircase: every point becomes the mean of its neighbours (cyclic for loops).
    static func movingAverage(_ p: [Pt], closed: Bool, radius: Int) -> [Pt] {
        let n = p.count
        var out = p
        for i in 0..<n {
            if !closed && (i < radius || i >= n - radius) { continue }       // ends stay where they are
            var sx = 0.0, sy = 0.0, c = 0.0
            for d in -radius...radius {
                var j = i + d
                if closed { j = ((j % n) + n) % n } else if j < 0 || j >= n { continue }
                sx += p[j].x; sy += p[j].y; c += 1
            }
            out[i] = Pt(sx / c, sy / c)
        }
        return out
    }

    /// Indices where the outline turns by more than `angle` degrees over `span` points on either side (strongest in each stretch).
    static func findCorners(_ p: [Pt], closed: Bool, span s: Int, angle: Double) -> [Int] {
        let n = p.count
        guard n > 2 * s + 1 else { return [] }
        var turn = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var a = i - s, b = i + s
            if closed { a = ((a % n) + n) % n; b %= n } else if a < 0 || b >= n { continue }
            let v1 = unit(sub(p[i], p[a])), v2 = unit(sub(p[b], p[i]))
            let c = max(-1, min(1, dot(v1, v2)))
            turn[i] = acos(c) * 180 / .pi
        }
        var corners: [Int] = []
        for i in 0..<n where turn[i] > angle {
            var isMax = true
            for d in -s...s where d != 0 {
                var j = i + d
                if closed { j = ((j % n) + n) % n } else if j < 0 || j >= n { continue }
                if turn[j] > turn[i] || (turn[j] == turn[i] && d < 0) { isMax = false; break }
            }
            if isMax { corners.append(i) }
        }
        return corners
    }

    // MARK: Schneider's curve fitting

    private static func fitCubic(_ d: [Pt], _ first: Int, _ last: Int, _ t1: Pt, _ t2: Pt, _ error: Double) -> [Bezier] {
        if last - first == 1 {
            let dist = d[first].distance(to: d[last]) / 3
            return [Bezier(d[first], add(d[first], mul(t1, dist)), add(d[last], mul(t2, dist)), d[last])]
        }
        var u = chordLengthParameters(d, first, last)
        var bez = generate(d, first, last, u, t1, t2)
        var (maxErr, split) = maxError(d, first, last, bez, u)
        if maxErr < error { return [bez] }
        if maxErr < error * 16 {
            for _ in 0..<5 {
                let uPrime = reparameterize(d, first, last, u, bez)
                bez = generate(d, first, last, uPrime, t1, t2)
                (maxErr, split) = maxError(d, first, last, bez, uPrime)
                if maxErr < error { return [bez] }
                u = uPrime
            }
        }
        let center = centerTangent(d, split)
        return fitCubic(d, first, split, t1, center, error) + fitCubic(d, split, last, mul(center, -1), t2, error)
    }

    private static func chordLengthParameters(_ d: [Pt], _ first: Int, _ last: Int) -> [Double] {
        var u = [0.0]
        for i in (first + 1)...last { u.append(u[u.count - 1] + d[i].distance(to: d[i - 1])) }
        let total = u[u.count - 1]
        return total > 0 ? u.map { $0 / total } : u.enumerated().map { Double($0.offset) / Double(max(1, u.count - 1)) }
    }

    private static func generate(_ d: [Pt], _ first: Int, _ last: Int, _ u: [Double], _ t1: Pt, _ t2: Pt) -> Bezier {
        let n = last - first + 1
        let p0 = d[first], p3 = d[last]
        var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
        for i in 0..<n {
            let t = u[i], m = 1 - t
            let b0 = m * m * m, b1 = 3 * t * m * m, b2 = 3 * t * t * m, b3 = t * t * t
            let a1 = mul(t1, b1), a2 = mul(t2, b2)
            c00 += dot(a1, a1); c01 += dot(a1, a2); c11 += dot(a2, a2)
            let tmp = sub(d[first + i], add(mul(p0, b0 + b1), mul(p3, b2 + b3)))
            x0 += dot(a1, tmp); x1 += dot(a2, tmp)
        }
        let det = c00 * c11 - c01 * c01
        var alpha1 = 0.0, alpha2 = 0.0
        if abs(det) > 1e-12 { alpha1 = (x0 * c11 - x1 * c01) / det; alpha2 = (c00 * x1 - c01 * x0) / det }
        let seg = p0.distance(to: p3)
        let eps = 1e-6 * seg
        if alpha1 < eps || alpha2 < eps {
            alpha1 = seg / 3; alpha2 = seg / 3
        }
        return Bezier(p0, add(p0, mul(t1, alpha1)), add(p3, mul(t2, alpha2)), p3)
    }

    private static func reparameterize(_ d: [Pt], _ first: Int, _ last: Int, _ u: [Double], _ b: Bezier) -> [Double] {
        (0...(last - first)).map { i in
            let t = u[i]
            let q = sub(b.point(t), d[first + i])
            let q1 = b.derivative(t), q2 = b.secondDerivative(t)
            let num = dot(q, q1)
            let den = dot(q1, q1) + dot(q, q2)
            return abs(den) < 1e-12 ? t : max(0, min(1, t - num / den))
        }
    }

    private static func maxError(_ d: [Pt], _ first: Int, _ last: Int, _ b: Bezier, _ u: [Double]) -> (Double, Int) {
        var split = (last - first + 1) / 2 + first
        var worst = 0.0
        for i in (first + 1)..<last {
            let p = b.point(u[i - first])
            let v = sub(p, d[i])
            let dist = dot(v, v)
            if dist >= worst { worst = dist; split = i }
        }
        return (worst, split)
    }

    private static func centerTangent(_ d: [Pt], _ center: Int) -> Pt {
        unit(sub(d[center - 1], d[center + 1]))
    }
}
