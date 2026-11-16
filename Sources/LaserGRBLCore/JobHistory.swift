import Foundation

public struct JobRecord: Codable, Equatable, Identifiable {
    public var id: String = UUID().uuidString
    public var date: Date
    public var name: String
    public var seconds: Double
    public var outcome: UsageEntry.Outcome
    public var machine: String
    public var lines: Int
    public var errors: Int
    /// Material or layer note, free text.
    public var material: String?
    public var hasGCode = false
    public var hasThumbnail = false

    public init(date: Date = Date(), name: String, seconds: Double, outcome: UsageEntry.Outcome, machine: String, lines: Int, errors: Int, material: String? = nil) {
        self.date = date; self.name = name; self.seconds = seconds; self.outcome = outcome; self.machine = machine
        self.lines = lines; self.errors = errors; self.material = material
    }
}

/// The last jobs with a copy of their G-code (so that they can be opened again even when the file has moved) and a small picture.
public final class JobHistoryStore {
    public private(set) var records: [JobRecord] = []
    let directory: URL?
    public let limit: Int
    /// Largest G-code copy kept per job.
    static let maxGCodeBytes = 20_000_000

    public init(directory: URL?, limit: Int = 40) {
        self.directory = directory
        self.limit = limit
        if let d = directory {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let data = try? Data(contentsOf: d.appendingPathComponent("history.json")), let r = try? dec.decode([JobRecord].self, from: data) { records = r }
        }
    }

    private func save() {
        guard let d = directory else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(records).write(to: d.appendingPathComponent("history.json"), options: .atomic)
    }

    private func file(_ id: String, _ ext: String) -> URL? { directory?.appendingPathComponent("\(id).\(ext)") }

    /// Newest first.
    @discardableResult
    public func add(_ record: JobRecord, gcode: String?, thumbnail: Data?) -> JobRecord {
        var r = record
        if let g = gcode, g.utf8.count <= JobHistoryStore.maxGCodeBytes, let f = file(r.id, "nc") {
            r.hasGCode = (try? g.write(to: f, atomically: true, encoding: .utf8)) != nil
        }
        if let t = thumbnail, let f = file(r.id, "png") { r.hasThumbnail = (try? t.write(to: f)) != nil }
        records.insert(r, at: 0)
        while records.count > limit { discardFiles(records.removeLast()) }
        save()
        return r
    }

    public func gcode(for id: String) -> String? {
        guard let f = file(id, "nc") else { return nil }
        return try? String(contentsOf: f, encoding: .utf8)
    }

    public func thumbnail(for id: String) -> Data? {
        guard let f = file(id, "png") else { return nil }
        return try? Data(contentsOf: f)
    }

    public func delete(id: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        discardFiles(records.remove(at: i))
        save()
    }

    public func clear() {
        records.forEach(discardFiles)
        records = []
        save()
    }

    private func discardFiles(_ r: JobRecord) {
        for ext in ["nc", "png"] { if let f = file(r.id, ext) { try? FileManager.default.removeItem(at: f) } }
    }
}
