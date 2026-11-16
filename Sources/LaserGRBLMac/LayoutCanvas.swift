import SwiftUI
import AppKit
import LaserGRBLCore

// MARK: - viewport (zoom and pan)

/// Which part of the work area is shown. `zoom` 1 shows all of it; `pan` moves it, in points.
struct LayoutViewport: Equatable {
    var zoom = 1.0
    var pan = CGPoint.zero
    static let zoomRange = 0.25...40.0

    /// Points per mm that make the whole area fit (with a margin).
    static func fitScale(area: (Double, Double), size: CGSize, margin: Double = 24) -> Double {
        max(0.01, min((Double(size.width) - 2 * margin) / area.0, (Double(size.height) - 2 * margin) / area.1))
    }

    func scale(area: (Double, Double), size: CGSize) -> Double { LayoutViewport.fitScale(area: area, size: size) * zoom }

    /// Where the top left corner of the work area is in the view.
    func origin(area: (Double, Double), size: CGSize) -> CGPoint {
        let s = scale(area: area, size: size)
        return CGPoint(x: Double(size.width) / 2 - area.0 * s / 2 + Double(pan.x), y: Double(size.height) / 2 - area.1 * s / 2 + Double(pan.y))
    }

    /// Zooms by a factor and keeps the point under `anchor` (view coordinates) where it is.
    mutating func zoom(by factor: Double, around anchor: CGPoint, area: (Double, Double), size: CGSize) {
        let old = scale(area: area, size: size), o = origin(area: area, size: size)
        let mm = ((Double(anchor.x) - Double(o.x)) / old, area.1 - (Double(anchor.y) - Double(o.y)) / old)
        zoom = min(LayoutViewport.zoomRange.upperBound, max(LayoutViewport.zoomRange.lowerBound, zoom * factor))
        let s = scale(area: area, size: size)
        let wantedX = Double(anchor.x) - mm.0 * s, wantedY = Double(anchor.y) - (area.1 - mm.1) * s
        pan = CGPoint(x: wantedX - (Double(size.width) / 2 - area.0 * s / 2), y: wantedY - (Double(size.height) / 2 - area.1 * s / 2))
    }

    mutating func fit() { zoom = 1; pan = .zero }
}

/// Picks up trackpad scrolling (pan), pinching (zoom) and the space bar while the pointer is over the canvas.
struct ScrollZoomCatcher: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat, Bool) -> Void          // dx, dy, command held (zoom instead of pan)
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onSpace: (Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.owner = self
        return v
    }
    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.owner = self }

    final class CatcherView: NSView {
        var owner: ScrollZoomCatcher?
        private var monitors: [Any] = []
        private var spaceIsDown = false
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            monitors.forEach { NSEvent.removeMonitor($0) }
            monitors = []
            guard window != nil else { return }
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in self?.handle(e) ?? e } as Any)
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in self?.key(e) ?? e } as Any)
        }

        deinit { monitors.forEach { NSEvent.removeMonitor($0) } }

        private func inside(_ e: NSEvent) -> NSPoint? {
            guard e.window === window else { return nil }
            let p = convert(e.locationInWindow, from: nil)
            return bounds.contains(p) ? p : nil
        }

        private func handle(_ e: NSEvent) -> NSEvent? {
            guard let p = inside(e), let o = owner else { return e }
            if e.type == .magnify { o.onMagnify(e.magnification, p); return nil }
            let dx = e.hasPreciseScrollingDeltas ? e.scrollingDeltaX : e.scrollingDeltaX * 8
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
            if e.modifierFlags.contains(.command) { o.onMagnify(dy / 120, p) } else { o.onScroll(dx, dy, false) }
            return nil
        }

        private func key(_ e: NSEvent) -> NSEvent? {
            guard e.keyCode == 49, !(window?.firstResponder is NSText) else { return e }
            let mouse = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
            guard bounds.contains(mouse) || spaceIsDown else { return e }
            let down = e.type == .keyDown
            if e.isARepeat { return nil }
            spaceIsDown = down
            owner?.onSpace(down)
            return nil
        }
    }
}

