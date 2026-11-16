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
    /// Stop (M0) before this layer is burnt, with a message for the console, e.g. "Flip the material". Resume continues the job.
    public var pauseBefore = false
    public var pauseNote = ""
    /// Lowers the focus by this many mm (Z axis) with every further pass, for cutting thick material. 0 = no Z movement.
    public var focusStep = 0.0
    public init(id: Int, name: String) { self.id = id; self.name = name }

    // Projects saved by earlier versions do not have the newer keys: every key is optional when reading.
    private enum CodingKeys: String, CodingKey {
        case id, name, mode, speed, powerPercent, passes, fillSpacing, visible, output, colorHex, pauseBefore, pauseNote, focusStep
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        mode = try c.decodeIfPresent(VectorMode.self, forKey: .mode) ?? .line
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1000
        powerPercent = try c.decodeIfPresent(Double.self, forKey: .powerPercent) ?? 100
        passes = try c.decodeIfPresent(Int.self, forKey: .passes) ?? 1
        fillSpacing = try c.decodeIfPresent(Double.self, forKey: .fillSpacing) ?? 0.1
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        output = try c.decodeIfPresent(Bool.self, forKey: .output) ?? true
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#0A84FF"
        pauseBefore = try c.decodeIfPresent(Bool.self, forKey: .pauseBefore) ?? false
        pauseNote = try c.decodeIfPresent(String.self, forKey: .pauseNote) ?? ""
        focusStep = try c.decodeIfPresent(Double.self, forKey: .focusStep) ?? 0
    }
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

    /// The four corners of the object's box, turned: bottom left, bottom right, top right, top left.
    public func orientedCorners() -> [Pt] {
        let cx = x + width / 2, cy = y + height / 2
        let t = Affine.translate(cx, cy).concatenating(.rotate(degrees: rotation))
        return [Pt(-width / 2, -height / 2), Pt(width / 2, -height / 2), Pt(width / 2, height / 2), Pt(-width / 2, height / 2)].map { t.apply($0) }
    }

    /// A point in world coordinates, seen from the object's own (unturned) box: (0, 0) is its lower left corner.
    public func localPoint(_ p: Pt) -> Pt {
        let cx = x + width / 2, cy = y + height / 2
        let t = Affine.rotate(degrees: -rotation)
        let q = t.apply(Pt(p.x - cx, p.y - cy))
        return Pt(q.x + width / 2, q.y + height / 2)
    }

    /// Is the point on the object? (Its turned box, with a little tolerance in mm.)
    public func contains(_ p: Pt, tolerance: Double = 1.5) -> Bool {
        let q = localPoint(p)
        return q.x >= -tolerance && q.x <= width + tolerance && q.y >= -tolerance && q.y <= height + tolerance
    }

    /// The area the object covers: the turned outlines for vectors, the turned box for pictures.
    public func boundsInWorld(serial: Int = 1) -> Bounds {
        if isImage { var b = Bounds(); for c in orientedCorners() { b.add(c.x, c.y) }; return b }
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
            if !imageObjs.isEmpty || !groups.isEmpty {
                out.append("; layer \(layer.name)")
                if layer.pauseBefore { out += LayoutDocument.pauseLines(layer.pauseNote) }
            }
            let step = abs(layer.focusStep) > 1e-9 ? layer.focusStep : 0
            var loweredToZ = false
            func focus(pass: Int) {
                guard step != 0 else { return }
                out.append("G90"); out.append("G0 Z\(VectorJob.fmt(-step * Double(pass)))")
                loweredToZ = pass > 0 || loweredToZ
            }
            for o in imageObjs {
                guard case .image(let id, var opts) = o.kind, var cg = image(id) else { continue }
                let s = settings(for: o, dynamicPower: dynamicPower)
                var box = (x: o.x, y: o.y, w: o.width, h: o.height)
                let turn = ((o.rotation.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
                if turn > 0.01 && turn < 359.99 {
                    // any angle: crop / mirror / 90° first, then scale to the box, turn, and engrave the bigger sheet
                    var pxPerMM = min(20, max(2, opts.linesPerMM * 2))
                    pxPerMM = min(pxPerMM, 4000 / max(o.width, o.height, 1))
                    var base = RasterConverter.transformed(cg, opts)
                    base = RasterConverter.resized(base, width: Int(o.width * pxPerMM), height: Int(o.height * pxPerMM))
                    cg = RasterConverter.rotatedFree(base, degrees: turn)
                    let bw = Double(cg.width) / pxPerMM, bh = Double(cg.height) / pxPerMM
                    box = (o.x + o.width / 2 - bw / 2, o.y + o.height / 2 - bh / 2, bw, bh)
                    opts.cropLeft = 0; opts.cropTop = 0; opts.cropRight = 0; opts.cropBottom = 0
                    opts.rotation = 0; opts.flipH = false; opts.flipV = false
                }
                opts.widthMM = box.w; opts.heightMM = box.h
                opts.offsetX = box.x; opts.offsetY = box.y
                opts.markSpeed = Int(s.speed.rounded())
                opts.maxPower = Int((s.powerPercent / 100 * maxS).rounded())
                opts.laserOn = dynamicPower ? "M4" : "M3"
                guard let text = RasterConverter.generate(image: cg, options: opts) else { continue }
                out.append("; picture \(o.name)")
                for pass in 0..<max(1, s.passes) {
                    focus(pass: pass)
                    out += text.split(whereSeparator: \.isNewline).map(String.init)
                }
                out += ["M5", "S0", "G90"]
            }
            for (s, shapes) in groups where !shapes.isEmpty {
                if step != 0 && s.passes > 1 {
                    // one pass at a time so the focus can move between them
                    var single = s; single.passes = 1
                    for pass in 0..<s.passes {
                        out.append("; pass \(pass + 1) of \(s.passes)")
                        focus(pass: pass)
                        out += VectorJob.gcode(shapes, single, maxS: maxS, header: false)
                    }
                } else {
                    out += VectorJob.gcode(shapes, s, maxS: maxS, header: false)
                }
            }
            if loweredToZ { out += ["G90", "G0 Z0"] }        // back to the focus the job started with
        }
        return out
    }
}

