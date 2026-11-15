import Foundation
import CoreGraphics

/// A layer decides how its objects are burnt, and the layers are run top to bottom (put engraving first, cutting last).
public struct LayoutLayer: Codable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var mode: VectorMode = .line
    public var speed = 1000.0
    public var powerPercent = 100.0
    public var passes = 1
    public var fillSpacing = 0.1
    public var visible = true
    /// Layers that are switched off are shown but not burnt.
    public var output = true
    public var colorHex = "#0A84FF"
    public init(id: Int, name: String) { self.id = id; self.name = name }
}

public enum LayoutKind: Codable, Equatable {
    case image(imageID: String, options: RasterOptions)
    case vectors([Polyline])
    case text(TextSpec)
}

public struct LayoutObject: Codable, Equatable, Identifiable {
    public var id: String = UUID().uuidString
    public var name: String
    public var kind: LayoutKind
    /// Lower left corner of the unrotated box, in mm.
    public var x = 0.0, y = 0.0
    public var width = 10.0, height = 10.0
    /// Degrees counter-clockwise around the centre. Pictures turn in steps of 90° (inside their options).
    public var rotation = 0.0
    public var layer: Int
    public var locked = false
    public var visible = true
    /// Settings that replace the layer's for this object only.
    public var speed: Double?
    public var powerPercent: Double?
    public var passes: Int?
    public var mode: VectorMode?

    public init(name: String, kind: LayoutKind, layer: Int = 0) {
        self.name = name; self.kind = kind; self.layer = layer
    }

    public var isImage: Bool { if case .image = kind { return true }; return false }

    /// Outlines in the object's own units, starting at (0, 0).
    public func nativeShapes(serial: Int = 1, date: Date = Date()) -> [Polyline] {
        switch kind {
        case .vectors(let v): return v
        case .text(let t): return TextLayout.polylines(t, serial: serial, date: date)
        case .image: return []
        }
    }

    /// Native size of a vector or text object.
    public func nativeSize(serial: Int = 1) -> (Double, Double) {
        let b = VectorMath.bounds(nativeShapes(serial: serial))
        return (b.width, b.height)
    }

    /// Where the outlines really are: scaled to the box, turned and moved.
    public func worldShapes(serial: Int = 1, date: Date = Date()) -> [Polyline] {
        let native = nativeShapes(serial: serial, date: date)
        let b = VectorMath.bounds(native)
        guard !b.isEmpty else { return [] }
        let sx = b.width > 1e-9 ? width / b.width : 1, sy = b.height > 1e-9 ? height / b.height : 1
        let t = Affine.translate(x + width / 2, y + height / 2)
            .concatenating(.rotate(degrees: rotation))
            .concatenating(.translate(-width / 2, -height / 2))
            .concatenating(.scale(sx, sy))
            .concatenating(.translate(-b.minX, -b.minY))
        return VectorMath.transform(native, t)
    }

    /// The area the object covers (of the turned outlines for vectors).
    public func boundsInWorld(serial: Int = 1) -> Bounds {
        if isImage { var b = Bounds(); b.add(x, y); b.add(x + width, y + height); return b }
        return VectorMath.bounds(worldShapes(serial: serial))
    }
}

public struct LayoutDocument: Codable, Equatable {
    public var version = 1
    public var layers: [LayoutLayer] = [LayoutLayer(id: 0, name: "Engrave")]
    public var objects: [LayoutObject] = []
    /// Serial number for `{n}` in texts; counts up for every copy that is made.
    public var serial = 1
    public init() {
        var cut = LayoutLayer(id: 1, name: "Cut")
        cut.speed = 200; cut.passes = 2; cut.colorHex = "#FF453A"
        layers.append(cut)
    }

    public func layer(_ id: Int) -> LayoutLayer? { layers.first { $0.id == id } }

    public var isEmpty: Bool { objects.isEmpty }

    public var bounds: Bounds {
        var b = Bounds()
        for o in objects where o.visible {
            let ob = o.boundsInWorld(serial: serial)
            if !ob.isEmpty { b.add(ob.minX, ob.minY); b.add(ob.maxX, ob.maxY) }
        }
        return b
    }

