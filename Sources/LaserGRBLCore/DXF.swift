import Foundation

public enum DXFError: Error, LocalizedError {
    case notDXF, binary, empty
    public var errorDescription: String? {
        switch self {
        case .notDXF: return "This is not a valid DXF file."
        case .binary: return "Binary DXF files are not supported. Save the drawing as an ASCII DXF."
        case .empty: return "The DXF file contains no lines or curves."
        }
    }
}

public struct DXFOptions {
    /// Flattening accuracy in mm.
    public var tolerance = 0.02
    /// Unit used when the file does not say (INSUNITS 0): millimetres.
    public var unitsIfUnknown = 1.0
    public init() {}
}

/// Reads the geometry of an ASCII DXF drawing: LINE, CIRCLE, ARC, ELLIPSE, LWPOLYLINE (with bulges), POLYLINE, SPLINE and
/// INSERT (blocks, scaled and turned). Everything is returned as polylines in millimetres, Y up, with the layer name as `tag`.
/// Not read: text, hatches, dimensions, 3D solids, images, paper space.
public enum DXFParser {
    typealias Pair = (code: Int, value: String)
    struct Entity { var type: String; var pairs: [Pair] }

    public static func parse(contentsOf url: URL, options: DXFOptions = DXFOptions()) throws -> [Polyline] {
        try parse(Data(contentsOf: url), options: options)
    }

    public static func parse(_ data: Data, options: DXFOptions = DXFOptions()) throws -> [Polyline] {
        if data.starts(with: Array("AutoCAD Binary DXF".utf8)) { throw DXFError.binary }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{FFFD}", with: "?")
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
        var pairs: [Pair] = []
        pairs.reserveCapacity(lines.count / 2)
        var i = 0
        while i + 1 < lines.count {
            guard let code = Int(lines[i].trimmingCharacters(in: .whitespaces)) else {
                if pairs.isEmpty { throw DXFError.notDXF }
                i += 1; continue
            }
            pairs.append((code, lines[i + 1].trimmingCharacters(in: .whitespaces)))
            i += 2
        }
        guard pairs.contains(where: { $0.code == 0 && $0.value == "SECTION" }) else { throw DXFError.notDXF }

        var units = 0
        var blocks: [String: [Entity]] = [:]
        var modelEntities: [Entity] = []
        var k = 0
        while k < pairs.count {
            if pairs[k].code == 0, pairs[k].value == "SECTION", k + 1 < pairs.count, pairs[k + 1].code == 2 {
                let name = pairs[k + 1].value
                var end = k + 2
                while end < pairs.count, !(pairs[end].code == 0 && pairs[end].value == "ENDSEC") { end += 1 }
                let body = Array(pairs[(k + 2)..<min(end, pairs.count)])
                if name == "HEADER" {
                    // header variables are a code 9 name followed by their value pairs
                    for (n, p) in body.enumerated() where p.code == 9 && p.value == "$INSUNITS" && n + 1 < body.count {
                        units = Int(body[n + 1].value) ?? 0
                    }
                }
                if name == "ENTITIES" { modelEntities = entities(body) }
                if name == "BLOCKS" { blocks = blockTable(body) }
                k = end
            }
            k += 1
        }

        var out: [Polyline] = []
        var budget = 400_000
        emit(modelEntities, blocks: blocks, transform: .identity, depth: 0, tolerance: options.tolerance / unitToMM(units, options), into: &out, budget: &budget)
        let s = unitToMM(units, options)
        if s != 1 { out = VectorMath.transform(out, .scale(s, s)) }
        out = VectorMath.sanitized(out)
        guard !out.isEmpty else { throw DXFError.empty }
        return out
    }

    /// A point count from a calculation on file data: never NaN, infinite or outside lo...hi.
    static func count(_ x: Double, _ lo: Int, _ hi: Int) -> Int {
        x.isFinite ? Int(max(Double(lo), min(Double(hi), x))) : lo
    }

