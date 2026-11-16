import Foundation

/// A point in millimetres (machine coordinates: origin bottom left, Y up).
public struct Pt: Equatable, Codable {
    public var x: Double, y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public func distance(to o: Pt) -> Double { ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y)).squareRoot() }
}

/// A chain of points that is either open or closed (the last point connects to the first).
public struct Polyline: Equatable, Codable {
    public var points: [Pt]
    public var closed: Bool
    /// Where it came from, for example the stroke colour of an SVG element; used to build layers.
    public var tag: String?
    public init(_ points: [Pt], closed: Bool = false, tag: String? = nil) {
        self.points = points; self.closed = closed; self.tag = tag
    }
    public var first: Pt? { points.first }
    public var last: Pt? { closed ? points.first : points.last }
    public var length: Double {
        var l = 0.0
        for i in 1..<Swift.max(1, points.count) { l += points[i - 1].distance(to: points[i]) }
        if closed, points.count > 2 { l += points[points.count - 1].distance(to: points[0]) }
        return l
    }
    /// Signed area (positive = counter-clockwise); zero for open chains.
    public var signedArea: Double {
        guard closed, points.count > 2 else { return 0 }
        var a = 0.0
        for i in 0..<points.count {
            let p = points[i], q = points[(i + 1) % points.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }
    public func reversed() -> Polyline { Polyline(points.reversed(), closed: closed, tag: tag) }
}

/// Affine transform: x' = a·x + c·y + e, y' = b·x + d·y + f.
public struct Affine: Equatable, Codable {
    public var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0
    public init() {}
    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }
    public static let identity = Affine()
    public static func translate(_ x: Double, _ y: Double) -> Affine { Affine(a: 1, b: 0, c: 0, d: 1, e: x, f: y) }
    public static func scale(_ x: Double, _ y: Double) -> Affine { Affine(a: x, b: 0, c: 0, d: y, e: 0, f: 0) }
    public static func rotate(degrees: Double) -> Affine {
        let r = degrees * .pi / 180, c = cos(r), s = sin(r)
        return Affine(a: c, b: s, c: -s, d: c, e: 0, f: 0)
    }
    /// `self` applied after `o` (o first, then self).
    public func concatenating(_ o: Affine) -> Affine {
        Affine(a: a * o.a + c * o.b, b: b * o.a + d * o.b,
               c: a * o.c + c * o.d, d: b * o.c + d * o.d,
               e: a * o.e + c * o.f + e, f: b * o.e + d * o.f + f)
    }
    public func apply(_ p: Pt) -> Pt { Pt(a * p.x + c * p.y + e, b * p.x + d * p.y + f) }
}

public enum VectorMath {
    /// Largest coordinate (mm) accepted from an imported file: 100 m. Anything beyond is a damaged or hostile file.
    public static let maxCoordinate = 100_000.0

    /// Drops the shapes that have a point that is not a finite number or lies absurdly far away, and shapes with fewer than two
    /// points. Files from the internet can contain `1e308` or `NaN`; one such point would break sizes, previews and G-code.
    public static func sanitized(_ lines: [Polyline]) -> [Polyline] {
        lines.filter { l in
            l.points.count >= 2 && l.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= maxCoordinate && abs($0.y) <= maxCoordinate }
        }
    }

    public static func bounds(_ lines: [Polyline]) -> Bounds {
        var b = Bounds()
        for l in lines { for p in l.points { b.add(p.x, p.y) } }
        return b
    }

    public static func transform(_ lines: [Polyline], _ t: Affine) -> [Polyline] {
        lines.map { Polyline($0.points.map { t.apply($0) }, closed: $0.closed, tag: $0.tag) }
    }