// MARK: - editor

struct LayoutEditor: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var layout: LayoutModel
    @State private var showArray = false

    var body: some View {
        VStack(spacing: 0) {
            LayoutToolbar(layout: layout, showArray: $showArray)
            Divider()
            HSplitView {
                LayoutCanvas(layout: layout)
                    .frame(minWidth: 320)
                LayoutInspector(layout: layout)
                    .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
            }
        }
        .sheet(isPresented: $showArray) { ArraySheet(layout: layout) }
    }
}

private struct LayoutToolbar: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var layout: LayoutModel
    @Binding var showArray: Bool

    var body: some View {
        let count = layout.selectedIDs.count
        HStack(spacing: 6) {
            Menu {
                Button("Add Picture…") { app.addPictureToLayout() }
                Button("Add Vector File…") { app.addSVGToLayout() }
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
            Button { layout.duplicateSelection() } label: { IconLabel("Duplicate", icon: "copy") }.labelStyle(.iconOnly).disabled(count == 0).help("Duplicate")
            Button { let a = app.machineArea; layout.centerSelection(inWidth: a.0, height: a.1) } label: { IconLabel("Center", icon: "center") }
                .labelStyle(.iconOnly).disabled(layout.selected == nil).help("Center in the work area")
            Button { layout.deleteSelection() } label: { IconLabel("Delete Button", icon: "trash") }.labelStyle(.iconOnly).disabled(count == 0).help("Delete Button")
            Divider().frame(height: 16)
            Menu {
                Menu("Align") {
                    ForEach(AlignEdge.allCases, id: \.self) { e in
                        Button(LayoutToolbar.title(e)) { layout.align(e, workArea: app.machineArea) }
                    }
                }.disabled(count == 0)
                Menu("Distribute") {
                    Button("Horizontally") { layout.distribute(.horizontal) }
                    Button("Vertically") { layout.distribute(.vertical) }
                }.disabled(count < 3)
                Divider()
                Button("Array…") { showArray = true }.disabled(layout.selected == nil)
                Button("Select All") { layout.selectAll() }.keyboardShortcut("a").disabled(layout.doc.isEmpty)
            } label: { IconLabel("Arrange", icon: "arrange") }
            .menuStyle(.borderlessButton).fixedSize()
            Divider().frame(height: 16)
            Button { layout.zoom(by: 1 / 1.25) } label: { IconLabel("Zoom Out", icon: "zoomout") }.labelStyle(.iconOnly).help("Zoom out")
            Text(verbatim: "\(Int((layout.viewport.zoom * 100).rounded())) %").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 44)
            Button { layout.zoom(by: 1.25) } label: { IconLabel("Zoom In", icon: "zoomin") }.labelStyle(.iconOnly).help("Zoom in")
            Button { layout.viewport.fit() } label: { IconLabel("Fit to window", icon: "fit") }.labelStyle(.iconOnly).help("Fit to window")
            Spacer()
            Button { app.useLayoutAsJob(); app.mainMode = .job } label: { IconLabel("Use as Job", icon: "play") }
                .disabled(layout.doc.isEmpty).help("Make the G-code from this layout and show it in the job preview")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    static func title(_ e: AlignEdge) -> LocalizedStringKey {
        switch e {
        case .left: return "Left"
        case .centerX: return "Center Horizontally"
        case .right: return "Right"
        case .top: return "Top"
        case .centerY: return "Center Vertically"
        case .bottom: return "Bottom"
        }
    }
}

// MARK: - array sheet

struct ArraySheet: View {
    @ObservedObject var layout: LayoutModel
    @Environment(\.dismiss) var dismiss
    @State private var rows = 2.0
    @State private var columns = 3.0
    @State private var gapX = 5.0
    @State private var gapY = 5.0
    @State private var number = true
    @State private var start = 1.0

    private var hasPlaceholder: Bool {
        if case .text(let s)? = layout.selected?.kind { return TextTemplate.hasPlaceholders(s.text) && s.text.contains("{n") }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.group) {
            Text("Array").font(.title2).fontWeight(.semibold)
            Text("Makes rows and columns of copies of the selected object, for series production.").foregroundStyle(.secondary).font(.callout)
            UnitRow("Rows", value: $rows, range: 1...100, digits: 0)
            UnitRow("Columns", value: $columns, range: 1...100, digits: 0)
            UnitRow("Gap between columns", value: $gapX, range: -1000...1000, unit: "mm")
            UnitRow("Gap between rows", value: $gapY, range: -1000...1000, unit: "mm")
            if hasPlaceholder {
                Toggle("Give every copy its own number ({n})", isOn: $number)
                if number { UnitRow("First number", value: $start, range: 0...999_999, digits: 0) }
            }
            Text(L("%d copies", Int(rows) * Int(columns))).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Array") {
                    layout.makeArray(rows: Int(rows), columns: Int(columns), gapX: gapX, gapY: gapY, numberFrom: hasPlaceholder && number ? Int(start) : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(Int(rows) * Int(columns) < 2)
            }
        }
        .padding(Metrics.dialog).frame(width: 420)
    }
}