    /// An angle difference brought into (0, 2π]: a sweep from `a0` to `a1` counter-clockwise.
    static func sweep(from a0: Double, to a1: Double) -> Double {
        guard a0.isFinite, a1.isFinite else { return 0 }
        var s = (a1 - a0).truncatingRemainder(dividingBy: 2 * .pi)
        if s <= 0 { s += 2 * .pi }
        return s
    }

    static func unitToMM(_ code: Int, _ o: DXFOptions) -> Double {
        switch code {
        case 1: return 25.4          // inches
        case 2: return 304.8         // feet
        case 4: return 1
        case 5: return 10
        case 6: return 1000
        case 8: return 0.0000254     // microinches
        case 9: return 0.0254        // mils
        case 10: return 914.4        // yards
        case 13: return 0.001        // microns
        default: return o.unitsIfUnknown
        }
    }

    // MARK: splitting into entities

    static func entities(_ body: [Pair]) -> [Entity] {
        var list: [Entity] = []
        var cur: Entity?
        for p in body {
            if p.code == 0 {
                if let c = cur { list.append(c) }
                cur = Entity(type: p.value, pairs: [])
            } else { cur?.pairs.append(p) }
        }
        if let c = cur { list.append(c) }
        return list
    }

    static func blockTable(_ body: [Pair]) -> [String: [Entity]] {
        var table: [String: [Entity]] = [:]
        var name: String?
        var members: [Entity] = []
        for e in entities(body) {
            if e.type == "BLOCK" {
                name = e.pairs.first { $0.code == 2 }?.value
                members = []
            } else if e.type == "ENDBLK" {
                if let n = name { table[n] = members }
                name = nil
            } else if name != nil { members.append(e) }
        }
        return table
    }

    // MARK: entities -> polylines

    static func num(_ e: Entity, _ code: Int, _ d: Double = 0) -> Double {
        e.pairs.first { $0.code == code }.flatMap { Double($0.value) } ?? d
    }

