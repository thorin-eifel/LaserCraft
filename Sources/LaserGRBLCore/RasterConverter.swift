import Foundation
import CoreGraphics

/// Plain RGBA bitmap (8 bits per channel, row 0 at the top).
public struct RasterImage {
    public var width: Int
    public var height: Int
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width; self.height = height; self.rgba = rgba
    }

    /// Draws `image` into a bitmap of the given size, composited over white.
    public init?(cgImage image: CGImage, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        var buf = [UInt8](repeating: 255, count: width * height * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        self.init(width: width, height: height, rgba: buf)
    }
}

public enum GrayFormula: String, CaseIterable, Identifiable {
    case simpleAverage = "Simple average"
    case weightedAverage = "Weighted average"
    case opticalCorrect = "Optical correct"
    case custom = "Custom"
    public var id: String { rawValue }
}

public enum DitherMode: String, CaseIterable, Identifiable {
    case atkinson = "Atkinson", floydSteinberg = "Floyd-Steinberg", burkes = "Burkes", jarvis = "Jarvis-Judice-Ninke"
    case random = "Random", sierra2 = "Sierra 2", sierra3 = "Sierra 3", sierraLite = "Sierra Lite", stucki = "Stucki"
    public var id: String { rawValue }

    /// (dx, dy, weight) rows plus divisor, as in the Windows dithering classes.
    var kernel: (taps: [(Int, Int, Int)], divisor: Int) {
        switch self {
        case .floydSteinberg: return ([(1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)], 16)
        case .atkinson: return ([(1, 0, 1), (2, 0, 1), (-1, 1, 1), (0, 1, 1), (1, 1, 1), (0, 2, 1)], 8)
        case .burkes: return ([(1, 0, 8), (2, 0, 4), (-2, 1, 2), (-1, 1, 4), (0, 1, 8), (1, 1, 4), (2, 1, 2)], 32)
        case .jarvis: return ([(1, 0, 7), (2, 0, 5), (-2, 1, 3), (-1, 1, 5), (0, 1, 7), (1, 1, 5), (2, 1, 3),
                               (-2, 2, 1), (-1, 2, 3), (0, 2, 5), (1, 2, 3), (2, 2, 1)], 48)
        case .sierra2: return ([(1, 0, 4), (2, 0, 3), (-2, 1, 1), (-1, 1, 2), (0, 1, 3), (1, 1, 2), (2, 1, 1)], 16)
        case .sierra3: return ([(1, 0, 5), (2, 0, 3), (-2, 1, 2), (-1, 1, 4), (0, 1, 5), (1, 1, 4), (2, 1, 2),
                                (-1, 2, 2), (0, 2, 3), (1, 2, 2)], 32)
        case .sierraLite: return ([(1, 0, 2), (-1, 1, 1), (0, 1, 1)], 4)
        case .stucki: return ([(1, 0, 8), (2, 0, 4), (-2, 1, 2), (-1, 1, 4), (0, 1, 8), (1, 1, 4), (2, 1, 2),
                               (-2, 2, 1), (-1, 2, 2), (0, 2, 4), (1, 2, 2), (2, 2, 1)], 42)
        case .random: return ([], 1)
        }
    }
}

public enum FillDirection: String, CaseIterable, Identifiable {
    case horizontal = "Horizontal", vertical = "Vertical", diagonal = "Diagonal"
    public var id: String { rawValue }
}

public enum RasterTool: String, CaseIterable, Identifiable {
    case lineToLine = "Line to line", dithering = "1 bit dithering"
    public var id: String { rawValue }
}

/// Image-to-engraving settings; defaults follow the Windows import window.
public struct RasterOptions {
    public var tool: RasterTool = .lineToLine
    public var formula: GrayFormula = .opticalCorrect
    public var red = 100, green = 100, blue = 100        // 40...160, custom formula only
    public var brightness = 100, contrast = 100          // 40...160
    public var whiteClip = 5                             // 0...20
    public var invert = false
    public var dithering: DitherMode = .floydSteinberg
    public var direction: FillDirection = .horizontal
    public var unidirectional = false
    public var linesPerMM = 3.0                          // "quality"
    public var widthMM = 100.0, heightMM = 100.0
    public var offsetX = 0.0, offsetY = 0.0
    public var markSpeed = 1000
    public var minPower = 0, maxPower = 1000
    public var laserOn = "M3", laserOff = "M5"
    public var pwm = true
    public var slowSkip = false                          // use G1 instead of G0 when skipping white
    public init() {}
}

public enum RasterConverter {

    // MARK: image processing

