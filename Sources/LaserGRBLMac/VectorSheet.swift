import SwiftUI
import AppKit
import LaserGRBLCore

/// Chooses a material from the database and hands it back.
struct MaterialPicker: View {
    @EnvironmentObject var app: AppModel
    var action: MaterialAction?
    var onPick: (LaserMaterial) -> Void
    @State private var open = false
    @State private var machine = UserDefaults.standard.string(forKey: "materialMachine") ?? ""
    @State private var search = ""

    var body: some View {
        Button { open.toggle() } label: { IconLabel("Material…", icon: "book") }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Machine", selection: $machine) {
                        Text("All machines").tag("")
                        ForEach(app.materials.machines, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: machine) { UserDefaults.standard.set(machine, forKey: "materialMachine") }
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                    let list = app.materials.materials(machine: machine, action: action, search: search)
                    List(list.prefix(300)) { m in
                        Button {
                            onPick(m); open = false
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack {
                                    Text(m.title).fontWeight(.medium)
                                    Text(m.action == .cut ? L("Cut") : L("Engrave")).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(m.speed)) mm/min · \(Int(m.power)) % · ×\(m.passes)").font(.caption).foregroundStyle(.secondary)
                                }
                                if machine.isEmpty { Text(m.machine).font(.caption2).foregroundStyle(.tertiary) }
                            }
                        }.buttonStyle(.plain)
                    }
                    .frame(width: 440, height: 300)
                    Text(L("%d materials", list.count)).font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
            }
    }
}

/// Imports vector artwork (SVG, DXF, PDF; the `.svg` source stands for any vector file), traces a picture, or lays out a text; then burns it as lines or filled areas.
struct VectorSheet: View {
    let source: VectorSource
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss

    @State private var base: [Polyline] = []          // in its own units, origin at 0
    @State private var width = 50.0
    @State private var height = 50.0
    @State private var offsetX = 0.0
    @State private var offsetY = 0.0
    @State private var lockAspect = true
    @State private var settings = VectorSettings()
    @State private var layerID = 1
    @State private var dpi = 96.0
    @State private var page = 1
    @State private var pageCount = 1
    @State private var trace = TraceOptions()
    @State private var spec = TextSpec()
    @State private var errorText: String?
    @State private var working = false
    @State private var gray: (pixels: [UInt8], w: Int, h: Int)?

    private var shapes: [Polyline] { VectorMath.fit(base, toX: offsetX, y: offsetY, width: width, height: height) }

    private var title: String {
        switch source { case .svg: return L("Import Vector File"); case .trace: return L("Trace Image"); case .text: return L("Add Text") }
    }
    private var sourceName: String {
        switch source {
        case .svg(let u), .trace(let u): return u.deletingPathExtension().lastPathComponent
        case .text: return spec.text.components(separatedBy: "\n").first ?? "Text"
        }
    }
    private var sourceKey: String {
        switch source {
        case .svg(let u): return "svg|\(u.path)|\(dpi)|\(page)"
        case .trace(let u): return "trace|\(u.path)|" + Self.stableJSON(trace)
        case .text: return "text|" + Self.stableJSON(spec)
        }
    }

