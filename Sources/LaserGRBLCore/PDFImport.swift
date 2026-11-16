import Foundation
import CoreGraphics

public enum PDFImportError: Error, LocalizedError {
    case unreadable, noSuchPage, empty
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "This PDF could not be opened."
        case .noSuchPage: return "The PDF has no such page."
        case .empty: return "The page contains no vector lines. Scanned pages and pictures are not vectors: use Trace Image for those."
        }
    }
}

/// Reads the vector paths of one PDF page (lines, curves, rectangles, also inside form objects) as polylines in millimetres,
/// Y up, origin at the lower left corner of the page. Text is only read when the PDF stores it as outlines; pictures, shadings,
/// clipping and line widths are ignored (every path becomes its outline).
public enum PDFImport {
    public static func pageCount(of url: URL) -> Int {
        CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
    }

    public static func parse(contentsOf url: URL, page: Int = 1, tolerance: Double = 0.02) throws -> [Polyline] {
        guard let doc = CGPDFDocument(url as CFURL), !(doc.isEncrypted && !doc.isUnlocked) else { throw PDFImportError.unreadable }
        guard page >= 1, page <= doc.numberOfPages, let pg = doc.page(at: page) else { throw PDFImportError.noSuchPage }
        let box = pg.getBoxRect(.cropBox)
        let reader = Reader(tolerance: tolerance / (25.4 / 72))
        reader.ctm = .translate(-Double(box.minX), -Double(box.minY))
        let cs = CGPDFContentStreamCreateWithPage(pg)
        reader.scan(cs, depth: 0)
        let k = 25.4 / 72
        var lines = VectorMath.sanitized(VectorMath.transform(reader.output, .scale(k, k)))
        // a white background rectangle the size of the page is not artwork
        let w = Double(box.width) * k, h = Double(box.height) * k
        lines = lines.filter { l in
            guard l.closed, l.points.count <= 5 else { return true }
            let b = VectorMath.bounds([l])
            return !(b.width >= w * 0.98 && b.height >= h * 0.98)
        }
        guard !lines.isEmpty else { throw PDFImportError.empty }
        return lines
    }

    final class Reader {
        var ctm = Affine.identity
        var stack: [Affine] = []
        var path: [Polyline] = []
        var current: [Pt] = []
        var start = Pt(0, 0), last = Pt(0, 0)
        var output: [Polyline] = []
        var streams: [CGPDFContentStreamRef] = []
        let tolerance: Double
        var budget = 400_000

        init(tolerance: Double) { self.tolerance = tolerance }

        func scan(_ cs: CGPDFContentStreamRef, depth: Int) {
            guard depth < 8 else { return }
            let table = CGPDFOperatorTableCreate()!
            func on(_ name: String, _ f: @escaping CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(table, name, f) }
            on("m") { s, info in Reader.of(info).moveTo(s) }
            on("l") { s, info in Reader.of(info).lineTo(s) }
            on("c") { s, info in Reader.of(info).curve(s, kind: 0) }
            on("v") { s, info in Reader.of(info).curve(s, kind: 1) }
            on("y") { s, info in Reader.of(info).curve(s, kind: 2) }
            on("h") { _, info in Reader.of(info).close() }
            on("re") { s, info in Reader.of(info).rect(s) }
            on("cm") { s, info in Reader.of(info).concat(s) }
            on("q") { _, info in let r = Reader.of(info); r.stack.append(r.ctm) }
            on("Q") { _, info in let r = Reader.of(info); if let m = r.stack.popLast() { r.ctm = m } }
            for op in ["S", "f", "F", "f*", "B", "B*"] { on(op) { _, info in Reader.of(info).paint(close: false) } }
            for op in ["s", "b", "b*"] { on(op) { _, info in Reader.of(info).paint(close: true) } }
            on("n") { _, info in Reader.of(info).discard() }
            on("Do") { s, info in Reader.of(info).form(s) }
            streams.append(cs)
            defer { streams.removeLast() }
            let savedStack = stack
            let ptr = Unmanaged.passUnretained(self).toOpaque()
            let scanner = CGPDFScannerCreate(cs, table, ptr)
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            stack = savedStack
        }

        static func of(_ info: UnsafeMutableRawPointer?) -> Reader { Unmanaged<Reader>.fromOpaque(info!).takeUnretainedValue() }

