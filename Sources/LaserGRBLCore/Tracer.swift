import Foundation

public struct TraceOptions: Codable, Equatable {
    /// Pixels darker than this (0...255) count as ink.
    public var threshold = 128
    /// Swap ink and paper.
    public var invert = false
    /// Contours: outline the dark areas. Centerline: one line through the middle of thin strokes (drawings, handwriting).
    public var centerline = false
    /// Shapes smaller than this many pixels are dropped (dust and scanner noise).
    public var minArea = 8
    /// Simplification in pixels; larger = fewer points, more angular.
    public var tolerance = 0.8
    /// Rounds the corners of contours (0...3 Chaikin steps).
    public var smoothing = 1
    /// Corners sharper than this angle (degrees) are kept sharp while smoothing.
    public var cornerAngle = 60.0
    /// Fit Bézier curves through the outline (smooth, few points) instead of straight stairs.
    public var curves = true
    /// How far a fitted curve may stay away from the outline, in pixels.
    public var curveError = 0.8
    public init() {}
}

/// Turns a picture into outlines: contour tracing of the dark areas or centerline tracing by thinning.
/// (This is a fresh Swift implementation, not a port of Potrace: curves are approximated by short straight lines.)
public enum Tracer {

    /// `gray`: 0 = black ... 255 = white, row by row, y down. Result in pixel units with y pointing up (origin lower left).
    public static func trace(gray: [UInt8], width w: Int, height h: Int, options o: TraceOptions = TraceOptions()) -> [Polyline] {
        guard w > 1, h > 1, gray.count >= w * h else { return [] }
        var ink = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { ink[i] = (Int(gray[i]) < o.threshold) != o.invert }
        var lines = o.centerline ? centerlines(ink, w, h, o) : contours(ink, w, h, o)
        // y up
        let hh = Double(h)
        lines = lines.map { Polyline($0.points.map { Pt($0.x, hh - $0.y) }, closed: $0.closed) }
        return lines
    }

    // MARK: contours

    static func contours(_ ink: [Bool], _ w: Int, _ h: Int, _ o: TraceOptions) -> [Polyline] {
        func at(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && ink[y * w + x] }
        // directed boundary edges between lattice corners, ink on the right-hand side when going along the edge (y down)
        var next: [Int: [Int]] = [:]            // corner id -> end corner ids
        let stride = w + 1
        func id(_ x: Int, _ y: Int) -> Int { y * stride + x }
        func addEdge(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) { next[id(x0, y0), default: []].append(id(x1, y1)) }
        for y in 0..<h {
            for x in 0..<w where at(x, y) {
                if !at(x, y - 1) { addEdge(x, y, x + 1, y) }            // top, going right
                if !at(x + 1, y) { addEdge(x + 1, y, x + 1, y + 1) }    // right, going down
                if !at(x, y + 1) { addEdge(x + 1, y + 1, x, y + 1) }    // bottom, going left
                if !at(x - 1, y) { addEdge(x, y + 1, x, y) }            // left, going up
            }
        }
        var out: [Polyline] = []
        for start in next.keys.sorted() {
          while !(next[start]?.isEmpty ?? true) {
            var loop: [Pt] = []
            var cur = start
            var prevDir = (0, 0)
            repeat {
                guard var options = next[cur], !options.isEmpty else { break }
                let cx = cur % stride, cy = cur / stride
                // at a corner with two exits prefer the sharper right turn: keeps diagonal pixels separate
                var pick = 0
                if options.count > 1 {
                    var bestScore = Int.min
                    for (i, e) in options.enumerated() {
                        let d = (e % stride - cx, e / stride - cy)
                        let cross = prevDir.0 * d.1 - prevDir.1 * d.0          // >0: turn right on screen
                        if cross > bestScore { bestScore = cross; pick = i }
                    }
                }
                let e = options.remove(at: pick)
                next[cur] = options
                loop.append(Pt(Double(cx), Double(cy)))
                prevDir = (e % stride - cx, e / stride - cy)
                cur = e
            } while cur != start
            if loop.count < 4 { continue }
            // drop collinear lattice points
            var pts: [Pt] = []
            for i in 0..<loop.count {
                let a = loop[(i + loop.count - 1) % loop.count], b = loop[i], c = loop[(i + 1) % loop.count]
                if (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) != 0 { pts.append(b) }
            }
            var poly = Polyline(pts, closed: true)
            if Int(abs(poly.signedArea)) < o.minArea { continue }
            poly.points = o.curves
                ? CurveFit.smooth(loop, closed: true, tolerance: o.curveError, cornerAngle: o.cornerAngle)
                : refine(pts, o)
            if poly.points.count > 2 { out.append(poly) }
          }
        }
        return out
    }

    /// Simplify and (optionally) round the corners of a closed outline.
    static func refine(_ pts: [Pt], _ o: TraceOptions) -> [Pt] {
        var p = pts
        if o.smoothing > 0 {
            for _ in 0..<min(3, o.smoothing) { p = chaikin(p, cornerCos: cos(o.cornerAngle * .pi / 180)) }
        }
        if o.tolerance > 0 {
            // simplify a closed loop: split at the point farthest from the start
            var far = 0, fd = 0.0
            for (i, q) in p.enumerated() { let d = q.distance(to: p[0]); if d > fd { fd = d; far = i } }
            if far > 0 && far < p.count - 1 {
                let a = VectorMath.simplify(Array(p[0...far]), tolerance: o.tolerance)
                let b = VectorMath.simplify(Array(p[far...]) + [p[0]], tolerance: o.tolerance)
                p = a + b.dropFirst().dropLast()
            }
        }
        return p
    }

