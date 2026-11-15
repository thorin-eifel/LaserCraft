import Foundation

/// Generators for calibration and test jobs. All return plain G-code lines (origin = work zero, lower left corner).
public enum TestPatterns {

    // MARK: Power vs. speed

    public struct PowerSpeedGrid: Equatable {
        public var speedMin = 500.0, speedMax = 3000.0, speedSteps = 6     // mm/min, columns
        public var powerMin = 10.0, powerMax = 100.0, powerSteps = 6       // percent, rows
        public var cell = 8.0, gap = 2.0                                   // mm
        public var lineSpacing = 0.1                                       // mm between engraved lines in a cell
        public var passes = 1
        public var dynamicPower = true
        public init() {}

        public func speed(column: Int) -> Double { value(speedMin, speedMax, speedSteps, column) }
        public func power(row: Int) -> Double { value(powerMin, powerMax, powerSteps, row) }
        private func value(_ lo: Double, _ hi: Double, _ n: Int, _ i: Int) -> Double {
            n <= 1 ? lo : lo + (hi - lo) * Double(i) / Double(n - 1)
        }
        public var width: Double { Double(speedSteps) * cell + Double(max(0, speedSteps - 1)) * gap }
        public var height: Double { Double(powerSteps) * cell + Double(max(0, powerSteps - 1)) * gap }
    }

    /// A matrix of filled squares: speed grows to the right, power grows upwards.
    public static func powerVsSpeed(_ g: PowerSpeedGrid, maxS: Double = 1000, labels: Bool = true) -> [String] {
        var out = ["G21", "G90"]
        let on = g.dynamicPower ? "M4" : "M3"
        for row in 0..<g.powerSteps {
            for col in 0..<g.speedSteps {
                let x0 = Double(col) * (g.cell + g.gap), y0 = Double(row) * (g.cell + g.gap)
                let sq = Polyline([Pt(x0, y0), Pt(x0 + g.cell, y0), Pt(x0 + g.cell, y0 + g.cell), Pt(x0, y0 + g.cell)], closed: true)
                var s = VectorSettings()
                s.mode = .fill; s.speed = g.speed(column: col); s.powerPercent = g.power(row: row)
                s.fillSpacing = g.lineSpacing; s.passes = g.passes; s.dynamicPower = g.dynamicPower
                out.append("; speed \(VectorJob.fmt(s.speed)) power \(VectorJob.fmt(s.powerPercent))%")
                _ = on
                out += VectorJob.gcode([sq], s, maxS: maxS, header: false).dropLast(2)
            }
        }
        if labels {
            // small single-stroke numbers below and left of the matrix, burnt at low power and medium speed
            var t = VectorSettings(); t.speed = 1500; t.powerPercent = 15; t.dynamicPower = g.dynamicPower
            var shapes: [Polyline] = []
            for col in 0..<g.speedSteps {
                var spec = TextSpec(); spec.text = "\(Int(g.speed(column: col).rounded()))"; spec.size = 2.2
                let x = Double(col) * (g.cell + g.gap)
                shapes += VectorMath.transform(TextLayout.polylines(spec), .translate(x, -4))
            }
            for row in 0..<g.powerSteps {
                var spec = TextSpec(); spec.text = "\(Int(g.power(row: row).rounded()))"; spec.size = 2.2
                let b = VectorMath.bounds(TextLayout.polylines(spec))
                shapes += VectorMath.transform(TextLayout.polylines(spec), .translate(-b.width - 2, Double(row) * (g.cell + g.gap) + g.cell / 2 - 1.1))
            }
            out += VectorJob.gcode(shapes, t, maxS: maxS, header: false)
        } else { out += ["M5", "S0"] }
        return out
    }

    // MARK: Cutting test

    public struct CuttingGrid: Equatable {
        public var speeds: [Double] = [100, 200, 300, 400, 600]     // mm/min, columns
        public var passes: [Int] = [1, 2, 3]                        // rows
        public var powerPercent = 100.0
        public var size = 10.0, gap = 4.0
        public var dynamicPower = true
        public init() {}
    }

    /// Squares cut with different speeds (columns) and numbers of passes (rows). The squares that fall out show what cuts through.
    public static func cuttingTest(_ g: CuttingGrid, maxS: Double = 1000) -> [String] {
        var out = ["G21", "G90"]
        for (r, passes) in g.passes.enumerated() {
            for (c, speed) in g.speeds.enumerated() {
                let x0 = Double(c) * (g.size + g.gap), y0 = Double(r) * (g.size + g.gap)
                let sq = Polyline([Pt(x0, y0), Pt(x0 + g.size, y0), Pt(x0 + g.size, y0 + g.size), Pt(x0, y0 + g.size)], closed: true)
                var s = VectorSettings(); s.speed = speed; s.passes = passes; s.powerPercent = g.powerPercent; s.dynamicPower = g.dynamicPower
                out.append("; speed \(VectorJob.fmt(speed)) passes \(passes)")
                out += VectorJob.gcode([sq], s, maxS: maxS, header: false).dropLast(2)
            }
        }
        return out + ["M5", "S0"]
    }

