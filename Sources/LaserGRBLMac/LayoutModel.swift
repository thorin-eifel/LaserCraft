import SwiftUI
import AppKit
import LaserGRBLCore

/// The editable layout: objects on layers, with undo and redo. G-code is made from it only when needed.
final class LayoutModel: ObservableObject {
    @Published private(set) var doc = LayoutDocument()
    @Published var selection: String? {
        didSet { if selection == nil { extraSelection = [] } else { extraSelection.remove(selection!) } }
    }
    /// More selected objects besides `selection` (shift-click): they move, align and are deleted together.
    @Published var extraSelection: Set<String> = []
    @Published private(set) var fileURL: URL?
    @Published private(set) var dirty = false
    /// Bumped by every change; the job is regenerated when it differs from `generatedAt`.
    @Published private(set) var revision = 0
    /// Which part of the work area is shown, and how big the canvas is (set by the canvas).
    @Published var viewport = LayoutViewport()
    var viewSize = CGSize(width: 600, height: 400)
    var viewArea: (Double, Double) = (300, 200)

    func zoom(by factor: Double) {
        let centre = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        viewport.zoom(by: factor, around: centre, area: viewArea, size: viewSize)
    }
    private(set) var generatedAt = -1
    var header = "", footer = ""

    private(set) var images: [String: Data] = [:]
    private var cgCache: [String: CGImage] = [:]
    private var undoStack: [LayoutDocument] = []
    private var redoStack: [LayoutDocument] = []
    private var interactionOpen = false

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var needsGenerate: Bool { !doc.isEmpty && revision != generatedAt }
    var selected: LayoutObject? { doc.objects.first { $0.id == selection } }
    /// Everything that is selected, in document order.
    var selectedIDs: [String] { doc.objects.map { $0.id }.filter { $0 == selection || extraSelection.contains($0) } }
    var selectedObjects: [LayoutObject] { doc.objects.filter { $0.id == selection || extraSelection.contains($0.id) } }

    /// Click selects one object; shift-click adds or removes one.
    func select(_ id: String?, additive: Bool = false) {
        guard additive, let id = id else { extraSelection = []; selection = id; return }
        if selection == nil { selection = id }
        else if id == selection { selection = extraSelection.sorted().first; if let n = selection { extraSelection.remove(n) } }
        else if extraSelection.contains(id) { extraSelection.remove(id) }
        else { extraSelection.insert(id) }
    }

    func selectAll() {
        selection = doc.objects.first?.id
        extraSelection = Set(doc.objects.dropFirst().map { $0.id })
    }

    // MARK: changing the document

    /// Changes the document as one undoable step.
    func mutate(_ change: (inout LayoutDocument) -> Void) {
        pushUndo()
        change(&doc)
        didChange()
    }

    /// For drags and sliders: the first call of an interaction records the undo step, the following ones only change.
    func interact(_ change: (inout LayoutDocument) -> Void) {
        if !interactionOpen { pushUndo(); interactionOpen = true }
        change(&doc)
        didChange()
    }

    func endInteraction() { interactionOpen = false }

    private func pushUndo() {
        undoStack.append(doc)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func didChange() { dirty = true; revision += 1; objectWillChange.send() }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(doc); doc = prev
        if selected == nil { selection = nil }
        interactionOpen = false; didChange()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(doc); doc = next
        if selected == nil { selection = nil }
        interactionOpen = false; didChange()
    }

    func markGenerated() { generatedAt = revision }

    func updateSelected(_ change: (inout LayoutObject) -> Void, interactive: Bool = false) {
        guard let i = doc.objects.firstIndex(where: { $0.id == selection }), !doc.objects[i].locked else { return }
        let apply: (inout LayoutDocument) -> Void = { change(&$0.objects[i]) }
        if interactive { interact(apply) } else { mutate(apply) }
    }

    // MARK: adding things

    @discardableResult
    func add(_ object: LayoutObject) -> LayoutObject {
        mutate { $0.objects.append(object) }
        selection = object.id
        return object
    }