    /// One Chaikin corner-cutting step on a closed polygon; corners sharper than the limit stay as they are.
    static func chaikin(_ p: [Pt], cornerCos: Double) -> [Pt] {
        let n = p.count
        guard n > 3 else { return p }
        var out: [Pt] = []
        for i in 0..<n {
            let a = p[(i + n - 1) % n], b = p[i], c = p[(i + 1) % n]
            let v1 = (x: b.x - a.x, y: b.y - a.y), v2 = (x: c.x - b.x, y: c.y - b.y)
            let l1 = (v1.x * v1.x + v1.y * v1.y).squareRoot(), l2 = (v2.x * v2.x + v2.y * v2.y).squareRoot()
            let cosTurn = l1 * l2 > 0 ? (v1.x * v2.x + v1.y * v2.y) / (l1 * l2) : 1      // 1 = straight on
            if cosTurn < cornerCos {          // sharp corner: keep
                out.append(b)
            } else {
                out.append(Pt(b.x * 0.75 + a.x * 0.25, b.y * 0.75 + a.y * 0.25))
                out.append(Pt(b.x * 0.75 + c.x * 0.25, b.y * 0.75 + c.y * 0.25))
            }
        }
        return out
    }

    // MARK: centerline

    /// Zhang–Suen thinning.
    static func thin(_ ink: [Bool], _ w: Int, _ h: Int) -> [Bool] {
        var img = ink
        func p(_ x: Int, _ y: Int) -> Int { x >= 0 && y >= 0 && x < w && y < h && img[y * w + x] ? 1 : 0 }
        var changed = true
        var guardCount = 0
        while changed, guardCount < 200 {
            changed = false; guardCount += 1
            for step in 0..<2 {
                var remove: [Int] = []
                for y in 0..<h {
                    for x in 0..<w where img[y * w + x] {
                        let p2 = p(x, y - 1), p3 = p(x + 1, y - 1), p4 = p(x + 1, y), p5 = p(x + 1, y + 1)
                        let p6 = p(x, y + 1), p7 = p(x - 1, y + 1), p8 = p(x - 1, y), p9 = p(x - 1, y - 1)
                        let b = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9
                        guard b >= 2, b <= 6 else { continue }
                        let seq = [p2, p3, p4, p5, p6, p7, p8, p9, p2]
                        var a = 0
                        for i in 0..<8 where seq[i] == 0 && seq[i + 1] == 1 { a += 1 }
                        guard a == 1 else { continue }
                        if step == 0 { guard p2 * p4 * p6 == 0, p4 * p6 * p8 == 0 else { continue } }
                        else { guard p2 * p4 * p8 == 0, p2 * p6 * p8 == 0 else { continue } }
                        remove.append(y * w + x)
                    }
                }
                if !remove.isEmpty { changed = true; for i in remove { img[i] = false } }
            }
        }
        return img
    }

    static func centerlines(_ ink: [Bool], _ w: Int, _ h: Int, _ o: TraceOptions) -> [Polyline] {
        let sk = thin(ink, w, h)
        func on(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && sk[y * w + x] }
        let dirs = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
        func neighbours(_ x: Int, _ y: Int) -> [(Int, Int)] { dirs.compactMap { on(x + $0.0, y + $0.1) ? (x + $0.0, y + $0.1) : nil } }
        var degree = [Int](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w where on(x, y) { degree[y * w + x] = neighbours(x, y).count } }
        var visited = Set<Int>()                    // visited edges as a * N + b
        let N = w * h
        func edgeKey(_ a: Int, _ b: Int) -> Int { min(a, b) * N + max(a, b) }
        var out: [Polyline] = []

        func walk(from sx: Int, _ sy: Int, first: (Int, Int)) {
            var pts = [Pt(Double(sx) + 0.5, Double(sy) + 0.5)]
            var prev = (sx, sy), cur = first
            visited.insert(edgeKey(sy * w + sx, cur.1 * w + cur.0))
            while true {
                pts.append(Pt(Double(cur.0) + 0.5, Double(cur.1) + 0.5))
                if degree[cur.1 * w + cur.0] != 2 { break }
                let nbs = neighbours(cur.0, cur.1).filter { $0 != prev }
                guard let n = nbs.first(where: { !visited.contains(edgeKey(cur.1 * w + cur.0, $0.1 * w + $0.0)) }) else { break }
                visited.insert(edgeKey(cur.1 * w + cur.0, n.1 * w + n.0))
                prev = cur; cur = n
                if cur == (sx, sy) { pts.append(Pt(Double(sx) + 0.5, Double(sy) + 0.5)); break }
            }
            if pts.count > 1 { out.append(Polyline(pts)) }
        }
        // from endpoints and junctions first, then loops
        for pass in 0..<2 {
            for y in 0..<h {
                for x in 0..<w where on(x, y) {
                    let d = degree[y * w + x]
                    if pass == 0 && d == 2 { continue }
                    for n in neighbours(x, y) where !visited.contains(edgeKey(y * w + x, n.1 * w + n.0)) {
                        walk(from: x, y, first: n)
                    }
                }
            }
        }
        // isolated dots are dropped; short stubs are noise
        return out.compactMap { l in
            guard l.length >= Double(max(2, o.minArea / 3)) else { return nil }
            var l = l
            if o.curves, l.points.count > 8 { l.points = CurveFit.smooth(l.points, closed: false, tolerance: max(0.5, o.curveError), cornerAngle: o.cornerAngle) }
            l.points = VectorMath.simplify(l.points, tolerance: max(0.3, o.curves ? 0.2 : o.tolerance))
            if let f = l.points.first, let e = l.points.last, l.points.count > 3, f.distance(to: e) < 1.5 { l.closed = true; l.points.removeLast() }
            return l
        }
    }
}