    /// Moves and scales the shapes so that they fill the box (x, y, width, height); nothing when empty.
    public static func fit(_ lines: [Polyline], toX x: Double, y: Double, width: Double, height: Double) -> [Polyline] {
        let b = bounds(lines)
        guard !b.isEmpty else { return lines }
        let sx = b.width > 1e-9 ? width / b.width : 1, sy = b.height > 1e-9 ? height / b.height : 1
        return transform(lines, Affine.translate(x, y).concatenating(.scale(sx, sy)).concatenating(.translate(-b.minX, -b.minY)))
    }

    /// Ramer–Douglas–Peucker simplification (tolerance in mm).
    public static func simplify(_ pts: [Pt], tolerance: Double, closed: Bool = false) -> [Pt] {
        guard pts.count > 2, tolerance > 0 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            var maxD = 0.0, idx = -1
            let a = pts[s], b = pts[e]
            for i in (s + 1)..<e where e > s + 1 {
                let d = distance(pts[i], from: a, to: b)
                if d > maxD { maxD = d; idx = i }
            }
            if idx >= 0, maxD > tolerance { keep[idx] = true; stack.append((s, idx)); stack.append((idx, e)) }
        }
        return zip(pts, keep).filter { $0.1 }.map { $0.0 }
    }

    static func distance(_ p: Pt, from a: Pt, to b: Pt) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        if l2 < 1e-18 { return p.distance(to: a) }
        let t = Swift.max(0, Swift.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return p.distance(to: Pt(a.x + t * dx, a.y + t * dy))
    }

    /// Point-in-polygon (even-odd) for a closed polyline.
    public static func contains(_ poly: Polyline, _ p: Pt) -> Bool {
        let v = poly.points
        guard poly.closed, v.count > 2 else { return false }
        var inside = false
        var j = v.count - 1
        for i in 0..<v.count {
            if (v[i].y > p.y) != (v[j].y > p.y),
               p.x < (v[j].x - v[i].x) * (p.y - v[i].y) / (v[j].y - v[i].y) + v[i].x { inside.toggle() }
            j = i
        }
        return inside
    }
}

// MARK: - SVG

public struct SVGOptions {
    /// Resolution used for unitless / px sizes. SVG defines 96 px per inch.
    public var dpi: Double = 96
    /// SVG has Y pointing down, machines have Y up.
    public var flipY = true
    /// Flattening accuracy in mm.
    public var tolerance = 0.02
    public init() {}
}

public enum SVGError: Error, LocalizedError {
    case notSVG, empty
    public var errorDescription: String? {
        switch self {
        case .notSVG: return "This is not a valid SVG file."
        case .empty: return "The SVG file contains no shapes."
        }
    }
}

/// Reads outlines from an SVG file: paths (all commands incl. arcs), rect, circle, ellipse, line, polyline, polygon,
/// nested groups with transforms, viewBox and units. Everything is returned as polylines in millimetres.
/// Not supported: text, images, <use>, clip paths, gradients (they are ignored).
public final class SVGParser: NSObject, XMLParserDelegate {
    private var options: SVGOptions
    private var stack: [Affine] = [.identity]
    private var hidden = 0                // depth inside <defs>, <clipPath>, <mask>, <symbol>, <pattern>, <marker>
    private var skipDepth: [Bool] = []
    private var shapes: [Polyline] = []
    private var sawSVG = false
    private var rootScale = 1.0           // user unit -> mm
    private var rootTransform = Affine.identity
    private var rootHeight = 0.0          // for Y flip, in user units after viewBox mapping
    private var failed = false

    init(options: SVGOptions) { self.options = options }

    public static func parse(_ data: Data, options: SVGOptions = SVGOptions()) throws -> [Polyline] {
        let p = SVGParser(options: options)
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.shouldProcessNamespaces = false
        _ = xml.parse()
        guard p.sawSVG else { throw SVGError.notSVG }
        let shapes = VectorMath.sanitized(p.shapes)
        guard !shapes.isEmpty else { throw SVGError.empty }
        return shapes
    }