    /// Encodes with sorted keys: the same value always gives the same text (used to notice real changes).
    static func stableJSON<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(data: (try? e.encode(v)) ?? Data(), encoding: .utf8) ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ShapePreview(shapes: shapes, working: working, error: errorText)
                    .frame(minWidth: 380, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
                    .padding(12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.dialog) {
                        sourceSection
                        sizeSection
                        burnSection
                        statsSection
                    }
                    .padding(Metrics.dialog)
                }
                .frame(width: 380)
            }
            Divider()
            HStack {
                Text(L("%d shapes · %.0f × %.0f mm", shapes.count, width, height)).foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Layout") { addToLayout() }.disabled(base.isEmpty)
                Button("Create G-code") { createGCode() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(base.isEmpty)
            }
            .padding(12)
        }
        .fullSheetFrame()
        .task(id: sourceKey) { await rebuildBase() }
        .onAppear { applyDefaults() }
    }

    // MARK: sections

    @ViewBuilder private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).fontWeight(.semibold)
            switch source {
            case .svg(let url):
                switch VectorFileKind(url) {
                case .svg:
                    Picker("Resolution of unitless sizes", selection: $dpi) { Text("96 dpi (browsers, Inkscape)").tag(96.0); Text("72 dpi (Illustrator)").tag(72.0) }
                    Text("Sizes in mm, cm, in or pt are used as they are. Text in the file is not read: convert it to paths first.").font(.caption).foregroundStyle(.secondary)
                case .dxf:
                    Text("The drawing's units (INSUNITS) are converted to mm; without them 1 unit = 1 mm. Lines, arcs, circles, ellipses, polylines, splines and blocks are read; text, hatches and dimensions are not.").font(.caption).foregroundStyle(.secondary)
                case .pdf:
                    if pageCount > 1 { Stepper(L("Page %d of %d", page, pageCount), value: $page, in: 1...pageCount) }
                    Text("The vector lines of the page are read, in their real size. Pictures and scanned pages are not vectors: use Trace Image for those. Text is only read when it is stored as outlines.").font(.caption).foregroundStyle(.secondary)
                }
            case .trace:
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Method", selection: $trace.centerline) { Text("Outline").tag(false); Text("Centerline").tag(true) }.pickerStyle(.segmented)
                    labelSlider("Threshold", Binding(get: { Double(trace.threshold) }, set: { trace.threshold = Int($0) }), 10...245)
                    Toggle("Invert", isOn: $trace.invert)
                    Toggle("Smooth curves (Bézier fitting)", isOn: $trace.curves)
                        .help("Fits smooth curves through the outline: rounder shapes with far fewer lines. Corners stay sharp.")
                    if trace.curves {
                        labelSlider("Curve error", $trace.curveError, 0.3...2)
                        labelSlider("Corner angle", $trace.cornerAngle, 20...120)
                    } else {
                        labelSlider("Smoothing", Binding(get: { Double(trace.smoothing) }, set: { trace.smoothing = Int($0) }), 0...3, step: 1)
                        labelSlider("Simplify", $trace.tolerance, 0...3)
                    }
                    labelSlider("Ignore specks", Binding(get: { Double(trace.minArea) }, set: { trace.minArea = Int($0) }), 0...200)
                }
            case .text:
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $spec.text).font(.system(size: 13)).frame(height: 70).border(Color.gray.opacity(0.3))
                    Text("Use {n} for a serial number (counting up), {date} or {time}.").font(.caption).foregroundStyle(.secondary)
                    Picker("Font", selection: $spec.fontName) { ForEach(TextLayout.availableFonts(), id: \.self) { Text($0).tag($0) } }
                    Text(spec.fontName == TextSpec.hershey ? "Single-stroke letters: one line per stroke, ideal for engraving." : "The outlines of the letters are burnt.")
                        .font(.caption).foregroundStyle(.secondary)
                    UnitRow("Letter height", value: $spec.size, range: 1...200, unit: "mm")
                    UnitRow("Line spacing", value: $spec.lineSpacing, range: 0.8...3, unit: "×")
                    UnitRow("Letter spacing", value: $spec.letterSpacing, range: -2...20, unit: "mm")
                    Picker("Alignment", selection: $spec.align) {
                        Text("Left").tag(TextAlign.left); Text("Center").tag(TextAlign.center); Text("Right").tag(TextAlign.right)
                    }.pickerStyle(.segmented)
                }
            }
        }
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Size and position").font(.headline)
            UnitRow("Width", value: Binding(get: { width }, set: { v in setWidth(v) }), range: 0.1...3000, unit: "mm")
            UnitRow("Height", value: Binding(get: { height }, set: { v in setHeight(v) }), range: 0.1...3000, unit: "mm")
            UnitRow("Offset X", value: $offsetX, range: -5000...5000, unit: "mm")
            UnitRow("Offset Y", value: $offsetY, range: -5000...5000, unit: "mm")
            Toggle("Lock", isOn: $lockAspect).toggleStyle(.checkbox)
        }
    }

    private var burnSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Burn").font(.headline); Spacer(); MaterialPicker(action: nil) { m in apply(m) } }
            Picker("Mode", selection: $settings.mode) {
                Text("Lines").tag(VectorMode.line); Text("Fill").tag(VectorMode.fill); Text("Lines and fill").tag(VectorMode.lineAndFill)
            }.pickerStyle(.segmented)
            UnitRow("Speed", value: $settings.speed, range: 1...30000, unit: "mm/min", digits: 0)
            UnitRow("Power", value: $settings.powerPercent, range: 0...100, unit: "%", digits: 0)
            ControlRow("Passes") { Stepper(value: $settings.passes, in: 1...50) { Text("\(settings.passes)").monospacedDigit() } }
            if settings.mode != .line {
                UnitRow("Line distance", value: $settings.fillSpacing, range: 0.02...2, unit: "mm")
                UnitRow("Angle", value: $settings.fillAngle, range: 0...179, unit: "°", digits: 0)
                Toggle("Engrave in one direction only", isOn: Binding(get: { !settings.fillBothDirections }, set: { settings.fillBothDirections = !$0 }))
            }
            Toggle("M4 dynamic power", isOn: $settings.dynamicPower)
            Divider()
            Toggle("Shortest travel (reorder shapes)", isOn: $settings.optimize.reorder)
            Toggle("Inner shapes first", isOn: $settings.optimize.insideFirst).help("Cut-out pieces fall out last, so nothing moves while the outline is cut.")
            Picker("Layer", selection: $layerID) { ForEach(app.layout.doc.layers) { Text($0.name).tag($0.id) } }
        }
    }

    private var statsSection: some View {
        let (burn, travelBefore, travelAfter) = stats()
        let seconds = burn / max(settings.speed, 1) * 60 * Double(settings.passes)
        return VStack(alignment: .leading, spacing: 4) {
            Text(L("Burnt length %.0f mm · %@", burn * Double(settings.passes), GCodeProgram.formatDuration(seconds))).font(.caption)
            if travelBefore > travelAfter + 1 {
                Text(L("Travel moves %.0f mm instead of %.0f mm", travelAfter, travelBefore)).font(.caption).foregroundStyle(.green)
            }
            if !app.dynamicPowerDefault && !settings.dynamicPower { EmptyView() }
        }.foregroundStyle(.secondary)
    }

    private func stats() -> (Double, Double, Double) {
        let s = shapes
        guard !s.isEmpty, s.count < 4000 else { return (s.map { $0.length }.reduce(0, +), 0, 0) }
        var plain = settings; plain.optimize.reorder = false; plain.optimize.insideFirst = false
        let before = VectorJob.toolpaths(s, plain), after = VectorJob.toolpaths(s, settings)
        return (after.map { $0.length }.reduce(0, +), PathOptimizer.travelLength(before), PathOptimizer.travelLength(after))
    }

    private func labelSlider(_ name: LocalizedStringKey, _ v: Binding<Double>, _ r: ClosedRange<Double>, step: Double? = nil) -> some View {
        HStack(spacing: Metrics.related) {
            Text(name).frame(width: 104, alignment: .leading)
            if let step = step { Slider(value: v, in: r, step: step) } else { Slider(value: v, in: r) }
        }
    }

    private func field(_ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        TextField("", value: Binding(get: { v.wrappedValue }, set: { v.wrappedValue = min(r.upperBound, max(r.lowerBound, $0)) }), format: .number.grouping(.never).precision(.fractionLength(0...3)))
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 80)
    }

    // MARK: logic

    private func applyDefaults() {
        settings.dynamicPower = app.dynamicPowerDefault
        layerID = app.layout.doc.layers.last?.id ?? 0                 // outlines usually are cut
        if case .text = source {
            settings.mode = .line; settings.speed = 1500; settings.powerPercent = 60
            layerID = app.layout.doc.layers.first?.id ?? 0             // text is usually engraved
        }
    }

    private func apply(_ m: LaserMaterial) {
        settings.speed = m.speed; settings.powerPercent = m.power; settings.passes = m.passes
        if m.action == .cut { settings.mode = .line }
    }

    private func setWidth(_ v: Double) {
        let r = height / max(width, 1e-6); width = max(0.1, v); if lockAspect { height = max(0.1, width * r) }
    }
    private func setHeight(_ v: Double) {
        let r = width / max(height, 1e-6); height = max(0.1, v); if lockAspect { width = max(0.1, height * r) }
    }

    /// Reads the file / traces / lays out the text again; the size follows the natural size except for traced pictures.
    private func rebuildBase() async {
        working = true; errorText = nil
        defer { working = false }
        switch source {
        case .svg(let url):
            let d = dpi, pg = page
            let kind = VectorFileKind(url)
            if kind == .pdf, pageCount <= 1 { pageCount = max(1, PDFImport.pageCount(of: url)) }
            let result: Result<[Polyline], Error> = await Task.detached {
                switch kind {
                case .svg:
                    var o = SVGOptions(); o.dpi = d
                    return Result { try SVGParser.parse(contentsOf: url, options: o) }
                case .dxf: return Result { try DXFParser.parse(contentsOf: url) }
                case .pdf: return Result { try PDFImport.parse(contentsOf: url, page: pg) }
                }
            }.value
            switch result {
            case .success(let lines): setBase(lines, keepSize: false)
            case .failure(let e): base = []; errorText = e.localizedDescription
            }
        case .trace(let url):
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            if gray == nil { gray = await Task.detached { SVGGray.load(url) }.value }
            guard let g = gray else { base = []; errorText = L("This file could not be read as an image."); return }
            let opts = trace
            let lines = await Task.detached { Tracer.trace(gray: g.pixels, width: g.w, height: g.h, options: opts) }.value
            if Task.isCancelled { return }
            // pixel units -> keep the box of the whole picture so the size stays in proportion to it
            var full = lines
            var b = Bounds(); b.add(0, 0); b.add(Double(g.w), Double(g.h))
            let first = base.isEmpty
            full = VectorMath.transform(full, .identity)
            base = full
            if first || width <= 0 { width = 100; height = (100 * Double(g.h) / Double(g.w) * 10).rounded() / 10 }
            baseBox = b
            if lines.isEmpty { errorText = L("Nothing was found. Change the threshold.") }
        case .text:
            let lines = TextLayout.polylines(spec, serial: app.layout.doc.serial)
            setBase(lines, keepSize: false)
        }
    }

    @State private var baseBox = Bounds()

    private func setBase(_ lines: [Polyline], keepSize: Bool) {
        let b = VectorMath.bounds(lines)
        base = lines.isEmpty ? [] : VectorMath.transform(lines, .translate(-b.minX, -b.minY))
        if !keepSize, !b.isEmpty { width = max(0.1, b.width); height = max(0.1, b.height) }
        if lines.isEmpty { errorText = errorText ?? L("The file contains no shapes.") }
    }

    private func createGCode() {
        let lines = VectorJob.gcode(shapes, settings, maxS: app.maxS)
        let program = GCodeProgram(text: lines.joined(separator: "\n"), name: sourceName + ".nc", rapidRate: app.rapidRate)
        app.setProgram(program)
        app.mainMode = .job
        dismiss()
    }

    private func addToLayout() {
        let at = Pt(offsetX, offsetY)
        switch source {
        case .text: app.layout.addText(spec, layer: layerID, at: at, settings: settings)
        default: app.layout.addVectors(base, name: sourceName, layer: layerID, at: at, size: (width, height), settings: settings)
        }
        app.mainMode = .layout
        dismiss()
    }
}