// MARK: - pauses

public extension LayoutDocument {
    /// The lines that stop a job for the person: laser off, a message (Grbl shows it as `[MSG:…]`), then M0.
    /// Brackets and semicolons would end the comment early, so they are taken out of the text.
    static func pauseLines(_ note: String) -> [String] {
        let clean = String(note.unicodeScalars.filter { $0.isASCII && $0.value >= 32 && !"();".unicodeScalars.contains($0) }.prefix(60))
        var lines = ["M5", "S0"]
        lines.append("(MSG,\(clean.isEmpty ? "Pause" : clean))")
        lines.append("M0")
        return lines
    }
}

// MARK: - array, align, distribute

public enum AlignEdge: String, CaseIterable { case left, centerX, right, bottom, centerY, top }
public enum DistributeAxis { case horizontal, vertical }

public extension LayoutDocument {
    /// `rows × columns` copies of an object on a grid; `gap*` is the space between the copies in mm. The first one is the
    /// object itself (as it is, or numbered). With `numberFrom` the `{n}` of texts is replaced by consecutive numbers
    /// (row by row, starting at the object), so every copy engraves its own number.
    func arrayObjects(of id: String, rows: Int, columns: Int, gapX: Double, gapY: Double, numberFrom: Int? = nil) -> [LayoutObject] {
        guard let o = objects.first(where: { $0.id == id }), rows >= 1, columns >= 1 else { return [] }
        let b = o.boundsInWorld(serial: serial)
        guard !b.isEmpty else { return [] }
        let stepX = b.width + gapX, stepY = b.height + gapY
        var out: [LayoutObject] = []
        for r in 0..<rows {
            for c in 0..<columns {
                var copy = o
                let index = r * columns + c
                if index > 0 { copy.id = UUID().uuidString; copy.name = o.name + " \(index + 1)" }
                copy.x += Double(c) * stepX
                copy.y += Double(r) * stepY
                if let first = numberFrom, case .text(var spec) = copy.kind, TextTemplate.hasPlaceholders(spec.text) {
                    spec.text = TextTemplate.expandSerial(spec.text, serial: first + index)
                    copy.kind = .text(spec)
                }
                out.append(copy)
            }
        }
        return out
    }

    /// How far each object has to move to line up with `edge`: on the area (for a single object, or when given) or on the
    /// group of objects.
    func alignOffsets(ids: [String], edge: AlignEdge, within area: Bounds? = nil) -> [String: Pt] {
        let items = objects.filter { ids.contains($0.id) }.map { ($0.id, $0.boundsInWorld(serial: serial)) }.filter { !$0.1.isEmpty }
        guard !items.isEmpty else { return [:] }
        var ref = Bounds()
        if let a = area, !a.isEmpty { ref = a } else { for (_, b) in items { ref.add(b.minX, b.minY); ref.add(b.maxX, b.maxY) } }
        var out: [String: Pt] = [:]
        for (id, b) in items {
            switch edge {
            case .left: out[id] = Pt(ref.minX - b.minX, 0)
            case .right: out[id] = Pt(ref.maxX - b.maxX, 0)
            case .centerX: out[id] = Pt((ref.minX + ref.maxX) / 2 - (b.minX + b.maxX) / 2, 0)
            case .bottom: out[id] = Pt(0, ref.minY - b.minY)
            case .top: out[id] = Pt(0, ref.maxY - b.maxY)
            case .centerY: out[id] = Pt(0, (ref.minY + ref.maxY) / 2 - (b.minY + b.maxY) / 2)
            }
        }
        return out
    }

    /// Equal gaps between three or more objects; the outer two stay where they are.
    func distributeOffsets(ids: [String], axis: DistributeAxis) -> [String: Pt] {
        var items = objects.filter { ids.contains($0.id) }.map { ($0.id, $0.boundsInWorld(serial: serial)) }.filter { !$0.1.isEmpty }
        guard items.count >= 3 else { return [:] }
        let h = axis == .horizontal
        items.sort { (h ? $0.1.minX : $0.1.minY) < (h ? $1.1.minX : $1.1.minY) }
        let start = h ? items.first!.1.minX : items.first!.1.minY
        let end = items.map { h ? $0.1.maxX : $0.1.maxY }.max()!
        let sizes = items.map { h ? $0.1.width : $0.1.height }
        let gap = (end - start - sizes.reduce(0, +)) / Double(items.count - 1)
        var pos = start
        var out: [String: Pt] = [:]
        for (i, item) in items.enumerated() {
            let current = h ? item.1.minX : item.1.minY
            out[item.0] = h ? Pt(pos - current, 0) : Pt(0, pos - current)
            pos += sizes[i] + gap
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
        // written next to the target first and moved into place, so a full disk never leaves half a project behind
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try fm.createDirectory(at: tmp.appendingPathComponent("images"), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(project).write(to: tmp.appendingPathComponent("project.json"))
            for (id, data) in images { try data.write(to: tmp.appendingPathComponent("images/\(id).png")) }
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
        } catch {
            try? fm.removeItem(at: tmp)                                   // do not leave the hidden temporary folder behind
            throw error
        }
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