    public static func parse(contentsOf url: URL, options: SVGOptions = SVGOptions()) throws -> [Polyline] {
        try parse(Data(contentsOf: url), options: options)
    }

    // MARK: XML

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String]) {
        let tag = name.split(separator: ":").last.map(String.init) ?? name
        var local = Affine.identity
        if let t = a["transform"] { local = SVGParser.parseTransform(t) }
        if tag == "svg", !sawSVG {
            sawSVG = true
            setUpRoot(a)
            stack = [rootTransform]
            skipDepth.append(false)
            return
        }
        let hide = ["defs", "clipPath", "mask", "symbol", "pattern", "marker", "metadata", "title", "desc"].contains(tag)
        let isHidden = hidden > 0 || hide || a["display"] == "none" || (a["style"]?.contains("display:none") ?? false)
        if hide { hidden += 1 }
        skipDepth.append(hide)
        let current = stack.last!.concatenating(local)
        stack.append(current)
        guard !isHidden else { return }
        let color = SVGParser.colour(a)
        let t = options.tolerance
        switch tag {
        case "path":
            if let d = a["d"] { emit(SVGPathData.polylines(d, transform: current, tolerance: t), color) }
        case "rect":
            let x = num(a["x"]), y = num(a["y"]), w = num(a["width"]), h = num(a["height"])
            guard w > 0, h > 0 else { return }
            var rx = a["rx"].map { num($0) } ?? -1, ry = a["ry"].map { num($0) } ?? -1
            if rx < 0 && ry < 0 { rx = 0; ry = 0 } else if rx < 0 { rx = ry } else if ry < 0 { ry = rx }
            rx = Swift.min(rx, w / 2); ry = Swift.min(ry, h / 2)
            let d: String
            if rx > 0 && ry > 0 {
                d = "M\(x + rx) \(y) H\(x + w - rx) A\(rx) \(ry) 0 0 1 \(x + w) \(y + ry) V\(y + h - ry) A\(rx) \(ry) 0 0 1 \(x + w - rx) \(y + h) H\(x + rx) A\(rx) \(ry) 0 0 1 \(x) \(y + h - ry) V\(y + ry) A\(rx) \(ry) 0 0 1 \(x + rx) \(y) Z"
            } else {
                d = "M\(x) \(y) H\(x + w) V\(y + h) H\(x) Z"
            }
            emit(SVGPathData.polylines(d, transform: current, tolerance: t), color)
        case "circle":
            let r = num(a["r"]); guard r > 0 else { return }
            emit(ellipse(num(a["cx"]), num(a["cy"]), r, r, current), color)
        case "ellipse":
            let rx = num(a["rx"]), ry = num(a["ry"]); guard rx > 0, ry > 0 else { return }
            emit(ellipse(num(a["cx"]), num(a["cy"]), rx, ry, current), color)
        case "line":
            emit(SVGPathData.polylines("M\(num(a["x1"])) \(num(a["y1"])) L\(num(a["x2"])) \(num(a["y2"]))", transform: current, tolerance: t), color)
        case "polyline", "polygon":
            let n = SVGPathData.numbers(a["points"] ?? "")
            guard n.count >= 4 else { return }
            var d = "M\(n[0]) \(n[1])"
            var i = 2
            while i + 1 < n.count { d += " L\(n[i]) \(n[i + 1])"; i += 2 }
            if tag == "polygon" { d += " Z" }
            emit(SVGPathData.polylines(d, transform: current, tolerance: t), color)
        default: break
        }
    }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard !skipDepth.isEmpty else { return }
        if skipDepth.removeLast() { hidden -= 1 }
        if stack.count > 1 { stack.removeLast() }
    }

    // MARK: helpers

    private func emit(_ lines: [Polyline], _ color: String?) {
        for var l in lines where l.points.count > 1 { l.tag = color; shapes.append(l) }
    }

    private func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ t: Affine) -> [Polyline] {
        SVGPathData.polylines("M\(cx + rx) \(cy) A\(rx) \(ry) 0 1 1 \(cx - rx) \(cy) A\(rx) \(ry) 0 1 1 \(cx + rx) \(cy) Z", transform: t, tolerance: options.tolerance)
    }

    private func num(_ s: String?) -> Double {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return 0 }
        if let plain = Double(s) { return plain }                                // user units
        return SVGParser.length(s, dpi: options.dpi, percentOf: 0) / rootScale   // with unit: to user units
    }

    /// Length with unit to millimetres.
    static func length(_ s: String, dpi: Double, percentOf: Double) -> Double {
        let t = s.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("mm", 1), ("cm", 10), ("in", 25.4), ("pt", 25.4 / 72), ("pc", 25.4 / 6), ("px", 25.4 / dpi), ("%", percentOf / 100)]
        for (u, f) in units where t.hasSuffix(u) {
            return (Double(t.dropLast(u.count).trimmingCharacters(in: .whitespaces)) ?? 0) * f
        }
        return (Double(t) ?? 0) * 25.4 / dpi
    }

    private func setUpRoot(_ a: [String: String]) {
        let vb = SVGPathData.numbers(a["viewBox"] ?? "")
        let mmPerPx = 25.4 / options.dpi
        var wMM: Double? = nil, hMM: Double? = nil
        if let w = a["width"], !w.hasSuffix("%") { wMM = SVGParser.length(w, dpi: options.dpi, percentOf: 0) }
        if let h = a["height"], !h.hasSuffix("%") { hMM = SVGParser.length(h, dpi: options.dpi, percentOf: 0) }
        var t = Affine.identity
        if vb.count == 4, vb[2] > 0, vb[3] > 0 {
            let sx = (wMM ?? vb[2] * mmPerPx) / vb[2], sy = (hMM ?? vb[3] * mmPerPx) / vb[3]
            let s = Swift.min(sx, sy)                        // preserveAspectRatio meet (default)
            rootScale = s
            t = Affine.scale(s, s).concatenating(.translate(-vb[0], -vb[1]))
            rootHeight = vb[3] * s
        } else {
            rootScale = mmPerPx
            t = .scale(mmPerPx, mmPerPx)
            rootHeight = (hMM ?? 0)
        }
        if options.flipY {
            // heights unknown without width/height/viewBox: flip around the bounding box later
            if vb.count == 4 || hMM != nil { t = Affine(a: 1, b: 0, c: 0, d: -1, e: 0, f: rootHeight).concatenating(t) }
            else { t = Affine.scale(1, -1).concatenating(t); needsFlipFix = true }
        }
        rootTransform = t
    }
    private var needsFlipFix = false

    /// After parsing: when the SVG had no size, move everything so that the minimum is at 0.
    func finish() {
        guard needsFlipFix else { return }
        let b = VectorMath.bounds(shapes)
        if !b.isEmpty { shapes = VectorMath.transform(shapes, .translate(0, -b.minY)) }
    }

    public func parserDidEndDocument(_ parser: XMLParser) { finish() }

    static func colour(_ a: [String: String]) -> String? {
        var stroke = a["stroke"], fill = a["fill"]
        if let style = a["style"] {
            for part in style.split(separator: ";") {
                let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { if kv[0] == "stroke" { stroke = kv[1] } else if kv[0] == "fill" { fill = kv[1] } }
            }
        }
        if let s = stroke, s != "none" { return s.lowercased() }
        if let f = fill, f != "none" { return f.lowercased() }
        return nil
    }

    static func parseTransform(_ s: String) -> Affine {
        var result = Affine.identity
        let scanner = Scanner(string: s)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\t\n\r")
        while !scanner.isAtEnd {
            guard let name = scanner.scanUpToString("("), scanner.scanString("(") != nil else { break }
            let body = scanner.scanUpToString(")") ?? ""
            _ = scanner.scanString(")")
            let n = SVGPathData.numbers(body)
            var m = Affine.identity
            switch name.trimmingCharacters(in: .whitespaces) {
            case "matrix" where n.count == 6: m = Affine(a: n[0], b: n[1], c: n[2], d: n[3], e: n[4], f: n[5])
            case "translate" where n.count >= 1: m = .translate(n[0], n.count > 1 ? n[1] : 0)
            case "scale" where n.count >= 1: m = .scale(n[0], n.count > 1 ? n[1] : n[0])
            case "rotate" where n.count >= 1:
                let r = Affine.rotate(degrees: n[0])
                m = n.count >= 3 ? Affine.translate(n[1], n[2]).concatenating(r).concatenating(.translate(-n[1], -n[2])) : r
            case "skewX" where n.count >= 1: m = Affine(a: 1, b: 0, c: tan(n[0] * .pi / 180), d: 1, e: 0, f: 0)
            case "skewY" where n.count >= 1: m = Affine(a: 1, b: tan(n[0] * .pi / 180), c: 0, d: 1, e: 0, f: 0)
            default: break
            }
            result = result.concatenating(m)
        }
        return result
    }
}

