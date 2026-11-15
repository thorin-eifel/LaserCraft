import Foundation

/// Settings that belong to one laser machine. Loaded automatically when you connect to the port or network address it is tied to.
public struct MachineProfile: Codable, Equatable, Identifiable {
    public var id: String = UUID().uuidString
    public var name: String
    /// Port path (/dev/cu.usbserial-…) or network address (tcp://host:23) this laser is found at; empty = never automatic.
    public var connection = ""
    public var baud = 115200
    public var header = ""
    public var footer = ""
    public var rapidRate = 2000.0
    public var spotSize = 0.1                 // mm
    public var laserWatts = 0.0               // optical power, for information
    public var ratedHours = 10_000.0          // expected lifetime of the laser (diode: typically 10 000 h)
    public var notes = ""
    /// Material database model name used as the default filter, e.g. "Ortur LU7W (1.5W)".
    public var materialMachine = ""
    public var created = Date()
    /// Usage entries before this date belong to a previous laser (set by "Laser replaced").
    public var lifeStart = Date(timeIntervalSince1970: 0)
    public init(name: String) { self.name = name }
}

public struct UsageEntry: Codable, Equatable, Identifiable {
    public var id: String = UUID().uuidString
    public var profileID: String
    public var date: Date
    public var job: String
    /// Wall-clock seconds the job ran.
    public var seconds: Double
    /// Estimated seconds with the laser switched on, and the same weighted by power (full-power equivalent).
    public var laserSeconds: Double
    public var fullPowerSeconds: Double
    public var lines: Int
    public var outcome: Outcome
    public enum Outcome: String, Codable { case finished, stopped, failed }
    public init(profileID: String, date: Date = Date(), job: String, seconds: Double, laserSeconds: Double, fullPowerSeconds: Double,
                lines: Int, outcome: Outcome) {
        self.profileID = profileID; self.date = date; self.job = job; self.seconds = seconds
        self.laserSeconds = laserSeconds; self.fullPowerSeconds = fullPowerSeconds; self.lines = lines; self.outcome = outcome
    }
}

public struct UsageSummary: Equatable {
    public var jobs = 0, finished = 0
    public var totalHours = 0.0
    public var laserHours = 0.0
    /// "True laser time": hours the laser was on, weighted with the power used.
    public var fullPowerHours = 0.0
    public var remainingHours = 0.0
    /// 0...1+ of the rated life used.
    public var lifeUsed = 0.0
}

/// Profiles and the usage log, kept as JSON files.
public final class ProfileStore {
    public private(set) var profiles: [MachineProfile] = []
    public private(set) var usage: [UsageEntry] = []
    let profilesFile: URL?, usageFile: URL?

    public init(directory: URL?) {
        profilesFile = directory?.appendingPathComponent("profiles.json")
        usageFile = directory?.appendingPathComponent("usage.json")
        if let d = directory { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let f = profilesFile, let d = try? Data(contentsOf: f), let p = try? dec.decode([MachineProfile].self, from: d) { profiles = p }
        if let f = usageFile, let d = try? Data(contentsOf: f), let u = try? dec.decode([UsageEntry].self, from: d) { usage = u }
    }

    private func save<T: Encodable>(_ v: T, to f: URL?) {
        guard let f = f else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(v).write(to: f, options: .atomic)
    }

    // MARK: profiles

    public func upsert(_ p: MachineProfile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        save(profiles, to: profilesFile)
    }

    public func delete(id: String) {
        profiles.removeAll { $0.id == id }
        save(profiles, to: profilesFile)
    }

    public func profile(id: String?) -> MachineProfile? { profiles.first { $0.id == id } }

    /// The profile tied to this port or address.
    public func profile(forConnection c: String) -> MachineProfile? {
        profiles.first { !$0.connection.isEmpty && $0.connection == c }
    }

    // MARK: usage

    public func record(_ e: UsageEntry) {
        usage.append(e)
        if usage.count > 5000 { usage.removeFirst(usage.count - 5000) }
        save(usage, to: usageFile)
    }

    public func clearUsage(profileID: String) {
        usage.removeAll { $0.profileID == profileID }
        save(usage, to: usageFile)
    }

    public func history(profileID: String? = nil, limit: Int = 50) -> [UsageEntry] {
        Array(usage.filter { profileID == nil || $0.profileID == profileID }.sorted { $0.date > $1.date }.prefix(limit))
    }

    public func summary(for p: MachineProfile) -> UsageSummary {
        var s = UsageSummary()
        for e in usage where e.profileID == p.id && e.date >= p.lifeStart {
            s.jobs += 1
            if e.outcome == .finished { s.finished += 1 }
            s.totalHours += e.seconds / 3600
            s.laserHours += e.laserSeconds / 3600
            s.fullPowerHours += e.fullPowerSeconds / 3600
        }
        s.remainingHours = max(0, p.ratedHours - s.fullPowerHours)
        s.lifeUsed = p.ratedHours > 0 ? s.fullPowerHours / p.ratedHours : 0
        return s
    }

    /// Marks the laser as replaced: the counters start again from now.
    public func laserReplaced(id: String, at date: Date = Date()) {
        guard var p = profile(id: id) else { return }
        p.lifeStart = date
        upsert(p)
    }

    /// Builds the entry for a job from the program's estimates, scaled to the part that really ran.
    public static func entry(profileID: String, program: GCodeProgram?, executedCommands: Int, seconds: Double, aborted: Bool, errors: Int,
                             maxS: Double, name: String) -> UsageEntry {
        var laser = 0.0, full = 0.0
        if let p = program, !p.commands.isEmpty {
            let i = min(max(0, executedCommands - 1), p.cumulativeBurnSeconds.count - 1)
            if i >= 0 {
                laser = Double(p.cumulativeBurnSeconds[i])
                full = maxS > 0 ? p.cumulativeBurnPowerSeconds[i] / maxS : 0
            }
        }
        let outcome: UsageEntry.Outcome = aborted ? (errors > 0 ? .failed : .stopped) : .finished
        return UsageEntry(profileID: profileID, job: name, seconds: seconds, laserSeconds: laser, fullPowerSeconds: full,
                          lines: executedCommands, outcome: outcome)
    }
}