    static func emit(_ list: [Entity], blocks: [String: [Entity]], transform t: Affine, depth: Int, tolerance: Double, into out: inout [Polyline], budget: inout Int) {
        var i = 0
        func add(_ pts: [Pt], closed: Bool, layer: String) {
            guard pts.count >= 2, budget > 0 else { return }
            budget -= pts.count
            out.append(Polyline(pts.map { t.apply($0) }, closed: closed, tag: layer))
        }
        while i < list.count {
            let e = list[i]
            let layer = e.pairs.first { $0.code == 8 }?.value ?? "0"
            if e.pairs.contains(where: { $0.code == 67 && $0.value == "1" }) { i += 1; continue }    // paper space
            switch e.type {
            case "LINE":
                add([Pt(num(e, 10), num(e, 20)), Pt(num(e, 11), num(e, 21))], closed: false, layer: layer)
            case "CIRCLE":
                add(arc(cx: num(e, 10), cy: num(e, 20), r: num(e, 40), from: 0, sweep: 2 * Double.pi, tolerance: tolerance, full: true), closed: true, layer: layer)
            case "ARC":
                let a0 = num(e, 50) * .pi / 180, a1 = num(e, 51) * .pi / 180
                add(arc(cx: num(e, 10), cy: num(e, 20), r: num(e, 40), from: a0, sweep: sweep(from: a0, to: a1), tolerance: tolerance, full: false), closed: false, layer: layer)
            case "ELLIPSE":
                let cx = num(e, 10), cy = num(e, 20), mx = num(e, 11), my = num(e, 21), ratio = num(e, 40, 1)
                let t0 = num(e, 41, 0), t1 = num(e, 42, 2 * .pi)
                let sweep = DXFParser.sweep(from: t0, to: t1)
                let major = (mx * mx + my * my).squareRoot()
                let n = count(ceil(sweep / (2 * Double.pi) * min(720, max(48, (major / max(tolerance, 1e-6)).squareRoot() * 6))), 16, 2000)
                var pts: [Pt] = []
                for s in 0...n {
                    let a = t0 + sweep * Double(s) / Double(n)
                    let px = cos(a), py = ratio * sin(a)
                    pts.append(Pt(cx + px * mx - py * my, cy + px * my + py * mx))
                }
                let closed = abs(sweep - 2 * .pi) < 1e-6
                if closed { pts.removeLast() }
                add(pts, closed: closed, layer: layer)
            case "LWPOLYLINE":
                var verts: [(x: Double, y: Double, bulge: Double)] = []
                for p in e.pairs {
                    if p.code == 10 { verts.append((Double(p.value) ?? 0, 0, 0)) }
                    else if p.code == 20, !verts.isEmpty { verts[verts.count - 1].y = Double(p.value) ?? 0 }
                    else if p.code == 42, !verts.isEmpty { verts[verts.count - 1].bulge = Double(p.value) ?? 0 }
                }
                let closed = (Int(e.pairs.first { $0.code == 70 }?.value ?? "0") ?? 0) & 1 == 1
                add(bulgePath(verts, closed: closed, tolerance: tolerance), closed: closed, layer: layer)
            case "POLYLINE":
                var verts: [(x: Double, y: Double, bulge: Double)] = []
                var j = i + 1
                while j < list.count, list[j].type == "VERTEX" {
                    let v = list[j]
                    let flags = Int(v.pairs.first { $0.code == 70 }?.value ?? "0") ?? 0
                    if flags & 16 == 0 { verts.append((num(v, 10), num(v, 20), num(v, 42))) }    // skip spline frame control points
                    j += 1
                }
                if j < list.count, list[j].type == "SEQEND" { j += 1 }
                let closed = (Int(e.pairs.first { $0.code == 70 }?.value ?? "0") ?? 0) & 1 == 1
                add(bulgePath(verts, closed: closed, tolerance: tolerance), closed: closed, layer: layer)
                i = j; continue
            case "SPLINE":
                add(spline(e, tolerance: tolerance), closed: (Int(e.pairs.first { $0.code == 70 }?.value ?? "0") ?? 0) & 1 == 1, layer: layer)
            case "INSERT":
                guard depth < 6, let name = e.pairs.first(where: { $0.code == 2 })?.value, let members = blocks[name] else { break }
                let sx = num(e, 41, 1), sy = num(e, 42, 1), rot = num(e, 50)
                let local = Affine.translate(num(e, 10), num(e, 20)).concatenating(.rotate(degrees: rot)).concatenating(.scale(sx, sy))   // scale first, then turn, then move
                emit(members, blocks: blocks, transform: t.concatenating(local), depth: depth + 1, tolerance: tolerance, into: &out, budget: &budget)
            default: break
            }
            i += 1
        }
    }

    /// Points of a circular arc, evenly spaced so the chord error stays within `tolerance`.
    static func arc(cx: Double, cy: Double, r: Double, from a0: Double, sweep: Double, tolerance: Double, full: Bool) -> [Pt] {
        guard r > 0, r.isFinite, cx.isFinite, cy.isFinite, a0.isFinite, sweep.isFinite else { return [] }
        let step = 2 * acos(max(-1, min(1, 1 - min(tolerance, r) / r)))
        let n = count(ceil(abs(sweep) / max(step, 0.01)), full ? 24 : 4, 20_000)
        var pts: [Pt] = []
        for s in 0...n {
            if full && s == n { break }
            let a = a0 + sweep * Double(s) / Double(n)
            pts.append(Pt(cx + r * cos(a), cy + r * sin(a)))
        }
        return pts
    }

