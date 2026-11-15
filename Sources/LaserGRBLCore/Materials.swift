import Foundation

public enum MaterialAction: String, Codable, CaseIterable { case engrave, cut }

/// Power and speed that worked for a material with a certain machine.
public struct LaserMaterial: Codable, Equatable, Identifiable {
    public var id: String
    public var machine: String
    public var name: String
    public var thickness: String
    public var action: MaterialAction
    /// Percent of the machine's maximum power.
    public var power: Double
    /// mm/min
    public var speed: Double
    public var passes: Int
    public var notes: String
    /// Built-in entries cannot be edited or deleted.
    public var builtin: Bool

    public init(id: String = UUID().uuidString, machine: String = "", name: String, thickness: String = "-",
                action: MaterialAction = .engrave, power: Double = 100, speed: Double = 1000, passes: Int = 1,
                notes: String = "", builtin: Bool = false) {
        self.id = id; self.machine = machine; self.name = name; self.thickness = thickness; self.action = action
        self.power = power; self.speed = speed; self.passes = passes; self.notes = notes; self.builtin = builtin
    }

    enum CodingKeys: String, CodingKey { case id, machine, name, thickness, action, power, speed, passes, notes, builtin }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        machine = try c.decodeIfPresent(String.self, forKey: .machine) ?? ""
        name = try c.decode(String.self, forKey: .name)
        thickness = try c.decodeIfPresent(String.self, forKey: .thickness) ?? "-"
        action = try c.decodeIfPresent(MaterialAction.self, forKey: .action) ?? .engrave
        power = try c.decodeIfPresent(Double.self, forKey: .power) ?? 100
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1000
        passes = try c.decodeIfPresent(Int.self, forKey: .passes) ?? 1
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        builtin = try c.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
    }

    /// "Plywood 3 mm - Cut"
    public var title: String {
        name + (thickness == "-" || thickness.isEmpty ? "" : " \(thickness) mm")
    }
}

/// The built-in set (from LaserGRBL's standard materials) plus your own entries.
public final class MaterialDB {
    public private(set) var builtin: [LaserMaterial] = []
    public private(set) var custom: [LaserMaterial] = []
    public var userFile: URL?

    public init(builtinData: Data? = nil, userFile: URL? = nil) {
        self.userFile = userFile
        if let d = builtinData, var list = try? JSONDecoder().decode([LaserMaterial].self, from: d) {
            for i in list.indices { list[i].builtin = true }
            builtin = list
        }
        loadUser()
    }

    public var all: [LaserMaterial] { custom + builtin }

    public var machines: [String] { Array(Set(all.map { $0.machine }.filter { !$0.isEmpty })).sorted() }

    public func materials(machine: String? = nil, action: MaterialAction? = nil, search: String = "") -> [LaserMaterial] {
        all.filter { m in
            (machine == nil || machine == "" || m.machine == machine) && (action == nil || m.action == action)
                && (search.isEmpty || m.name.localizedCaseInsensitiveContains(search) || m.notes.localizedCaseInsensitiveContains(search))
        }
    }

    public func add(_ m: LaserMaterial) {
        var m = m; m.builtin = false
        if let i = custom.firstIndex(where: { $0.id == m.id }) { custom[i] = m } else { custom.insert(m, at: 0) }
        saveUser()
    }

    public func remove(id: String) {
        custom.removeAll { $0.id == id }
        saveUser()
    }

    // MARK: files

    func loadUser() {
        guard let f = userFile, let d = try? Data(contentsOf: f), let list = try? JSONDecoder().decode([LaserMaterial].self, from: d) else { return }
        custom = list.map { var m = $0; m.builtin = false; return m }
    }

    func saveUser() {
        guard let f = userFile else { return }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(custom).write(to: f, options: .atomic)
    }

    /// Your own materials as JSON, to share.
    public func exportCustom() throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(custom)
    }

    /// Adds the materials of a shared file; entries with the same id are replaced. Returns how many were read.
    @discardableResult
    public func importMaterials(_ data: Data) throws -> Int {
        let list = try JSONDecoder().decode([LaserMaterial].self, from: data)
        for m in list { add(m) }
        return list.count
    }
}