/// Reads a picture as an 8-bit gray bitmap (at most 1400 pixels on the long side).
enum SVGGray {
    static func load(_ url: URL) -> (pixels: [UInt8], w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let scale = min(1, 1400.0 / Double(max(img.width, img.height)))
        let w = max(2, Int(Double(img.width) * scale)), h = max(2, Int(Double(img.height) * scale))
        var px = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (px, w, h)
    }
}

/// Draws outlines to fit the available space.
struct ShapePreview: View {
    let shapes: [Polyline]
    var working = false
    var error: String?

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .textBackgroundColor)))
                let b = VectorMath.bounds(shapes)
                guard !b.isEmpty else { return }
                let m = 16.0
                let s = min((size.width - 2 * m) / max(b.width, 1e-6), (size.height - 2 * m) / max(b.height, 1e-6))
                let ox = (size.width - b.width * s) / 2, oy = (size.height - b.height * s) / 2
                var path = Path()
                for l in shapes {
                    guard let f = l.points.first else { continue }
                    func pt(_ p: Pt) -> CGPoint { CGPoint(x: ox + (p.x - b.minX) * s, y: size.height - oy - (p.y - b.minY) * s) }
                    path.move(to: pt(f))
                    for p in l.points.dropFirst() { path.addLine(to: pt(p)) }
                    if l.closed { path.closeSubpath() }
                }
                ctx.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.4)))
            if working { ProgressView().controlSize(.small) }
            else if let e = error { Text(e).foregroundStyle(.secondary).multilineTextAlignment(.center).padding() }
        }
    }
}