    /// Grayscale (0 black ... 255 white) after formula, brightness, contrast, white clip, invert, dither.
    public static func grayscale(_ img: RasterImage, _ o: RasterOptions) -> [UInt8] {
        var rf: Float, gf: Float, bf: Float
        switch o.formula {
        case .simpleAverage: (rf, gf, bf) = (0.333, 0.333, 0.333)
        case .weightedAverage: (rf, gf, bf) = (0.333, 0.444, 0.222)
        case .opticalCorrect: (rf, gf, bf) = (0.299, 0.587, 0.114)
        case .custom: (rf, gf, bf) = (0.333 * Float(o.red) / 100, 0.333 * Float(o.green) / 100, 0.333 * Float(o.blue) / 100)
        }
        let contrast = Float(o.contrast) / 100
        rf *= contrast; gf *= contrast; bf *= contrast
        let offset = -(Float(100 - o.brightness) / 100)
        let n = img.width * img.height
        var g = [UInt8](repeating: 255, count: n)
        for p in 0..<n {
            let r = Float(img.rgba[p * 4]) / 255, gr = Float(img.rgba[p * 4 + 1]) / 255, b = Float(img.rgba[p * 4 + 2]) / 255
            var v = (r * rf + gr * gf + b * bf + offset) * 255
            v = min(255, max(0, v))
            var byte = UInt8(v.rounded())
            if o.whiteClip > 0 && Int(byte) > 255 - o.whiteClip { byte = 255 }
            if o.invert { byte = 255 - byte }
            g[p] = byte
        }
        return g
    }