/// SVG path data ("M 10 10 L 20 20 C …") to polylines.
public enum SVGPathData {
    public static func numbers(_ s: String) -> [Double] {
        var out: [Double] = []
        var i = s.startIndex
        while i < s.endIndex {
            if let (v, next) = number(s, i) { out.append(v); i = next } else { i = s.index(after: i) }
        }
        return out
    }

    static func number(_ s: String, _ start: String.Index) -> (Double, String.Index)? {
        var i = start
        while i < s.endIndex, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" || s[i] == "\r" { i = s.index(after: i) }
        let begin = i
        if i < s.endIndex, s[i] == "-" || s[i] == "+" { i = s.index(after: i) }
        var digits = 0
        while i < s.endIndex, s[i].isASCII, s[i].isNumber { i = s.index(after: i); digits += 1 }
        if i < s.endIndex, s[i] == "." {
            i = s.index(after: i)
            while i < s.endIndex, s[i].isASCII, s[i].isNumber { i = s.index(after: i); digits += 1 }
        }
        guard digits > 0 else { return nil }
        if i < s.endIndex, s[i] == "e" || s[i] == "E" {
            var j = s.index(after: i)
            if j < s.endIndex, s[j] == "-" || s[j] == "+" { j = s.index(after: j) }
            if j < s.endIndex, s[j].isNumber {
                while j < s.endIndex, s[j].isNumber { j = s.index(after: j) }
                i = j
            }
        }
        guard let v = Double(s[begin..<i]) else { return nil }
        return (v, i)
    }

