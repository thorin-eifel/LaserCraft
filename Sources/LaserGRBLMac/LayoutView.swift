import SwiftUI
import AppKit
import LaserGRBLCore

/// The layout editor: the work area with all objects, and an inspector with the selected object and the layers.
struct LayoutEditor: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var layout: LayoutModel

    var body: some View {
        VStack(spacing: 0) {
            LayoutToolbar(layout: layout)
            Divider()
            HSplitView {
                LayoutCanvas(layout: layout)
                    .frame(minWidth: 320)
                LayoutInspector(layout: layout)
                    .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
            }
        }
    }
}

private struct LayoutToolbar: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var layout: LayoutModel

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Add Picture…") { app.addPictureToLayout() }
                Button("Add SVG…") { app.addSVGToLayout() }
                Button("Add Text…") { app.tool = .vector(.text) }
                Button("Trace Image…") { app.traceImage() }
            } label: { IconLabel("Add", icon: "plus") }
            .menuStyle(.borderlessButton).fixedSize()
            Divider().frame(height: 16)
            Button { layout.undo() } label: { IconLabel("Undo", icon: "undo") }.labelStyle(.iconOnly).disabled(!layout.canUndo)
                .help("Undo (⌘Z)")
            Button { layout.redo() } label: { IconLabel("Redo", icon: "redo") }.labelStyle(.iconOnly).disabled(!layout.canRedo)
                .help("Redo (⇧⌘Z)")
            Divider().frame(height: 16)
            Button { layout.duplicateSelection() } label: { IconLabel("Duplicate", icon: "copy") }.labelStyle(.iconOnly).disabled(layout.selected == nil).help("Duplicate")
            Button { let a = app.machineArea; layout.centerSelection(inWidth: a.0, height: a.1) } label: { IconLabel("Center", icon: "center") }
                .labelStyle(.iconOnly).disabled(layout.selected == nil).help("Center in the work area")
            Button { layout.deleteSelection() } label: { IconLabel("Delete Button", icon: "trash") }.labelStyle(.iconOnly).disabled(layout.selected == nil).help("Delete Button")
            Spacer()
            Button { app.useLayoutAsJob(); app.mainMode = .job } label: { IconLabel("Use as Job", icon: "play") }
                .disabled(layout.doc.isEmpty).help("Make the G-code from this layout and show it in the job preview")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

// MARK: - canvas