    /// Effective settings of an object: its own overrides on top of its layer.
    public func settings(for o: LayoutObject, dynamicPower: Bool = true) -> VectorSettings {
        let l = layer(o.layer) ?? LayoutLayer(id: o.layer, name: "")
        var s = VectorSettings()
        s.mode = o.mode ?? l.mode
        s.speed = o.speed ?? l.speed
        s.powerPercent = o.powerPercent ?? l.powerPercent
        s.passes = o.passes ?? l.passes
        s.fillSpacing = l.fillSpacing
        s.dynamicPower = dynamicPower
        return s
    }

    /// The whole job as G-code. Layers run in order; inside a layer, objects with the same settings are optimised together.
    /// `image` returns the picture for an image object.
    public func generate(maxS: Double = 1000, dynamicPower: Bool = true, image: (String) -> CGImage? = { _ in nil }) -> [String] {
        var out = ["G21", "G90"]
        for layer in layers where layer.output && layer.visible {
            let objs = objects.filter { $0.layer == layer.id && $0.visible }
            // vectors and text: group by effective settings (an Equatable struct) keeping first-seen order
            var groups: [(VectorSettings, [Polyline])] = []
            for o in objs where !o.isImage {
                let s = settings(for: o, dynamicPower: dynamicPower)
                let shapes = o.worldShapes(serial: serial)
                if let i = groups.firstIndex(where: { $0.0 == s }) { groups[i].1 += shapes } else { groups.append((s, shapes)) }
            }
            let imageObjs = objs.filter { $0.isImage }
            if !imageObjs.isEmpty || !groups.isEmpty { out.append("; layer \(layer.name)") }
            for o in imageObjs {
                guard case .image(let id, var opts) = o.kind, let cg = image(id) else { continue }
                let s = settings(for: o, dynamicPower: dynamicPower)
                opts.widthMM = o.width; opts.heightMM = o.height
                opts.offsetX = o.x; opts.offsetY = o.y
                opts.markSpeed = Int(s.speed.rounded())
                opts.maxPower = Int((s.powerPercent / 100 * maxS).rounded())
                opts.laserOn = dynamicPower ? "M4" : "M3"
                guard let text = RasterConverter.generate(image: cg, options: opts) else { continue }
                out.append("; picture \(o.name)")
                for _ in 0..<max(1, s.passes) { out += text.split(whereSeparator: \.isNewline).map(String.init) }
                out += ["M5", "S0", "G90"]
            }
            for (s, shapes) in groups where !shapes.isEmpty {
                out += VectorJob.gcode(shapes, s, maxS: maxS, header: false)
            }
        }
        return out
    }
}

// MARK: - Project files

/// A project is a folder with the extension ".lasercraft": `project.json` plus `images/<id>.png` with the original pictures.
public struct ProjectFile: Codable, Equatable {
    public var version = 1
    public var document: LayoutDocument
    public var header = ""
    public var footer = ""
    public var machineProfileID: String?
    public init(document: LayoutDocument) { self.document = document }
}

public enum ProjectIO {
    public static let fileExtension = "lasercraft"

    public static func write(_ project: ProjectFile, images: [String: Data], to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try fm.createDirectory(at: tmp.appendingPathComponent("images"), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(project).write(to: tmp.appendingPathComponent("project.json"))
        for (id, data) in images { try data.write(to: tmp.appendingPathComponent("images/\(id).png")) }
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
    }

    public static func read(from url: URL) throws -> (ProjectFile, [String: Data]) {
        let fm = FileManager.default
        let data = try Data(contentsOf: url.appendingPathComponent("project.json"))
        let project = try JSONDecoder().decode(ProjectFile.self, from: data)
        var images: [String: Data] = [:]
        let dir = url.appendingPathComponent("images")
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".png") {
            images[String(f.dropLast(4))] = try? Data(contentsOf: dir.appendingPathComponent(f))
        }
        return (project, images)
    }
}