    /// A polyline with bulge values (tan of a quarter of the arc angle) turned into points.
    static func bulgePath(_ v: [(x: Double, y: Double, bulge: Double)], closed: Bool, tolerance: Double) -> [Pt] {
        guard v.count >= 2 else { return [] }
        var pts: [Pt] = []
        let count = closed ? v.count : v.count - 1
        for i in 0..<count {
            let a = v[i], b = v[(i + 1) % v.count]
            pts.append(Pt(a.x, a.y))
            if abs(a.bulge) > 1e-9 {
                let theta = 4 * atan(a.bulge)                        // signed included angle
                let dx = b.x - a.x, dy = b.y - a.y
                let chord = (dx * dx + dy * dy).squareRoot()
                guard chord > 1e-12 else { continue }
                guard sin(abs(theta) / 2) > 1e-9 else { continue }              // a full turn on one point has no arc
                let r = chord / (2 * sin(abs(theta) / 2))
                let mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2
                let h = r * cos(theta / 2)                           // distance from chord midpoint to centre
                let nx = -dy / chord, ny = dx / chord                // left normal
                let sign: Double = theta > 0 ? 1 : -1
                let cx = mx + nx * h * sign, cy = my + ny * h * sign
                let a0 = atan2(a.y - cy, a.x - cx)
                let step = 2 * acos(max(-1, min(1, 1 - min(tolerance, r) / r)))
                let n = DXFParser.count(ceil(abs(theta) / max(step, 0.01)), 2, 5_000)
                for s in 1..<n {
                    let ang = a0 + theta * Double(s) / Double(n)
                    pts.append(Pt(cx + r * cos(ang), cy + r * sin(ang)))
                }
            }
        }
        if !closed, let l = v.last { pts.append(Pt(l.x, l.y)) }
        return pts
    }

    /// A B-spline from its control points and knots (fit points when there are no control points).
    static func spline(_ e: Entity, tolerance: Double) -> [Pt] {
        var ctrl: [Pt] = [], fit: [Pt] = [], knots: [Double] = []
        var weights: [Double] = []
        for p in e.pairs {
            switch p.code {
            case 10: ctrl.append(Pt(Double(p.value) ?? 0, 0))
            case 20: if !ctrl.isEmpty { ctrl[ctrl.count - 1].y = Double(p.value) ?? 0 }
            case 11: fit.append(Pt(Double(p.value) ?? 0, 0))
            case 21: if !fit.isEmpty { fit[fit.count - 1].y = Double(p.value) ?? 0 }
            case 40: knots.append(Double(p.value) ?? 0)
            case 41: weights.append(Double(p.value) ?? 1)
            default: break
            }
        }
        let degree = Int(e.pairs.first { $0.code == 71 }?.value ?? "3") ?? 3
        if ctrl.count < 2 { return fit }
        guard degree >= 1, ctrl.count > degree, knots.count == ctrl.count + degree + 1, knots.last! > knots.first! else { return ctrl }
        let rational = weights.count == ctrl.count
        let lo = knots[degree], hi = knots[ctrl.count]
        let n = max(24, ctrl.count * 16)
        var pts: [Pt] = []
        for s in 0...n {
            let u = s == n ? hi : lo + (hi - lo) * Double(s) / Double(n)
            // find the knot span
            var span = degree
            while span < ctrl.count - 1, u >= knots[span + 1] { span += 1 }
            // Cox–de Boor basis functions
            var basis = [Double](repeating: 0, count: degree + 1)
            basis[0] = 1
            var left = [Double](repeating: 0, count: degree + 1), right = left
            if degree >= 1 {
                for j in 1...degree {
                    left[j] = u - knots[span + 1 - j]; right[j] = knots[span + j] - u
                    var saved = 0.0
                    for r in 0..<j {
                        let d = right[r + 1] + left[j - r]
                        let temp = d == 0 ? 0 : basis[r] / d
                        basis[r] = saved + right[r + 1] * temp
                        saved = left[j - r] * temp
                    }
                    basis[j] = saved
                }
            }
            var x = 0.0, y = 0.0, w = 0.0
            for j in 0...degree {
                let idx = span - degree + j
                let b = basis[j] * (rational ? weights[idx] : 1)
                x += b * ctrl[idx].x; y += b * ctrl[idx].y; w += b
            }
            if w != 0 { pts.append(Pt(x / w, y / w)) }
        }
        return VectorMath.simplify(pts, tolerance: tolerance)
    }
}