private struct LayoutCanvas: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var layout: LayoutModel
    @AppStorage("layoutSnap") private var snap = 1.0

    private enum Drag {
        case move(startX: Double, startY: Double, from: Pt)
        case resize(corner: Int, box: Bounds, aspect: Double)
    }
    @State private var drag: Drag?

    private struct Geometry {
        var scale: Double, ox: Double, oy: Double, w: Double, h: Double
        func pt(_ p: Pt) -> CGPoint { CGPoint(x: ox + p.x * scale, y: oy + (h - p.y) * scale) }
        func mm(_ p: CGPoint) -> Pt { Pt((Double(p.x) - ox) / scale, h - (Double(p.y) - oy) / scale) }
        func rect(_ b: Bounds) -> CGRect {
            let a = pt(Pt(b.minX, b.maxY)), c = pt(Pt(b.maxX, b.minY))
            return CGRect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y)
        }
    }

    private func geometry(_ size: CGSize) -> Geometry {
        let (w, h) = app.machineArea
        let margin = 24.0
        let s = max(0.01, min((Double(size.width) - 2 * margin) / w, (Double(size.height) - 2 * margin) / h))
        return Geometry(scale: s, ox: (Double(size.width) - w * s) / 2, oy: (Double(size.height) - h * s) / 2, w: w, h: h)
    }

    var body: some View {
        GeometryReader { proxy in
            let g = geometry(proxy.size)
            Canvas { ctx, size in draw(ctx, g) }
                .background(Color(nsColor: .underPageBackgroundColor))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in dragChanged(v, g) }
                    .onEnded { _ in drag = nil; layout.endInteraction() })
                .focusable()
                .onDeleteCommand { layout.deleteSelection() }
                .overlay(alignment: .bottomLeading) {
                    Text(L("Work area %.0f × %.0f mm", g.w, g.h)).font(.caption).foregroundStyle(.secondary).padding(8)
                }
                .overlay {
                    if layout.doc.isEmpty {
                        VStack(spacing: 6) {
                            Text("The layout is empty").font(.headline)
                            Text("Add a picture, an SVG file or a text with the + button.").foregroundStyle(.secondary)
                        }.allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: drawing

    private func draw(_ context: GraphicsContext, _ g: Geometry) {
        var ctx = context
        let bed = CGRect(x: g.ox, y: g.oy, width: g.w * g.scale, height: g.h * g.scale)
        ctx.fill(Path(bed), with: .color(Color(nsColor: .textBackgroundColor)))
        // grid every 10 mm (every 50 mm stronger)
        var grid = Path(), strong = Path()
        var gx = 0.0
        while gx <= g.w {
            var line = Path(); line.move(to: g.pt(Pt(gx, 0))); line.addLine(to: g.pt(Pt(gx, g.h)))
            if Int(gx) % 50 == 0 { strong.addPath(line) } else { grid.addPath(line) }
            gx += 10
        }
        var gy = 0.0
        while gy <= g.h {
            var line = Path(); line.move(to: g.pt(Pt(0, gy))); line.addLine(to: g.pt(Pt(g.w, gy)))
            if Int(gy) % 50 == 0 { strong.addPath(line) } else { grid.addPath(line) }
            gy += 10
        }
        ctx.stroke(grid, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)
        ctx.stroke(strong, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
        ctx.stroke(Path(bed), with: .color(.gray.opacity(0.7)), lineWidth: 1)
        // origin marker
        let o = g.pt(Pt(0, 0))
        var axes = Path(); axes.move(to: CGPoint(x: o.x, y: o.y - 22)); axes.addLine(to: o); axes.addLine(to: CGPoint(x: o.x + 22, y: o.y))
        ctx.stroke(axes, with: .color(.red.opacity(0.8)), lineWidth: 1.5)

        for layer in layout.doc.layers where layer.visible {
            let color = Color(hex: layer.colorHex).opacity(layer.output ? 1 : 0.35)
            for obj in layout.doc.objects where obj.layer == layer.id && obj.visible {
                switch obj.kind {
                case .image(let id, let opts):
                    var b = Bounds(); b.add(obj.x, obj.y); b.add(obj.x + obj.width, obj.y + obj.height)
                    if let cg = layout.cgImage(id) {
                        let t = RasterConverter.transformed(cg, opts)
                        ctx.opacity = layer.output ? 0.9 : 0.35
                        ctx.draw(Image(decorative: t, scale: 1), in: g.rect(b))
                        ctx.opacity = 1
                    }
                    ctx.stroke(Path(g.rect(b)), with: .color(color), lineWidth: 1)
                default:
                    var path = Path()
                    for l in obj.worldShapes(serial: layout.doc.serial) {
                        guard let f = l.points.first else { continue }
                        path.move(to: g.pt(f))
                        for p in l.points.dropFirst() { path.addLine(to: g.pt(p)) }
                        if l.closed { path.closeSubpath() }
                    }
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                }
            }
        }
        if let s = layout.selected {
            let b = s.boundsInWorld(serial: layout.doc.serial)
            guard !b.isEmpty else { return }
            let r = g.rect(b)
            ctx.stroke(Path(r), with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            for c in 0..<4 {
                let hp = handle(c, r)
                ctx.fill(Path(CGRect(x: hp.x - 4, y: hp.y - 4, width: 8, height: 8)), with: .color(.white))
                ctx.stroke(Path(CGRect(x: hp.x - 4, y: hp.y - 4, width: 8, height: 8)), with: .color(.accentColor), lineWidth: 1.2)
            }
        }
    }

    /// 0 = top left, 1 = top right, 2 = bottom right, 3 = bottom left.
    private func handle(_ c: Int, _ r: CGRect) -> CGPoint {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)][c]
    }

    // MARK: mouse

    private func objectAt(_ p: Pt) -> LayoutObject? {
        for o in layout.doc.objects.reversed() where o.visible {
            if let l = layout.doc.layer(o.layer), !l.visible { continue }
            let b = o.boundsInWorld(serial: layout.doc.serial)
            if !b.isEmpty, p.x >= b.minX - 1.5, p.x <= b.maxX + 1.5, p.y >= b.minY - 1.5, p.y <= b.maxY + 1.5 { return o }
        }
        return nil
    }

    private func snapped(_ v: Double) -> Double { snap > 0 ? (v / snap).rounded() * snap : v }

    private func dragChanged(_ v: DragGesture.Value, _ g: Geometry) {
        let here = g.mm(v.location)
        if drag == nil {
            // start of a gesture: a handle of the selection, an object, or nothing
            if let s = layout.selected, !s.locked, s.rotation == 0 || s.isImage {
                let b = s.boundsInWorld(serial: layout.doc.serial)
                if !b.isEmpty {
                    let r = g.rect(b)
                    for c in 0..<4 where hypot(handle(c, r).x - v.startLocation.x, handle(c, r).y - v.startLocation.y) < 9 {
                        drag = .resize(corner: c, box: b, aspect: max(1e-6, b.width) / max(1e-6, b.height))
                        break
                    }
                }
            }
            if drag == nil {
                let start = g.mm(v.startLocation)
                if let o = objectAt(start) {
                    layout.selection = o.id
                    drag = .move(startX: o.x, startY: o.y, from: start)
                } else { layout.selection = nil; return }
            }
        }
        switch drag {
        case .move(let sx, let sy, let from)?:
            guard let s = layout.selected, !s.locked else { return }
            let nx = snapped(sx + here.x - from.x), ny = snapped(sy + here.y - from.y)
            layout.updateSelected({ $0.x = nx; $0.y = ny }, interactive: true)
        case .resize(let corner, let box, let aspect)?:
            guard layout.selected != nil else { return }
            // the opposite corner stays where it is
            let fixed = [Pt(box.maxX, box.minY), Pt(box.minX, box.minY), Pt(box.minX, box.maxY), Pt(box.maxX, box.maxY)][corner]
            var w = abs(snapped(here.x) - fixed.x), h = abs(snapped(here.y) - fixed.y)
            if !NSEvent.modifierFlags.contains(.option) { if w / max(h, 1e-6) > aspect { w = h * aspect } else { h = w / aspect } }
            w = max(1, w); h = max(1, h)
            let left = here.x < fixed.x ? fixed.x - w : fixed.x, bottom = here.y < fixed.y ? fixed.y - h : fixed.y
            layout.updateSelected({ o in
                // for turned objects the box is the unrotated one; resizing is only offered when not turned
                o.x = left; o.y = bottom; o.width = w; o.height = h
            }, interactive: true)
        case nil: break
        }
    }
}

// MARK: - inspector

private struct LayoutInspector: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var layout: LayoutModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let o = layout.selected { ObjectSection(layout: layout, object: o) }
                else { Text("Select an object to change its position, size and settings.").foregroundStyle(.secondary).font(.callout) }
                Divider()
                LayersSection(layout: layout)
            }
            .padding(12)
        }
        .background(.background)
    }
}