    /// Kerf (width of the cut) from a test: cut a square of `nominal` mm and measure the piece that falls out.
    /// The beam removes `nominal - measured` of material, so the path needs to be offset by half of it.
    public static func kerf(nominal: Double, measuredPiece: Double) -> (kerf: Double, offset: Double) {
        let k = max(0, nominal - measuredPiece)
        return (k, k / 2)
    }

    // MARK: Shake test

    public struct Shake: Equatable {
        public var feeds: [Double] = [1000, 2000, 3000, 4000, 6000]
        public var length = 20.0, repeats = 10, lineGap = 3.0
        public var powerPercent = 8.0
        public var dynamicPower = true
        public init() {}
    }

    /// Short zig-zags back and forth at growing feed rates, drawn with weak laser power. If the machine loses steps or
    /// shakes, the line becomes wavy or jumps sideways at that feed.
    public static func shakeTest(_ s: Shake, maxS: Double = 1000) -> [String] {
        var out = ["G21", "G90"]
        let power = Int((s.powerPercent / 100 * maxS).rounded())
        for (i, f) in s.feeds.enumerated() {
            let y = Double(i) * s.lineGap
            out.append("; feed \(VectorJob.fmt(f))")
            out += ["M5", "G0 X0 Y\(VectorJob.fmt(y))", "\(s.dynamicPower ? "M4" : "M3") S\(power)"]
            for r in 0..<s.repeats {
                out.append("G1 X\(VectorJob.fmt(r % 2 == 0 ? s.length : 0)) Y\(VectorJob.fmt(y + (r % 2 == 0 ? 0.0 : 0.0))) F\(VectorJob.fmt(f))")
            }
        }
        return out + ["M5", "S0"]
    }

    /// A first guess for the acceleration setting ($120/$121, mm/s²) from the highest clean feed of the shake test:
    /// the machine has to reach that speed within the stroke length. Start at 80 % of it and test again.
    public static func accelerationEstimate(cleanFeed: Double, stroke: Double) -> Double {
        guard stroke > 0 else { return 0 }
        let v = cleanFeed / 60
        return v * v / (2 * stroke) * 0.8
    }

    // MARK: Resolution / focus test

    /// Blocks of hatch lines with a decreasing line distance; the finest block that still shows separate lines
    /// is your usable resolution, a sharp narrow line shows good focus.
    public static func resolutionTest(spacings: [Double] = [0.3, 0.2, 0.15, 0.1, 0.07, 0.05], width: Double = 15, height: Double = 8,
                                      speed: Double = 1500, powerPercent: Double = 30, dynamicPower: Bool = true, maxS: Double = 1000) -> [String] {
        var out = ["G21", "G90"]
        for (i, sp) in spacings.enumerated() {
            let x0 = Double(i) * (width + 3)
            let sq = Polyline([Pt(x0, 0), Pt(x0 + width, 0), Pt(x0 + width, height), Pt(x0, height)], closed: true)
            var s = VectorSettings(); s.mode = .fill; s.speed = speed; s.powerPercent = powerPercent
            s.fillSpacing = sp; s.fillAngle = 90; s.dynamicPower = dynamicPower
            out.append("; line distance \(VectorJob.fmt(sp)) mm")
            out += VectorJob.gcode([sq], s, maxS: maxS, header: false).dropLast(2)
        }
        return out + ["M5", "S0"]
    }

    // MARK: Calibration square

    /// A square burnt with low power; measure its sides afterwards.
    public static func calibrationSquare(size: Double = 100, speed: Double = 1500, powerPercent: Double = 10, dynamicPower: Bool = true, maxS: Double = 1000) -> [String] {
        let sq = Polyline([Pt(0, 0), Pt(size, 0), Pt(size, size), Pt(0, size)], closed: true)
        var s = VectorSettings(); s.speed = speed; s.powerPercent = powerPercent; s.dynamicPower = dynamicPower
        s.optimize.reorder = false; s.optimize.insideFirst = false
        return VectorJob.gcode([sq], s, maxS: maxS)
    }

    /// New steps/mm for $100 / $101: `current × asked / measured`.
    public static func stepsPerMM(current: Double, asked: Double, measured: Double) -> Double? {
        guard current > 0, asked > 0, measured > 0 else { return nil }
        return (current * asked / measured * 1000).rounded() / 1000
    }
}
