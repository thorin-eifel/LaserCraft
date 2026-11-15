import Foundation

/// Text for the "Save Console Log" and "Copy Diagnostic Report" commands.
public enum Diagnostics {
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// One line per console entry: `[12:03:41.250] > G0 X10`.
    public static func consoleText(_ lines: [ConsoleLine]) -> String {
        lines.map { line in
            let mark: String
            switch line.kind {
            case .sent: mark = ">"
            case .received: mark = "<"
            case .info: mark = "i"
            case .error: mark = "!"
            }
            return "[\(clock.string(from: line.date))] \(mark) \(line.text)"
        }.joined(separator: "\n")
    }

    /// Everything a bug report needs: versions, machine settings, job state and the last console lines.
    /// Contains no file contents and no personal data besides the serial port name.
    public static func report(appVersion: String, system: String, port: String, baud: Int,
                              controller: GrblController, consoleLines: Int = 200) -> String {
        var out: [String] = []
        out.append("LaserCraft diagnostic report")
        out.append("App version:   \(appVersion)")
        out.append("System:        \(system)")
        out.append("Grbl version:  \(controller.version?.description ?? "unknown")")
        out.append("Port / baud:   \(port.isEmpty ? "-" : port) / \(baud)")
        out.append("State:         \(controller.state.rawValue)\(controller.lastAlarm.map { " (last alarm: \($0))" } ?? "")")
        out.append("Position:      MPos X\(String(format: "%.3f", controller.machinePosition.x)) Y\(String(format: "%.3f", controller.machinePosition.y))"
                   + "  WCO X\(String(format: "%.3f", controller.workOffset.x)) Y\(String(format: "%.3f", controller.workOffset.y))")
        if let p = controller.program {
            out.append("Job:           \(p.commands.count) lines, \(controller.jobExecuted)/\(controller.jobTarget) done, \(controller.jobErrors) errors, "
                       + "running: \(controller.jobRunning)")
            if !p.travelBounds.isEmpty {
                out.append("Job bounds:    X \(String(format: "%.1f", p.travelBounds.minX))…\(String(format: "%.1f", p.travelBounds.maxX)), "
                           + "Y \(String(format: "%.1f", p.travelBounds.minY))…\(String(format: "%.1f", p.travelBounds.maxY)) mm, "
                           + "max S \(Int(p.maxPower)), max F \(Int(p.maxFeed))")
            }
            let warnings = JobCheck.run(program: p, settings: controller.settings, workOffset: controller.workOffset)
            if !warnings.isEmpty { out.append("Warnings:      " + warnings.map { $0.text }.joined(separator: " | ")) }
        } else {
            out.append("Job:           none loaded")
        }
        out.append("")
        out.append("Grbl settings ($$):")
        if controller.settings.isEmpty { out.append("  (not read)") }
        for key in controller.settings.keys.sorted() { out.append("  $\(key)=\(controller.settings[key] ?? "")") }
        out.append("")
        out.append("Last console lines:")
        out.append(consoleText(Array(controller.console.suffix(consoleLines))))
        return out.joined(separator: "\n") + "\n"
    }
}