    /// Outlines (any size, any origin) become an object; `at` is the lower left corner of the box.
    @discardableResult
    func addVectors(_ shapes: [Polyline], name: String, layer: Int = 0, at: Pt = Pt(0, 0), size: (Double, Double)? = nil,
                    settings: VectorSettings? = nil) -> LayoutObject? {
        let b = VectorMath.bounds(shapes)
        guard !b.isEmpty else { return nil }
        let native = VectorMath.transform(shapes, .translate(-b.minX, -b.minY))
        var o = LayoutObject(name: name, kind: .vectors(native), layer: layer)
        o.x = at.x; o.y = at.y
        o.width = size?.0 ?? max(b.width, 0.1); o.height = size?.1 ?? max(b.height, 0.1)
        apply(settings, to: &o)
        return add(o)
    }

    @discardableResult
    func addText(_ spec: TextSpec, layer: Int = 0, at: Pt = Pt(0, 0), settings: VectorSettings? = nil) -> LayoutObject {
        var o = LayoutObject(name: spec.text.components(separatedBy: "\n").first ?? "Text", kind: .text(spec), layer: layer)
        let (w, h) = o.nativeSize(serial: doc.serial)
        o.x = at.x; o.y = at.y; o.width = max(w, 0.1); o.height = max(h, 0.1)
        apply(settings, to: &o)
        return add(o)
    }

    /// Settings that differ from the layer become the object's own.
    private func apply(_ s: VectorSettings?, to o: inout LayoutObject) {
        guard let s = s, let l = doc.layer(o.layer) else { return }
        if s.speed != l.speed { o.speed = s.speed }
        if s.powerPercent != l.powerPercent { o.powerPercent = s.powerPercent }
        if s.passes != l.passes { o.passes = s.passes }
        if s.mode != l.mode { o.mode = s.mode }
    }