    /// Flags in arc commands are single characters that may not be separated ("a1 1 0 00 1 1").
    static func flag(_ s: String, _ start: String.Index) -> (Bool, String.Index)? {
        var i = start
        while i < s.endIndex, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" { i = s.index(after: i) }
        guard i < s.endIndex, s[i] == "0" || s[i] == "1" else { return nil }
        return (s[i] == "1", s.index(after: i))
    }

    public static func polylines(_ d: String, transform t: Affine, tolerance: Double) -> [Polyline] {
        var out: [Polyline] = []
        var cur: [Pt] = []
        var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0
        var lastCtrl: (Double, Double)? = nil, lastQ: (Double, Double)? = nil
        var cmd: Character = " "
        var i = d.startIndex

        func flush(closed: Bool) {
            if cur.count > 1 { out.append(Polyline(cur, closed: closed)) }
            cur = []
        }
        func add(_ x: Double, _ y: Double) { cur.append(t.apply(Pt(x, y))) }
        func skipSep() { while i < d.endIndex, d[i] == " " || d[i] == "," || d[i] == "\n" || d[i] == "\t" || d[i] == "\r" { i = d.index(after: i) } }
        func num() -> Double? { guard let (v, n) = number(d, i) else { return nil }; i = n; return v }

        while true {
            skipSep()
            guard i < d.endIndex else { break }
            let ch = d[i]
            if ch.isLetter { cmd = ch; i = d.index(after: i) } else if cmd == " " { break }
            let rel = cmd.isLowercase
            switch cmd {
            case "M", "m":
                guard let x = num(), let y = num() else { return finish() }
                flush(closed: false)
                cx = rel ? cx + x : x; cy = rel ? cy + y : y
                sx = cx; sy = cy
                add(cx, cy)
                cmd = rel ? "l" : "L"
                lastCtrl = nil; lastQ = nil
            case "L", "l":
                guard let x = num(), let y = num() else { return finish() }
                cx = rel ? cx + x : x; cy = rel ? cy + y : y
                add(cx, cy); lastCtrl = nil; lastQ = nil
            case "H", "h":
                guard let x = num() else { return finish() }
                cx = rel ? cx + x : x; add(cx, cy); lastCtrl = nil; lastQ = nil
            case "V", "v":
                guard let y = num() else { return finish() }
                cy = rel ? cy + y : y; add(cx, cy); lastCtrl = nil; lastQ = nil
            case "C", "c", "S", "s":
                var x1 = cx, y1 = cy
                if cmd == "C" || cmd == "c" {
                    guard let a = num(), let b = num() else { return finish() }
                    x1 = rel ? cx + a : a; y1 = rel ? cy + b : b
                } else if let lc = lastCtrl { x1 = 2 * cx - lc.0; y1 = 2 * cy - lc.1 }
                guard let a2 = num(), let b2 = num(), let a3 = num(), let b3 = num() else { return finish() }
                let x2 = rel ? cx + a2 : a2, y2 = rel ? cy + b2 : b2
                let x3 = rel ? cx + a3 : a3, y3 = rel ? cy + b3 : b3
                cubic(Pt(cx, cy), Pt(x1, y1), Pt(x2, y2), Pt(x3, y3), t, tolerance, &cur)
                cx = x3; cy = y3; lastCtrl = (x2, y2); lastQ = nil
            case "Q", "q", "T", "t":
                var x1 = cx, y1 = cy
                if cmd == "Q" || cmd == "q" {
                    guard let a = num(), let b = num() else { return finish() }
                    x1 = rel ? cx + a : a; y1 = rel ? cy + b : b
                } else if let lq = lastQ { x1 = 2 * cx - lq.0; y1 = 2 * cy - lq.1 }
                guard let a2 = num(), let b2 = num() else { return finish() }
                let x2 = rel ? cx + a2 : a2, y2 = rel ? cy + b2 : b2
                // elevate to cubic
                let c1 = Pt(cx + 2.0 / 3 * (x1 - cx), cy + 2.0 / 3 * (y1 - cy))
                let c2 = Pt(x2 + 2.0 / 3 * (x1 - x2), y2 + 2.0 / 3 * (y1 - y2))
                cubic(Pt(cx, cy), c1, c2, Pt(x2, y2), t, tolerance, &cur)
                cx = x2; cy = y2; lastQ = (x1, y1); lastCtrl = nil
            case "A", "a":
                guard let rx = num(), let ry = num(), let rot = num() else { return finish() }
                skipSep(); guard let (large, n1) = flag(d, i) else { return finish() }; i = n1
                skipSep(); guard let (sweep, n2) = flag(d, i) else { return finish() }; i = n2
                guard let a = num(), let b = num() else { return finish() }
                let x = rel ? cx + a : a, y = rel ? cy + b : b
                arc(cx, cy, rx, ry, rot, large, sweep, x, y, t, tolerance, &cur)
                cx = x; cy = y; lastCtrl = nil; lastQ = nil
            case "Z", "z":
                if !cur.isEmpty { flush(closed: true) }
                cx = sx; cy = sy
                cur = []                   // a following command without M starts at the subpath start
                if i < d.endIndex { skipSep(); if i < d.endIndex, !d[i].isLetter { cmd = "L"; add(cx, cy) } }
                lastCtrl = nil; lastQ = nil
            default: return finish()
            }
        }
        return finish()

        func finish() -> [Polyline] { flush(closed: false); return out }
    }