    /// Error-diffusion dithering to pure black/white.
    public static func dither(_ gray: [UInt8], width: Int, height: Int, mode: DitherMode) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: gray.count)
        if mode == .random {
            var rng = SystemRandomNumberGenerator()
            for i in 0..<gray.count { out[i] = Int(gray[i]) > Int.random(in: 0...255, using: &rng) ? 255 : 0 }
            return out
        }
        let k = mode.kernel
        var work = gray.map { Int($0) }
        for y in 0..<height {
            for x in 0..<width {
                let old = work[y * width + x]
                let new = old < 128 ? 0 : 255
                out[y * width + x] = UInt8(new)
                let err = old - new
                if err == 0 { continue }
                for (dx, dy, w) in k.taps {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < width, ny < height { work[ny * width + nx] += err * w / k.divisor }
                }
            }
        }
        return out
    }

    // MARK: g-code generation

    private enum Kind { case x, y, d, vsep, hsep }
    private struct Seg { var kind: Kind; var color: Int; var len: Int; var reverse: Bool }

    private static func format(_ v: Double) -> String {
        var r = (v * 1000).rounded() / 1000
        if r == 0 { r = 0 }   // avoid "-0"
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.3f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    /// Builds the engraving program (without header/footer) from a bitmap already sized to
    /// `widthMM * linesPerMM` by `heightMM * linesPerMM` pixels.
    public static func generate(bitmap: RasterImage, options o: RasterOptions) -> String {
        var gray = grayscale(bitmap, o)
        if o.tool == .dithering { gray = dither(gray, width: bitmap.width, height: bitmap.height, mode: o.dithering) }
        return generate(gray: gray, width: bitmap.width, height: bitmap.height, options: o)
    }

    static func generate(gray: [UInt8], width w: Int, height h: Int, options o: RasterOptions) -> String {
        let res = o.linesPerMM
        let skip = o.slowSkip ? "G1" : "G0"

        // Row 0 of the output is the bottom of the picture (Y grows upwards on the machine).
        func color(_ x: Int, _ y: Int) -> Int {
            let v = 255 - Int(gray[(h - 1 - y) * w + x])
            if v == 0 { return 0 }
            return o.pwm ? v * (o.maxPower - o.minPower) / 255 + o.minPower : v
        }
        func fast(_ c: Int) -> Bool { o.pwm ? c == 0 : c <= 125 }

        // 1. cut the bitmap into runs of equal power
        var segs: [Seg] = []
        let uni = o.unidirectional
        func extract(_ x: Int, _ y: Int, _ rev: Bool, _ len: inout Int, _ prev: inout Int) {
            len += 1
            let c = color(x, y)
            if prev == -1 { prev = c }
            if prev != c {
                let k: Kind = o.direction == .horizontal ? .x : (o.direction == .vertical ? .y : .d)
                segs.append(Seg(kind: k, color: prev, len: len, reverse: rev))
                len = 0
            }
            prev = c
        }

        switch o.direction {
        case .horizontal, .vertical:
            let hz = o.direction == .horizontal
            let lines = hz ? h : w, cells = hz ? w : h
            for i in 0..<lines {
                let d = uni || i % 2 == 0
                var prev = -1, len = -1
                var j = d ? 0 : cells - 1
                while d ? j < cells : j >= 0 {
                    extract(hz ? j : i, hz ? i : j, !d, &len, &prev)
                    j += d ? 1 : -1
                }
                segs.append(Seg(kind: hz ? .x : .y, color: prev, len: len + 1, reverse: !d))
                if uni { segs.append(Seg(kind: hz ? .x : .y, color: 0, len: cells, reverse: true)) }
                if i < lines - 1 { segs.append(Seg(kind: hz ? .vsep : .hsep, color: 0, len: 1, reverse: false)) }
            }
        case .diagonal:
            segs.append(Seg(kind: .vsep, color: 0, len: 1, reverse: false))
            for slice in 0..<(w + h - 1) {
                let d = uni || slice % 2 == 0
                var prev = -1, len = -1
                let z1 = slice < h ? 0 : slice - h + 1
                let z2 = slice < w ? 0 : slice - w + 1
                var j = d ? z1 : slice - z2
                while d ? j <= slice - z2 : j >= z1 {
                    extract(j, slice - j, !d, &len, &prev)
                    j += d ? 1 : -1
                }
                segs.append(Seg(kind: .d, color: prev, len: len + 1, reverse: !d))
                if uni { segs.append(Seg(kind: .d, color: 0, len: (slice - z1 - z2) + 1, reverse: true)) }
                if slice < min(w, h) - 1 {
                    segs.append(Seg(kind: (d && !uni) ? .hsep : .vsep, color: 0, len: 1, reverse: false))
                } else if slice >= max(w, h) - 1 {
                    segs.append(Seg(kind: (d && !uni) ? .vsep : .hsep, color: 0, len: 1, reverse: false))
                } else {
                    segs.append(Seg(kind: w > h ? .hsep : .vsep, color: 0, len: 1, reverse: false))
                }
            }
        }

        // 2. turn runs into g-code text
        var cumX = 0, cumY = 0
        var isFast = true
        var cmds: [String] = []
        func fx(_ n: Int) -> String { format(Double(n) / res + o.offsetX) }
        func fy(_ n: Int) -> String { format(Double(n) / res + o.offsetY) }
        func power(_ c: Int) -> String { "S\(c)" }

        for s in segs {
            let sep = s.kind == .vsep || s.kind == .hsep
            let f = sep ? true : fast(s.color)
            let change = isFast != f
            if sep && !isFast { cmds.append(o.pwm ? "S0" : o.laserOff) }
            isFast = f
            let len = s.reverse ? -s.len : s.len
            var body: String
            let tail = o.pwm ? power(s.color) : (f ? o.laserOff : o.laserOn)
            switch s.kind {
            case .x: cumX += len; body = "X\(fx(cumX)) \(tail)"
            case .y: cumY += len; body = "Y\(fy(cumY)) \(tail)"
            case .d: cumX += len; cumY -= len; body = "X\(fx(cumX)) Y\(fy(cumY)) \(tail)"
            case .vsep: cumY += 1; body = "Y\(fy(cumY))"
            case .hsep: cumX += 1; body = "X\(fx(cumX))"
            }
            cmds.append(change ? "\(f ? skip : "G1") \(body)" : body)
        }

        // 3. drop travel moves made while the laser is off, keep only the final position
        var out: [String] = []
        var curX = o.offsetX, curY = o.offsetY
        var cumulate = false
        for c in cmds {
            let old = cumulate
            let ws = GCodeProgram.words(of: c)
            let sWord = ws.first { $0.letter == "S" }
            if o.pwm {
                if let sv = sWord { cumulate = sv.value == 0 }
            } else {
                if c.contains(o.laserOff) { cumulate = true } else if c.contains(o.laserOn) { cumulate = false }
            }
            if old && !cumulate {
                out.append(o.pwm ? "\(skip) X\(format(curX)) Y\(format(curY)) S0"
                                 : "\(skip) X\(format(curX)) Y\(format(curY)) \(o.laserOff)")
            }
            let hasX = ws.first { $0.letter == "X" }, hasY = ws.first { $0.letter == "Y" }
            let isMove = hasX != nil || hasY != nil
            if isMove {
                if let v = hasX { curX = v.value }
                if let v = hasY { curY = v.value }
            }
            if !isMove || !cumulate { out.append(c) }
        }

        // 4. preamble and closing
        var head: [String] = ["\(skip) X\(format(o.offsetX)) Y\(format(o.offsetY)) F\(o.markSpeed)"]
        head.append(o.pwm ? "\(o.laserOn) S0" : "\(o.laserOff) S\(o.maxPower)")
        return (head + out + [o.laserOff]).joined(separator: "\n")
    }

    // MARK: end to end

    /// Number of pixels the bitmap needs for the chosen size and quality.
    public static func pixelSize(_ o: RasterOptions) -> (Int, Int) {
        (max(1, Int(o.widthMM * o.linesPerMM)), max(1, Int(o.heightMM * o.linesPerMM)))
    }

    public static func generate(image: CGImage, options o: RasterOptions) -> String? {
        let (w, h) = pixelSize(o)
        guard w * h <= 40_000_000, let bmp = RasterImage(cgImage: image, width: w, height: h) else { return nil }
        return generate(bitmap: bmp, options: o)
    }

    /// Greyscale preview of what will be engraved (dark = more power), same size as the bitmap.
    public static func previewBitmap(_ img: RasterImage, _ o: RasterOptions) -> RasterImage {
        var gray = grayscale(img, o)
        if o.tool == .dithering { gray = dither(gray, width: img.width, height: img.height, mode: o.dithering) }
        var rgba = [UInt8](repeating: 255, count: gray.count * 4)
        for i in 0..<gray.count {
            rgba[i * 4] = gray[i]; rgba[i * 4 + 1] = gray[i]; rgba[i * 4 + 2] = gray[i]
        }
        return RasterImage(width: img.width, height: img.height, rgba: rgba)
    }
}

public extension RasterImage {
    func makeCGImage() -> CGImage? {
        var data = rgba
        return data.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let ctx = CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
}