    @discardableResult
    func addImage(data: Data, name: String, options: RasterOptions = RasterOptions(), layer: Int = 0, at: Pt = Pt(0, 0)) -> LayoutObject? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let id = UUID().uuidString
        images[id] = data; cgCache[id] = img
        var opts = options
        let aspect = Double(img.height) / Double(max(1, img.width))
        opts.widthMM = options.widthMM; opts.heightMM = (options.widthMM * aspect * 100).rounded() / 100
        var o = LayoutObject(name: name, kind: .image(imageID: id, options: opts), layer: layer)
        o.x = at.x; o.y = at.y; o.width = opts.widthMM; o.height = opts.heightMM
        return add(o)
    }

    func cgImage(_ id: String) -> CGImage? {
        if let c = cgCache[id] { return c }
        guard let d = images[id], let src = CGImageSourceCreateWithData(d as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        cgCache[id] = img
        return img
    }

    // MARK: editing the selection

    func deleteSelection() {
        let ids = Set(selectedIDs)
        guard !ids.isEmpty else { return }
        mutate { $0.objects.removeAll { ids.contains($0.id) } }
        selection = nil
    }

    /// Moves every selected object by the same amount (a drag): the first call of an interaction is one undo step.
    func moveSelected(by dx: Double, _ dy: Double, from start: [String: Pt]) {
        let ids = Set(selectedIDs)
        interact { d in
            for i in d.objects.indices where ids.contains(d.objects[i].id) && !d.objects[i].locked {
                if let o = start[d.objects[i].id] { d.objects[i].x = o.x + dx; d.objects[i].y = o.y + dy }
            }
        }
    }

    // MARK: arrange

    /// Moves objects by the given offsets (one undo step).
    func apply(offsets: [String: Pt]) {
        guard !offsets.isEmpty else { return }
        mutate { d in
            for i in d.objects.indices {
                if let o = offsets[d.objects[i].id], !d.objects[i].locked { d.objects[i].x += o.x; d.objects[i].y += o.y }
            }
        }
    }

    /// Lines the selected objects up with each other, or — for a single object — with the work area.
    func align(_ edge: AlignEdge, workArea: (Double, Double)) {
        let ids = selectedIDs
        var area: Bounds? = nil
        if ids.count == 1 { var b = Bounds(); b.add(0, 0); b.add(workArea.0, workArea.1); area = b }
        apply(offsets: doc.alignOffsets(ids: ids, edge: edge, within: area))
    }

    func distribute(_ axis: DistributeAxis) { apply(offsets: doc.distributeOffsets(ids: selectedIDs, axis: axis)) }

    /// `rows × columns` copies of the selected object (pictures get their own copy of the picture data).
    @discardableResult
    func makeArray(rows: Int, columns: Int, gapX: Double, gapY: Double, numberFrom: Int?) -> Int {
        guard let id = selection else { return 0 }
        let all = doc.arrayObjects(of: id, rows: rows, columns: columns, gapX: gapX, gapY: gapY, numberFrom: numberFrom)
        guard all.count > 1 else { return 0 }
        var copies = Array(all.dropFirst())
        for i in copies.indices {
            if case .image(let imgID, let opts) = copies[i].kind, let data = images[imgID] {
                let nid = UUID().uuidString
                images[nid] = data; cgCache[nid] = cgCache[imgID]
                copies[i].kind = .image(imageID: nid, options: opts)
            }
        }
        mutate { d in
            if let first = all.first, let i = d.objects.firstIndex(where: { $0.id == id }) { d.objects[i] = first }   // numbered original
            d.objects += copies
        }
        selection = id
        extraSelection = Set(copies.map { $0.id })
        return copies.count
    }

    func duplicateSelection() {
        let originals = selectedObjects
        guard !originals.isEmpty else { return }
        var copies: [LayoutObject] = []
        for var o in originals {
            o.id = UUID().uuidString; o.x += 5; o.y -= 5; o.name += " copy"
            if case .image(let id, let opts) = o.kind, let d = images[id] {
                let nid = UUID().uuidString
                images[nid] = d; cgCache[nid] = cgCache[id]
                o.kind = .image(imageID: nid, options: opts)
            }
            copies.append(o)
        }
        mutate { $0.objects += copies }
        selection = copies.first?.id
        extraSelection = Set(copies.dropFirst().map { $0.id })
    }

    func centerSelection(inWidth w: Double, height h: Double) {
        updateSelected { o in
            let b = o.boundsInWorld(serial: doc.serial)
            guard !b.isEmpty else { return }
            o.x += w / 2 - (b.minX + b.maxX) / 2
            o.y += h / 2 - (b.minY + b.maxY) / 2
        }
    }

    func addLayer() {
        mutate { d in
            let id = (d.layers.map { $0.id }.max() ?? 0) + 1
            var l = LayoutLayer(id: id, name: "Layer \(id)")
            l.colorHex = ["#30D158", "#FF9F0A", "#BF5AF2", "#64D2FF"][id % 4]
            d.layers.append(l)
        }
    }

    func moveLayer(_ id: Int, by delta: Int) {
        mutate { d in
            guard let i = d.layers.firstIndex(where: { $0.id == id }) else { return }
            let j = min(max(0, i + delta), d.layers.count - 1)
            d.layers.swapAt(i, j)
        }
    }

    func deleteLayer(_ id: Int) {
        guard doc.layers.count > 1, let fallback = doc.layers.first(where: { $0.id != id }) else { return }
        mutate { d in
            for i in d.objects.indices where d.objects[i].layer == id { d.objects[i].layer = fallback.id }
            d.layers.removeAll { $0.id == id }
        }
    }

    /// Turns the selected object counter-clockwise by `degrees` (any angle; pictures too).
    func rotateSelected(by degrees: Double) {
        updateSelected { o in
            var r = (o.rotation + degrees).truncatingRemainder(dividingBy: 360)
            if r < 0 { r += 360 }
            o.rotation = (r * 100).rounded() / 100
        }
    }

    // MARK: output

    func generate(maxS: Double, dynamicPower: Bool) -> [String] {
        doc.generate(maxS: maxS, dynamicPower: dynamicPower) { [self] in cgImage($0) }
    }

    // MARK: files

    func newDocument() {
        doc = LayoutDocument(); images = [:]; cgCache = [:]; undoStack = []; redoStack = []
        selection = nil; fileURL = nil; dirty = false; header = ""; footer = ""
        revision += 1
    }

    func save(to url: URL, profileID: String?) throws {
        var p = ProjectFile(document: doc)
        p.header = header; p.footer = footer; p.machineProfileID = profileID
        let used = Set(doc.objects.compactMap { o -> String? in if case .image(let id, _) = o.kind { return id }; return nil })
        try ProjectIO.write(p, images: images.filter { used.contains($0.key) }, to: url)
        fileURL = url; dirty = false
    }

    @discardableResult
    func open(_ url: URL) throws -> ProjectFile {
        let (p, imgs) = try ProjectIO.read(from: url)
        doc = p.document; images = imgs; cgCache = [:]
        header = p.header; footer = p.footer
        undoStack = []; redoStack = []; selection = nil
        fileURL = url; dirty = false; revision += 1
        return p
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt32(s, radix: 16) ?? 0x0A84FF
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}