    /// Cubic Bézier flattening (control points are mapped by the transform first, then subdivided in mm).
    static func cubic(_ p0: Pt, _ p1: Pt, _ p2: Pt, _ p3: Pt, _ t: Affine, _ tol: Double, _ out: inout [Pt]) {
        let a = t.apply(p0), b = t.apply(p1), c = t.apply(p2), d = t.apply(p3)
        if out.isEmpty { out.append(a) }
        subdivide(a, b, c, d, tol, 0, &out)
    }

    private static func subdivide(_ a: Pt, _ b: Pt, _ c: Pt, _ d: Pt, _ tol: Double, _ depth: Int, _ out: inout [Pt]) {
        let flat = Swift.max(VectorMath.distance(b, from: a, to: d), VectorMath.distance(c, from: a, to: d))
        if flat <= tol || depth > 16 { out.append(d); return }
        let ab = mid(a, b), bc = mid(b, c), cd = mid(c, d)
        let abc = mid(ab, bc), bcd = mid(bc, cd), m = mid(abc, bcd)
        subdivide(a, ab, abc, m, tol, depth + 1, &out)
        subdivide(m, bcd, cd, d, tol, depth + 1, &out)
    }

    private static func mid(_ a: Pt, _ b: Pt) -> Pt { Pt((a.x + b.x) / 2, (a.y + b.y) / 2) }