private func numberField(_ title: String, _ value: Double, _ set: @escaping (Double) -> Void, width: CGFloat = 64) -> some View {
    TextField(title, value: Binding(get: { value }, set: set), format: .number.grouping(.never).precision(.fractionLength(0...2)))
        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: width)
}

private struct ObjectSection: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var layout: LayoutModel
    let object: LayoutObject
    @State private var lockAspect = true

    private func edit(_ f: @escaping (inout LayoutObject) -> Void) { layout.updateSelected(f) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Object").font(.headline)
            TextField("Name", text: Binding(get: { object.name }, set: { v in edit { $0.name = v } })).textFieldStyle(.roundedBorder)
            UnitRow("X", value: Binding(get: { object.x }, set: { v in edit { $0.x = v } }), unit: "mm", digits: 2)
            UnitRow("Y", value: Binding(get: { object.y }, set: { v in edit { $0.y = v } }), unit: "mm", digits: 2)
            UnitRow("Width", value: Binding(get: { object.width }, set: { v in
                edit { o in let r = o.height / max(o.width, 1e-6); o.width = max(0.1, v); if lockAspect { o.height = max(0.1, v * r) } } }),
                    range: 0.1...5000, unit: "mm", digits: 2)
            UnitRow("Height", value: Binding(get: { object.height }, set: { v in
                edit { o in let r = o.width / max(o.height, 1e-6); o.height = max(0.1, v); if lockAspect { o.width = max(0.1, v * r) } } }),
                    range: 0.1...5000, unit: "mm", digits: 2)
            Toggle("Lock", isOn: $lockAspect).toggleStyle(.checkbox)
            HStack {
                Button { layout.rotateSelected(by: 90) } label: { IconLabel("Rotate Left", icon: "rotl", size: 13) }.labelStyle(.iconOnly).help("Rotate Left")
                Button { layout.rotateSelected(by: -90) } label: { IconLabel("Rotate Right", icon: "rotr", size: 13) }.labelStyle(.iconOnly).help("Rotate Right")
                Spacer()
                if !object.isImage {
                    Text("Rotation").foregroundStyle(.secondary)
                    NumberInput(value: Binding(get: { object.rotation }, set: { v in edit { $0.rotation = v } }), digits: 1, width: 60)
                    Text(verbatim: "°").foregroundStyle(.secondary)
                }
            }
            Picker("Layer", selection: Binding(get: { object.layer }, set: { v in edit { $0.layer = v } })) {
                ForEach(layout.doc.layers) { Text($0.name).tag($0.id) }
            }
            Toggle("Locked", isOn: Binding(get: { object.locked }, set: { v in layout.mutate { d in if let i = d.objects.firstIndex(where: { $0.id == object.id }) { d.objects[i].locked = v } } }))
            kindSection
            DisclosureGroup("Own settings") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Empty fields use the settings of the layer.").font(.caption).foregroundStyle(.secondary)
                    HStack { Text("Speed"); Spacer(); optional(object.speed, { v in edit { $0.speed = v } }, "mm/min") }
                    HStack { Text("Power"); Spacer(); optional(object.powerPercent, { v in edit { $0.powerPercent = v } }, "%") }
                    HStack {
                        Text("Passes"); Spacer()
                        optional(object.passes.map(Double.init), { v in edit { $0.passes = v.map { max(1, Int($0)) } } }, "")
                    }
                    if !object.isImage {
                        Picker("Mode", selection: Binding(get: { object.mode }, set: { v in edit { $0.mode = v } })) {
                            Text("Layer").tag(VectorMode?.none)
                            Text("Lines").tag(VectorMode?.some(.line)); Text("Fill").tag(VectorMode?.some(.fill))
                            Text("Lines and fill").tag(VectorMode?.some(.lineAndFill))
                        }
                    }
                }.padding(.top, 4)
            }
        }
    }

    private func optional(_ v: Double?, _ set: @escaping (Double?) -> Void, _ unit: String) -> some View {
        HStack(spacing: 4) {
            TextField("–", value: Binding(get: { v }, set: set), format: .number.grouping(.never).precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 70)
            Text(unit).foregroundStyle(.secondary).font(.caption).frame(width: 44, alignment: .leading)
        }
    }

    @ViewBuilder private var kindSection: some View {
        switch object.kind {
        case .text(let spec):
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Text").font(.subheadline).fontWeight(.semibold)
                TextEditor(text: Binding(get: { spec.text }, set: { v in setSpec { $0.text = v } }))
                    .font(.system(size: 12)).frame(height: 56).border(Color.gray.opacity(0.3))
                Picker("Font", selection: Binding(get: { spec.fontName }, set: { v in setSpec { $0.fontName = v } })) {
                    ForEach(TextLayout.availableFonts(), id: \.self) { Text($0).tag($0) }
                }
                HStack { Text("Letter height"); Spacer(); numberField("mm", spec.size, { v in setSpec { $0.size = max(1, v) } }); Text("mm").foregroundStyle(.secondary) }
                if TextTemplate.hasPlaceholders(spec.text) {
                    HStack { Text("Serial number"); Spacer(); numberField("n", Double(layout.doc.serial), { v in layout.mutate { $0.serial = max(0, Int(v)) } }) }
                }
            }
        case .image(let id, let opts):
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Picture").font(.subheadline).fontWeight(.semibold)
                Picker("Tool", selection: Binding(get: { opts.tool }, set: { v in setOpts(id, opts) { $0.tool = v } })) {
                    Text("Line to line").tag(RasterTool.lineToLine); Text("1 bit dithering").tag(RasterTool.dithering)
                }
                HStack { Text("Quality"); Spacer(); numberField("lines/mm", opts.linesPerMM, { v in setOpts(id, opts) { $0.linesPerMM = min(20, max(0.5, v)) } }); Text("lines/mm").foregroundStyle(.secondary).font(.caption) }
                HStack {
                    Button { cropToSubject(id, opts) } label: { IconLabel("Crop to Subject", icon: "crop", size: 12) }
                        .help("Cut away the empty border around the subject (transparent or flat background)")
                    Spacer()
                    if opts.cropLeft + opts.cropTop + opts.cropRight + opts.cropBottom > 0 {
                        Button("Reset Crop") { resetCrop(id, opts) }.controlSize(.small)
                    }
                }
                Toggle("Invert", isOn: Binding(get: { opts.invert }, set: { v in setOpts(id, opts) { $0.invert = v } }))
                Toggle("Mirror horizontally", isOn: Binding(get: { opts.flipH }, set: { v in setOpts(id, opts) { $0.flipH = v } }))
                Toggle("Mirror vertically", isOn: Binding(get: { opts.flipV }, set: { v in setOpts(id, opts) { $0.flipV = v } }))
                HStack { Text("Brightness"); Slider(value: Binding(get: { Double(opts.brightness) }, set: { v in setOpts(id, opts) { $0.brightness = Int(v) } }), in: 40...160) }
                HStack { Text("Contrast"); Slider(value: Binding(get: { Double(opts.contrast) }, set: { v in setOpts(id, opts) { $0.contrast = Int(v) } }), in: 40...160) }
            }
        default: EmptyView()
        }
    }

    private func setSpec(_ f: @escaping (inout TextSpec) -> Void) {
        edit { o in
            guard case .text(var s) = o.kind else { return }
            f(&s); o.kind = .text(s)
            let (w, h) = o.nativeSize(serial: layout.doc.serial)
            o.width = max(0.1, w); o.height = max(0.1, h)
        }
    }

    /// Crops to the subject and keeps the width, so the picture keeps its scale on the work area.
    private func cropToSubject(_ id: String, _ opts: RasterOptions) {
        guard let img = layout.cgImage(id), let c = RasterConverter.subjectCrop(of: img) else { return }
        var o = opts; o.cropLeft = c.left; o.cropTop = c.top; o.cropRight = c.right; o.cropBottom = c.bottom
        applyCrop(id, o, img)
    }

    private func resetCrop(_ id: String, _ opts: RasterOptions) {
        guard let img = layout.cgImage(id) else { return }
        var o = opts; o.cropLeft = 0; o.cropTop = 0; o.cropRight = 0; o.cropBottom = 0
        applyCrop(id, o, img)
    }

    private func applyCrop(_ id: String, _ o: RasterOptions, _ img: CGImage) {
        let aspect = RasterConverter.aspect(of: img, o)
        edit { obj in
            obj.kind = .image(imageID: id, options: o)
            obj.height = max(0.1, (obj.width * aspect * 100).rounded() / 100)
        }
    }

    private func setOpts(_ id: String, _ opts: RasterOptions, _ f: (inout RasterOptions) -> Void) {
        var o = opts; f(&o)
        edit { $0.kind = .image(imageID: id, options: o) }
    }
}