// MARK: - canvas

struct LayoutCanvas: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var layout: LayoutModel
    @AppStorage("layoutSnap") private var snap = 1.0

    private enum Drag {
        case move(primary: Pt, starts: [String: Pt], from: Pt)
        case resize(corner: Int, box: Bounds, aspect: Double)
        case rotate
        case pan(last: CGPoint)
    }
    @State private var drag: Drag?
    @State private var spaceDown = false

    private struct Geometry {
        var scale: Double, ox: Double, oy: Double, w: Double, h: Double
        func pt(_ p: Pt) -> CGPoint { CGPoint(x: ox + p.x * scale, y: oy + (h - p.y) * scale) }
        func mm(_ p: CGPoint) -> Pt { Pt((Double(p.x) - ox) / scale, h - (Double(p.y) - oy) / scale) }
    }

    private func geometry(_ size: CGSize) -> Geometry {
        let area = app.machineArea
        let o = layout.viewport.origin(area: area, size: size)
        return Geometry(scale: layout.viewport.scale(area: area, size: size), ox: Double(o.x), oy: Double(o.y), w: area.0, h: area.1)
    }

    var body: some View {
        GeometryReader { proxy in
            let g = geometry(proxy.size)
            Canvas { ctx, _ in draw(ctx, g) }
                .background(Color(nsColor: .underPageBackgroundColor))
                .background(ScrollZoomCatcher(
                    onScroll: { dx, dy, _ in layout.viewport.pan.x += dx; layout.viewport.pan.y += dy },
                    onMagnify: { f, p in layout.viewport.zoom(by: 1 + Double(f), around: p, area: app.machineArea, size: proxy.size) },
                    onSpace: { spaceDown = $0 }))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in dragChanged(v, g) }
                    .onEnded { _ in drag = nil; layout.endInteraction() })
                .onAppear { layout.viewSize = proxy.size; layout.viewArea = app.machineArea }
                .onChange(of: proxy.size) { _, new in layout.viewSize = new }
                .focusable()
                .onDeleteCommand { layout.deleteSelection() }
                .overlay(alignment: .bottomLeading) {
                    Text(L("Work area %.0f × %.0f mm", g.w, g.h)).font(.caption).foregroundStyle(.secondary).padding(8)
                }
                .overlay(alignment: .top) {
                    Text("Scroll to move, pinch or ⌘-scroll to zoom, hold Space and drag to pan.").font(.caption2).foregroundStyle(.tertiary).padding(6)
                }
                .overlay {
                    if layout.doc.isEmpty {
                        VStack(spacing: 6) {
                            Text("The layout is empty").font(.headline)
                            Text("Add a picture, a vector file (SVG, DXF, PDF) or a text with the + button.").foregroundStyle(.secondary)
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
        // grid: 10 mm, stronger every 50 mm; finer grids only when the lines are far enough apart
        let step = g.scale * 10 < 6 ? 50.0 : 10.0
        var grid = Path(), strong = Path()
        var gx = 0.0
        while gx <= g.w {
            var line = Path(); line.move(to: g.pt(Pt(gx, 0))); line.addLine(to: g.pt(Pt(gx, g.h)))
            if Int(gx) % 50 == 0 { strong.addPath(line) } else { grid.addPath(line) }
            gx += step
        }
        var gy = 0.0
        while gy <= g.h {
            var line = Path(); line.move(to: g.pt(Pt(0, gy))); line.addLine(to: g.pt(Pt(g.w, gy)))
            if Int(gy) % 50 == 0 { strong.addPath(line) } else { grid.addPath(line) }
            gy += step
        }
        ctx.stroke(grid, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)
        ctx.stroke(strong, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
        ctx.stroke(Path(bed), with: .color(.gray.opacity(0.7)), lineWidth: 1)
        let o = g.pt(Pt(0, 0))
        var axes = Path(); axes.move(to: CGPoint(x: o.x, y: o.y - 22)); axes.addLine(to: o); axes.addLine(to: CGPoint(x: o.x + 22, y: o.y))
        ctx.stroke(axes, with: .color(.red.opacity(0.8)), lineWidth: 1.5)

        for layer in layout.doc.layers where layer.visible {
            let color = Color(hex: layer.colorHex).opacity(layer.output ? 1 : 0.35)
            for obj in layout.doc.objects where obj.layer == layer.id && obj.visible {
                switch obj.kind {
                case .image(let id, let opts):
                    if let cg = layout.cgImage(id) {
                        let t = RasterConverter.transformed(cg, opts)
                        var c2 = ctx
                        let centre = g.pt(Pt(obj.x + obj.width / 2, obj.y + obj.height / 2))
                        c2.translateBy(x: centre.x, y: centre.y)
                        c2.rotate(by: .degrees(-obj.rotation))
                        c2.opacity = layer.output ? 0.9 : 0.35
                        let r = CGRect(x: -obj.width * g.scale / 2, y: -obj.height * g.scale / 2, width: obj.width * g.scale, height: obj.height * g.scale)
                        c2.draw(Image(decorative: t, scale: 1), in: r)
                        c2.opacity = 1
                        c2.stroke(Path(r), with: .color(color), lineWidth: 1)
                    }
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
        // selection: the turned box of every selected object, handles on the main one
        for obj in layout.selectedObjects {
            let corners = obj.orientedCorners().map { g.pt($0) }
            var box = Path(); box.move(to: corners[0]); corners.dropFirst().forEach { box.addLine(to: $0) }; box.closeSubpath()
            let isMain = obj.id == layout.selection
            ctx.stroke(box, with: .color(isMain ? .accentColor : .accentColor.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            guard isMain, layout.selectedIDs.count == 1 || isMain, !obj.locked else { continue }
            if obj.rotation == 0 {
                for c in 0..<4 { drawHandle(&ctx, corners[c]) }
            }
            let (from, handle) = rotateHandle(obj, g)
            var stem = Path(); stem.move(to: from); stem.addLine(to: handle)
            ctx.stroke(stem, with: .color(.accentColor), lineWidth: 1)
            let r = CGRect(x: handle.x - 5, y: handle.y - 5, width: 10, height: 10)
            ctx.fill(Path(ellipseIn: r), with: .color(.white))
            ctx.stroke(Path(ellipseIn: r), with: .color(.accentColor), lineWidth: 1.4)
        }
    }

    private func drawHandle(_ ctx: inout GraphicsContext, _ p: CGPoint) {
        let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
        ctx.fill(Path(r), with: .color(.white))
        ctx.stroke(Path(r), with: .color(.accentColor), lineWidth: 1.2)
    }

    /// Top middle of the turned box and the turning handle 24 pt beyond it.
    private func rotateHandle(_ o: LayoutObject, _ g: Geometry) -> (CGPoint, CGPoint) {
        let th = o.rotation * .pi / 180
        let c = g.pt(Pt(o.x + o.width / 2, o.y + o.height / 2))
        let up = CGPoint(x: -sin(th), y: -cos(th))                // "up" of the object on the screen
        let half = o.height * g.scale / 2
        return (CGPoint(x: c.x + up.x * half, y: c.y + up.y * half), CGPoint(x: c.x + up.x * (half + 24), y: c.y + up.y * (half + 24)))
    }

    // MARK: mouse

    private func objectAt(_ p: Pt) -> LayoutObject? {
        for o in layout.doc.objects.reversed() where o.visible {
            if let l = layout.doc.layer(o.layer), !l.visible { continue }
            if o.contains(p) { return o }
        }
        return nil
    }

    private func snapped(_ v: Double) -> Double { snap > 0 ? (v / snap).rounded() * snap : v }

    private func dragChanged(_ v: DragGesture.Value, _ g: Geometry) {
        if spaceDown {
            if case .pan(let last)? = drag { layout.viewport.pan.x += v.location.x - last.x; layout.viewport.pan.y += v.location.y - last.y }
            drag = .pan(last: v.location)
            return
        }
        let here = g.mm(v.location)
        if drag == nil {
            if let s = layout.selected, !s.locked {
                let (_, handle) = rotateHandle(s, g)
                if hypot(handle.x - v.startLocation.x, handle.y - v.startLocation.y) < 10 { drag = .rotate }
                else if s.rotation == 0 {
                    let corners = s.orientedCorners().map { g.pt($0) }
                    for c in 0..<4 where hypot(corners[c].x - v.startLocation.x, corners[c].y - v.startLocation.y) < 9 {
                        var b = Bounds(); b.add(s.x, s.y); b.add(s.x + s.width, s.y + s.height)
                        drag = .resize(corner: c, box: b, aspect: max(1e-6, b.width) / max(1e-6, b.height))
                        break
                    }
                }
            }
            if drag == nil {
                let start = g.mm(v.startLocation)
                if let o = objectAt(start) {
                    let additive = NSEvent.modifierFlags.contains(.shift)
                    if additive { layout.select(o.id, additive: true) }
                    else if !layout.selectedIDs.contains(o.id) { layout.select(o.id) }
                    if let m = layout.selected {
                        drag = .move(primary: Pt(m.x, m.y), starts: Dictionary(uniqueKeysWithValues: layout.selectedObjects.map { ($0.id, Pt($0.x, $0.y)) }), from: start)
                    } else { return }
                } else { layout.select(nil); return }
            }
        }
        switch drag {
        case .move(let primary, let starts, let from)?:
            let nx = snapped(primary.x + here.x - from.x), ny = snapped(primary.y + here.y - from.y)
            layout.moveSelected(by: nx - primary.x, ny - primary.y, from: starts)
        case .resize(let corner, let box, let aspect)?:
            guard layout.selected != nil else { return }
            let fixed = [Pt(box.maxX, box.minY), Pt(box.minX, box.minY), Pt(box.minX, box.maxY), Pt(box.maxX, box.maxY)][corner]
            var w = abs(snapped(here.x) - fixed.x), h = abs(snapped(here.y) - fixed.y)
            if !NSEvent.modifierFlags.contains(.option) { if w / max(h, 1e-6) > aspect { w = h * aspect } else { h = w / aspect } }
            w = max(1, w); h = max(1, h)
            let left = here.x < fixed.x ? fixed.x - w : fixed.x, bottom = here.y < fixed.y ? fixed.y - h : fixed.y
            layout.updateSelected({ o in o.x = left; o.y = bottom; o.width = w; o.height = h }, interactive: true)
        case .rotate?:
            guard let s = layout.selected else { return }
            let cx = s.x + s.width / 2, cy = s.y + s.height / 2
            var deg = atan2(here.y - cy, here.x - cx) * 180 / .pi - 90
            if !NSEvent.modifierFlags.contains(.option) { deg = (deg / 15).rounded() * 15 }      // snaps every 15°, hold ⌥ for free turning
            deg = deg.truncatingRemainder(dividingBy: 360); if deg < 0 { deg += 360 }
            layout.updateSelected({ $0.rotation = (deg * 100).rounded() / 100 }, interactive: true)
        case .pan?, nil: break
        }
    }
}