    /// SVG endpoint arc to points (W3C implementation notes, F.6).
    static func arc(_ x1: Double, _ y1: Double, _ rxIn: Double, _ ryIn: Double, _ rotDeg: Double, _ large: Bool, _ sweep: Bool,
                    _ x2: Double, _ y2: Double, _ t: Affine, _ tol: Double, _ out: inout [Pt]) {
        func add(_ x: Double, _ y: Double) { out.append(t.apply(Pt(x, y))) }
        if out.isEmpty { add(x1, y1) }
        var rx = abs(rxIn), ry = abs(ryIn)
        if (x1 == x2 && y1 == y2) { return }
        if rx == 0 || ry == 0 { add(x2, y2); return }
        let phi = rotDeg * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (x1 - x2) / 2, dy = (y1 - y2) / 2
        let x1p = cp * dx + sp * dy, y1p = -sp * dx + cp * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = lambda.squareRoot(); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : (Swift.max(0, num) / den).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry, cyp = -coef * ry * x1p / rx
        let cx = cp * cxp - sp * cyp + (x1 + x2) / 2, cy = sp * cxp + cp * cyp + (y1 + y2) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let th1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dth = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dth > 0 { dth -= 2 * .pi } else if sweep && dth < 0 { dth += 2 * .pi }
        // step so that the sagitta stays below the tolerance (in user units, scaled by the transform)
        let scale = Swift.max(1e-9, (abs(t.a * t.d - t.b * t.c)).squareRoot())
        let r = Swift.max(rx, ry) * scale
        let step = r > tol ? 2 * acos(Swift.max(0, 1 - tol / r)) : .pi / 2
        let n = Swift.max(2, Int((abs(dth) / Swift.max(step, 0.01)).rounded(.up)))
        for k in 1...n {
            let a = th1 + dth * Double(k) / Double(n)
            let x = cp * rx * cos(a) - sp * ry * sin(a) + cx
            let y = sp * rx * cos(a) + cp * ry * sin(a) + cy
            if k == n { add(x2, y2) } else { add(x, y) }
        }
    }
}