        func numbers(_ s: CGPDFScannerRef, _ n: Int) -> [Double]? {
            var v = [Double](repeating: 0, count: n)
            for i in stride(from: n - 1, through: 0, by: -1) {
                var x: CGPDFReal = 0
                guard CGPDFScannerPopNumber(s, &x) else { return nil }
                v[i] = Double(x)
            }
            return v
        }

        func flush() {
            if current.count >= 2 { path.append(Polyline(current, closed: false)) }
            current = []
        }

        func moveTo(_ s: CGPDFScannerRef) {
            guard let v = numbers(s, 2) else { return }
            flush()
            start = ctm.apply(Pt(v[0], v[1])); last = start
            current = [start]
        }

        func lineTo(_ s: CGPDFScannerRef) {
            guard let v = numbers(s, 2) else { return }
            if current.isEmpty { current = [last] }
            last = ctm.apply(Pt(v[0], v[1]))
            current.append(last)
        }

        /// kind 0: c (two controls), 1: v (first control is the current point), 2: y (second control is the end point).
        func curve(_ s: CGPDFScannerRef, kind: Int) {
            guard let v = numbers(s, kind == 0 ? 6 : 4) else { return }
            if current.isEmpty { current = [last] }
            let p0 = last
            let c1: Pt, c2: Pt, p3: Pt
            switch kind {
            case 0: c1 = ctm.apply(Pt(v[0], v[1])); c2 = ctm.apply(Pt(v[2], v[3])); p3 = ctm.apply(Pt(v[4], v[5]))
            case 1: c1 = p0; c2 = ctm.apply(Pt(v[0], v[1])); p3 = ctm.apply(Pt(v[2], v[3]))
            default: c1 = ctm.apply(Pt(v[0], v[1])); p3 = ctm.apply(Pt(v[2], v[3])); c2 = p3
            }
            var pts: [Pt] = [p0]
            SVGPathData.cubic(p0, c1, c2, p3, .identity, tolerance, &pts)
            current.append(contentsOf: pts.dropFirst())
            last = p3
        }

        func close() {
            guard current.count >= 2 else { return }
            path.append(Polyline(current, closed: true))
            current = []
            last = start
        }

        func rect(_ s: CGPDFScannerRef) {
            guard let v = numbers(s, 4) else { return }
            flush()
            let x = v[0], y = v[1], w = v[2], h = v[3]
            path.append(Polyline([ctm.apply(Pt(x, y)), ctm.apply(Pt(x + w, y)), ctm.apply(Pt(x + w, y + h)), ctm.apply(Pt(x, y + h))], closed: true))
            start = ctm.apply(Pt(x, y)); last = start
        }

        func concat(_ s: CGPDFScannerRef) {
            guard let v = numbers(s, 6) else { return }
            ctm = ctm.concatenating(Affine(a: v[0], b: v[1], c: v[2], d: v[3], e: v[4], f: v[5]))
        }

        func paint(close closeFirst: Bool) {
            if closeFirst { close() } else { flush() }
            for p in path where budget > 0 {
                // a closed subpath that ends where it began does not need the duplicate point
                var q = p
                if q.closed, q.points.count > 2, let f = q.points.first, let l = q.points.last, f.distance(to: l) < 1e-9 { q.points.removeLast() }
                budget -= q.points.count
                output.append(q)
            }
            path = []; current = []
        }

        func discard() { path = []; current = [] }

        func form(_ s: CGPDFScannerRef) {
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(s, &name), let name, let parent = streams.last,
                  let obj = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(obj, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" else { return }
            var m = Affine.identity
            var arr: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict, "Matrix", &arr), let arr, CGPDFArrayGetCount(arr) == 6 {
                var v = [Double](repeating: 0, count: 6)
                for i in 0..<6 { var x: CGPDFReal = 0; CGPDFArrayGetNumber(arr, i, &x); v[i] = Double(x) }
                m = Affine(a: v[0], b: v[1], c: v[2], d: v[3], e: v[4], f: v[5])
            }
            var res: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dict, "Resources", &res)
            guard let child = CGPDFContentStreamCreateWithStream(stream, res ?? dict, parent) as CGPDFContentStreamRef? else { return }
            let savedCTM = ctm, savedPath = path, savedCurrent = current
            ctm = ctm.concatenating(m)
            path = []; current = []
            scan(child, depth: streams.count)
            ctm = savedCTM; path = savedPath; current = savedCurrent
        }
    }
}
