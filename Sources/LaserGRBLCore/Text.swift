import Foundation
import CoreText
import CoreGraphics

public enum TextAlign: String, Codable, CaseIterable { case left, center, right }

/// Text to engrave or cut. `fontName` is "Hershey" (single-stroke, ideal for engraving) or the name of an installed font
/// (its outlines are used).
public struct TextSpec: Codable, Equatable {
    public var text = "LaserCraft"
    public var fontName = "Hershey"
    /// Height of capital letters in mm.
    public var size = 10.0
    /// Line height as a multiple of the font size.
    public var lineSpacing = 1.4
    public var align: TextAlign = .left
    /// Extra space between letters in mm.
    public var letterSpacing = 0.0
    public init() {}
    public static let hershey = "Hershey"
}

/// Placeholders for series production: `{n}` serial number (`{n:3}` pads to three digits), `{date}`, `{time}`.
public enum TextTemplate {
    public static func expand(_ s: String, serial: Int = 1, date: Date = Date()) -> String {
        var out = s
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"; out = out.replacingOccurrences(of: "{date}", with: df.string(from: date))
        df.dateFormat = "HH:mm"; out = out.replacingOccurrences(of: "{time}", with: df.string(from: date))
        // {n} and {n:width}
        if let re = try? NSRegularExpression(pattern: "\\{n(?::(\\d{1,2}))?\\}") {
            let ns = out as NSString
            var result = "", last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let width = m.range(at: 1).location != NSNotFound ? Int(ns.substring(with: m.range(at: 1))) ?? 0 : 0
                result += String(format: "%0\(width)d", serial)
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }
    public static func hasPlaceholders(_ s: String) -> Bool { s.contains("{n") || s.contains("{date}") || s.contains("{time}") }
}

public enum TextLayout {
    static let hersheyCap = 1.3          // capital letter height in glyph units
    static let hersheyBaseline = 0.49
    static let hersheyGap = 0.3

    /// Parsed Hershey glyph: strokes in glyph units and advance width.
    static let hersheyGlyphs: [[[Pt]]] = HersheyData.glyphs.map { enc, _ in
        enc.split(separator: ";").map { stroke in
            stroke.split(separator: " ").map { pair in
                let v = pair.split(separator: ",")
                return Pt(Double(v[0]) ?? 0, Double(v[1]) ?? 0)
            }
        }
    }

    /// Installed font families and the Hershey font.
    public static func availableFonts() -> [String] {
        [TextSpec.hershey] + (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).sorted()
    }

    /// The text as outlines in mm, starting at (0, 0) at the lower left of the whole block.
    public static func polylines(_ spec: TextSpec, serial: Int = 1, date: Date = Date()) -> [Polyline] {
        let text = TextTemplate.expand(spec.text, serial: serial, date: date)
        let lines = text.components(separatedBy: "\n")
        var all: [(shapes: [Polyline], width: Double, baseline: Double)] = []
        let lineHeight = spec.size * spec.lineSpacing
        for (i, line) in lines.enumerated() {
            let r = spec.fontName == TextSpec.hershey ? hershey(line, spec) : outline(line, spec)
            all.append((r.shapes, r.width, -Double(i) * lineHeight))
        }
        let maxW = all.map { $0.width }.max() ?? 0
        var out: [Polyline] = []
        for l in all {
            let dx: Double
            switch spec.align { case .left: dx = 0; case .center: dx = (maxW - l.width) / 2; case .right: dx = maxW - l.width }
            out += VectorMath.transform(l.shapes, .translate(dx, l.baseline))
        }
        let b = VectorMath.bounds(out)
        guard !b.isEmpty else { return [] }
        return VectorMath.transform(out, .translate(-b.minX, -b.minY))
    }

    /// One line in the Hershey font; the baseline is at y = 0.
    static func hershey(_ line: String, _ spec: TextSpec) -> (shapes: [Polyline], width: Double) {
        let scale = spec.size / hersheyCap
        var x = 0.0
        var out: [Polyline] = []
        for ch in line.unicodeScalars {
            let code = Int(ch.value)
            let idx = (code >= 32 && code <= 126) ? code - 32 : 31      // unknown characters become "?"
            for stroke in hersheyGlyphs[idx] where stroke.count > 1 {
                out.append(Polyline(stroke.map { Pt(x + $0.x * scale, ($0.y - hersheyBaseline) * scale) }))
            }
            x += HersheyData.glyphs[idx].1 * scale + hersheyGap * scale + spec.letterSpacing
        }
        return (out, max(0, x - hersheyGap * scale - spec.letterSpacing))
    }

    /// One line in an installed font (outline); the baseline is at y = 0.
    static func outline(_ line: String, _ spec: TextSpec) -> (shapes: [Polyline], width: Double) {
        guard !line.isEmpty else { return ([], 0) }
        var font = CTFontCreateWithName(spec.fontName as CFString, 100, nil)
        let cap = CTFontGetCapHeight(font)
        if cap > 0 { font = CTFontCreateWithName(spec.fontName as CFString, 100 * spec.size / cap, nil) }
        let attr = NSAttributedString(string: line, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): spec.letterSpacing,
        ])
        let ctLine = CTLineCreateWithAttributedString(attr)
        var shapes: [Polyline] = []
        var width = 0.0
        for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = (attrs[kCTFontAttributeName as String] as! CTFont?) ?? font
            for i in 0..<n {
                guard let path = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                shapes += flatten(path, dx: Double(pos[i].x), dy: Double(pos[i].y), tolerance: 0.02)
            }
        }
        width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        return (shapes, width)
    }

    /// CGPath to polylines (mm), moved by (dx, dy).
    public static func flatten(_ path: CGPath, dx: Double = 0, dy: Double = 0, tolerance: Double) -> [Polyline] {
        var out: [Polyline] = []
        var cur: [Pt] = []
        var start = Pt(0, 0), last = Pt(0, 0)
        func flush(_ closed: Bool) { if cur.count > 1 { out.append(Polyline(cur, closed: closed)) }; cur = [] }
        path.applyWithBlock { e in
            let p = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint:
                flush(false); start = Pt(Double(p[0].x) + dx, Double(p[0].y) + dy); last = start; cur = [start]
            case .addLineToPoint:
                last = Pt(Double(p[0].x) + dx, Double(p[0].y) + dy); cur.append(last)
            case .addQuadCurveToPoint:
                let c = Pt(Double(p[0].x) + dx, Double(p[0].y) + dy), e2 = Pt(Double(p[1].x) + dx, Double(p[1].y) + dy)
                let c1 = Pt(last.x + 2.0 / 3 * (c.x - last.x), last.y + 2.0 / 3 * (c.y - last.y))
                let c2 = Pt(e2.x + 2.0 / 3 * (c.x - e2.x), e2.y + 2.0 / 3 * (c.y - e2.y))
                SVGPathData.cubic(last, c1, c2, e2, .identity, tolerance, &cur)
                last = e2
            case .addCurveToPoint:
                let c1 = Pt(Double(p[0].x) + dx, Double(p[0].y) + dy), c2 = Pt(Double(p[1].x) + dx, Double(p[1].y) + dy)
                let e2 = Pt(Double(p[2].x) + dx, Double(p[2].y) + dy)
                SVGPathData.cubic(last, c1, c2, e2, .identity, tolerance, &cur)
                last = e2
            case .closeSubpath:
                if cur.count > 2, let f = cur.first, let l = cur.last, f.distance(to: l) < 1e-9 { cur.removeLast() }
                flush(true); last = start
            @unknown default: break
            }
        }
        flush(false)
        return out
    }
}
