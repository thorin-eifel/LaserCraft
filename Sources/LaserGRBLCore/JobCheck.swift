import Foundation

/// A problem found before a job starts. Shown in the start dialog; never blocks by itself.
public struct JobWarning: Equatable {
    public enum Kind: Equatable { case boundary, laserMode, power, speed }
    public var kind: Kind
    public var text: String
    public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
}

/// Plausibility checks of a loaded job against what the machine reported (`$$`).
public enum JobCheck {
    private static func number(_ settings: [Int: String], _ key: Int) -> Double? {
        settings[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// - Parameters:
    ///   - settings: the `$n` values read from the machine (empty when unknown: then nothing is claimed).
    ///   - workOffset: the work coordinate offset (WCO) of the machine, when known.
    public static func run(program: GCodeProgram, settings: [Int: String], workOffset: Point3?) -> [JobWarning] {
        var out: [JobWarning] = []

        // 1. does the job fit on the machine?
        if let maxX = number(settings, 130), let maxY = number(settings, 131), maxX > 0, maxY > 0, !program.travelBounds.isEmpty {
            let b = program.travelBounds
            if b.width > maxX + 0.01 {
                out.append(JobWarning(.boundary, L("The job is %.1f mm wider than the machine's travel (%.0f mm).", b.width - maxX, maxX)))
            }
            if b.height > maxY + 0.01 {
                out.append(JobWarning(.boundary, L("The job is %.1f mm taller than the machine's travel (%.0f mm).", b.height - maxY, maxY)))
            }
            // 2. where is it? Only meaningful with soft limits: Grbl then keeps the machine inside [-travel, 0].
            if number(settings, 20) == 1, let wco = workOffset {
                let lowX = -maxX - wco.x, highX = -wco.x, lowY = -maxY - wco.y, highY = -wco.y
                if b.maxX > highX + 0.01 { out.append(JobWarning(.boundary, L("The job reaches %.1f mm beyond the right edge of the machine area.", b.maxX - highX))) }
                if b.minX < lowX - 0.01 { out.append(JobWarning(.boundary, L("The job reaches %.1f mm beyond the left edge of the machine area.", lowX - b.minX))) }
                if b.maxY > highY + 0.01 { out.append(JobWarning(.boundary, L("The job reaches %.1f mm beyond the top edge of the machine area.", b.maxY - highY))) }
                if b.minY < lowY - 0.01 { out.append(JobWarning(.boundary, L("The job reaches %.1f mm beyond the bottom edge of the machine area.", lowY - b.minY))) }
            }
        }

        // 3. laser mode
        if number(settings, 32) == 0, program.usesM4 || program.maxPower > 0 {
            out.append(JobWarning(.laserMode, L("Laser mode ($32) is off: the laser stays on during travel moves and M4 does not change the power dynamically. Turn it on in the Grbl configuration.")))
        }

        // 4. power
        if let smax = number(settings, 30), smax > 0, Double(program.maxPower) > smax + 0.5 {
            out.append(JobWarning(.power, L("The job uses power up to S%d, but the machine's maximum ($30) is %d. Higher values are limited.", Int(program.maxPower), Int(smax))))
        }

        // 5. speed
        let rates = [number(settings, 110), number(settings, 111)].compactMap { $0 }.filter { $0 > 0 }
        if let maxRate = rates.min(), program.maxFeed > maxRate * 1.001 {
            out.append(JobWarning(.speed, L("The job asks for speeds up to %d mm/min, faster than the machine's maximum of %d mm/min ($110/$111). Grbl will limit them.", Int(program.maxFeed), Int(maxRate))))
        }
        return out
    }

    /// Does the whole job lie inside the machine's size? (For drawing the machine area in red.)
    public static func exceedsMachine(program: GCodeProgram, settings: [Int: String]) -> Bool {
        run(program: program, settings: settings, workOffset: nil).contains { $0.kind == .boundary }
    }
}