private struct LayersSection: View {
    @ObservedObject var layout: LayoutModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Button { layout.addLayer() } label: { IconLabel("Add Layer", icon: "plus", size: 12) }.buttonStyle(.borderless)
            }
            Text("Layers run from top to bottom: engrave first, cut last.").font(.caption).foregroundStyle(.secondary)
            ForEach(layout.doc.layers) { layer in
                LayerRow(layout: layout, layer: layer)
            }
        }
    }
}

private struct LayerRow: View {
    @ObservedObject var layout: LayoutModel
    let layer: LayoutLayer

    private func edit(_ f: @escaping (inout LayoutLayer) -> Void) {
        layout.mutate { d in if let i = d.layers.firstIndex(where: { $0.id == layer.id }) { f(&d.layers[i]) } }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: layer.colorHex)).frame(width: 10, height: 10)
                    TextField("Name", text: Binding(get: { layer.name }, set: { v in edit { $0.name = v } })).textFieldStyle(.plain).fontWeight(.medium)
                    Spacer()
                    Toggle("Show", isOn: Binding(get: { layer.visible }, set: { v in edit { $0.visible = v } })).toggleStyle(.checkbox).labelsHidden().help("Show")
                    Toggle("Burn", isOn: Binding(get: { layer.output }, set: { v in edit { $0.output = v } })).toggleStyle(.checkbox).labelsHidden().help("Burn this layer")
                    Button { layout.moveLayer(layer.id, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                    Button { layout.moveLayer(layer.id, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                    if layout.doc.layers.count > 1 {
                        Button { layout.deleteLayer(layer.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                Picker("Mode", selection: Binding(get: { layer.mode }, set: { v in edit { $0.mode = v } })) {
                    Text("Lines").tag(VectorMode.line); Text("Fill").tag(VectorMode.fill); Text("Lines and fill").tag(VectorMode.lineAndFill)
                }.labelsHidden().pickerStyle(.segmented)
                HStack(spacing: 8) {
                    Text("Speed"); numberField("mm/min", layer.speed, { v in edit { $0.speed = max(1, v) } }, width: 60)
                    Text("Power"); numberField("%", layer.powerPercent, { v in edit { $0.powerPercent = min(100, max(0, v)) } }, width: 46)
                    Text("Passes"); numberField("", Double(layer.passes), { v in edit { $0.passes = max(1, Int(v)) } }, width: 36)
                }.font(.caption)
            }
            .padding(2)
        }
    }
}
