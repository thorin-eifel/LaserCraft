import SwiftUI
import LaserGRBLCore

/// Job preview: grid, machine area, tool path, progress overlay and the laser position.
struct PreviewView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var preview: PreviewModel
    @ObservedObject var controller: GrblController

    @State private var scale: CGFloat = 2          // points per mm
    @State private var origin = CGPoint(x: 30, y: 30) // screen position of machine (0,0) measured from bottom-left
    @State private var dragStart: CGPoint?
    @State private var scaleStart: CGFloat?
    @State private var lastSize = CGSize(width: 600, height: 400)
    /// Once the person pans or zooms, the view stops re-fitting itself when the window is resized.
    @State private var userAdjusted = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("previewShowTravel") private var showTravel = true
    @AppStorage("previewShowGrid") private var showGrid = true
    @AppStorage("previewFollowsAppearance") private var followsAppearance = false

    /// The sheet is white like paper unless the person asks the preview to follow dark mode.
    private var darkPaper: Bool { followsAppearance && colorScheme == .dark }
    private var paperColor: Color { darkPaper ? Color(white: 0.11) : .white }
    private var labelColor: Color { Color(white: darkPaper ? 0.72 : 0.35) }
    private var inkColor: Color { darkPaper ? .white : .black }
    private var panelColor: Color { darkPaper ? Color(white: 0.2) : .white }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var machineArea: (Double, Double)? {
        if let x = Double(controller.settings[130] ?? ""), let y = Double(controller.settings[131] ?? ""), x > 0, y > 0 { return (x, y) }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                draw(&ctx, size: size)
            }
            .background(paperColor)
            .accessibilityElement()
            .accessibilityLabel(Text("Job preview"))
            .accessibilityValue(Text(accessibilitySummary))
            .overlay(alignment: .topLeading) { zoomControls }
            .overlay(alignment: .topTrailing) { readout }
            .overlay(alignment: .bottomLeading) { legend }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        userAdjusted = true
                        if dragStart == nil { dragStart = origin }
                        origin = CGPoint(x: dragStart!.x + v.translation.width, y: dragStart!.y - v.translation.height)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { m in
                        userAdjusted = true
                        if scaleStart == nil { scaleStart = scale }
                        zoom(to: max(0.05, min(200, scaleStart! * m)), around: CGPoint(x: lastSize.width / 2, y: lastSize.height / 2))
                    }
                    .onEnded { _ in scaleStart = nil }
            )
            .onAppear { lastSize = geo.size; fit(size: geo.size) }
            .onChange(of: geo.size) { _, new in lastSize = new; if !userAdjusted { fit(size: new) } }
            .onChange(of: preview.requestFit) { _, f in
                if f { fit(size: lastSize); preview.requestFit = false }
            }
            .onChange(of: controller.jobExecuted) { preview.updateDone(upTo: controller.executedProgramCommands) }
            .onChange(of: controller.jobRunning) { _, r in if r { preview.updateDone(upTo: 0) } }
        }
        .clipped()
    }

    // MARK: drawing

    private func toScreen(_ x: Double, _ y: Double, _ h: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(x) * scale, y: h - (origin.y + CGFloat(y) * scale))
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        _ = preview.revision
        // grid
        let step: Double = scale > 8 ? 10 : (scale > 1.5 ? 50 : 100)
        let minX = Double(-origin.x / scale), maxX = Double((size.width - origin.x) / scale)
        let minY = Double(-origin.y / scale), maxY = Double((size.height - origin.y) / scale)
        var grid = Path()
        var gx = (minX / step).rounded(.down) * step
        while gx <= maxX {
            let a = toScreen(gx, minY, size.height), b = toScreen(gx, maxY, size.height)
            grid.move(to: a); grid.addLine(to: b); gx += step
        }
        var gy = (minY / step).rounded(.down) * step
        while gy <= maxY {
            let a = toScreen(minX, gy, size.height), b = toScreen(maxX, gy, size.height)
            grid.move(to: a); grid.addLine(to: b); gy += step
        }
        if showGrid {
            let g = contrast == .increased ? 0.7 : 0.9
            ctx.stroke(grid, with: .color(Color(white: darkPaper ? 1 - g : g)), lineWidth: contrast == .increased ? 1 : 0.5)
        }

        // machine area
        if let (w, h) = machineArea {
            let p0 = toScreen(0, 0, size.height), p1 = toScreen(w, h, size.height)
            let r = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
            ctx.stroke(Path(r), with: .color(.blue.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        }

        // axes
        let o = toScreen(0, 0, size.height)
        var axes = Path()
        axes.move(to: CGPoint(x: o.x, y: 0)); axes.addLine(to: CGPoint(x: o.x, y: size.height))
        axes.move(to: CGPoint(x: 0, y: o.y)); axes.addLine(to: CGPoint(x: size.width, y: o.y))
        ctx.stroke(axes, with: .color(.red.opacity(0.35)), lineWidth: 1)

        // job: draw in machine millimetres through a transform so the big paths aren't rebuilt
        if preview.program != nil {
            var c = ctx
            c.translateBy(x: origin.x, y: size.height - origin.y)
            c.scaleBy(x: scale, y: -scale)
            let hairline = 1 / scale
            if showTravel { c.stroke(preview.travel, with: .color(.blue.opacity(darkPaper ? 0.4 : 0.18)), lineWidth: hairline) }
            let w = max(hairline, 0.12)   // ~laser spot
            for layer in preview.burn {
                c.stroke(layer.path, with: .color(Color(white: darkPaper ? 1 - layer.gray : layer.gray)), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
            if controller.jobRunning || controller.jobExecuted > 0 {
                c.stroke(preview.done, with: .color(.green.opacity(0.75)), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
        }

        // laser head
        if controller.isConnected {
            let p = controller.workPosition
            let c = toScreen(p.x, p.y, size.height)
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - 9, y: c.y)); cross.addLine(to: CGPoint(x: c.x + 9, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: c.y - 9)); cross.addLine(to: CGPoint(x: c.x, y: c.y + 9))
            ctx.stroke(cross, with: .color(.red), lineWidth: 1.5)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.red), lineWidth: 1.5)
        }

        // mm ruler labels
        let labelStep = step * (scale < 4 ? 1 : 1)
        var lx = (max(minX, 0) / labelStep).rounded(.up) * labelStep
        while lx <= maxX {
            let p = toScreen(lx, 0, size.height)
            ctx.draw(Text("\(Int(lx))").font(.system(size: 10)).foregroundColor(labelColor), at: CGPoint(x: p.x + 2, y: min(max(p.y, 8), size.height - 8) + 8), anchor: .leading)
            lx += labelStep
        }
        var ly = (max(minY, 0) / labelStep).rounded(.up) * labelStep
        while ly <= maxY {
            let p = toScreen(0, ly, size.height)
            if ly > 0 { ctx.draw(Text("\(Int(ly))").font(.system(size: 10)).foregroundColor(labelColor), at: CGPoint(x: min(max(p.x, 4), size.width - 20) + 3, y: p.y - 6), anchor: .leading) }
            ly += labelStep
        }

        if preview.program == nil {
            ctx.draw(Text("Open a G-code file or import an image").font(.title3).foregroundColor(labelColor),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
        }
    }

    // MARK: zoom & fit

    private func zoom(to s: CGFloat, around p: CGPoint) {
        userAdjusted = true
        // keep the machine point under `p` fixed
        let h = lastSize.height
        let mx = (p.x - origin.x) / scale
        let my = (h - p.y - origin.y) / scale
        scale = s
        origin = CGPoint(x: p.x - mx * s, y: h - p.y - my * s)
    }

    private func fit(size: CGSize) {
        userAdjusted = false
        var b = Bounds()
        if let p = preview.program, !p.travelBounds.isEmpty {
            b = p.burnBounds.isEmpty ? p.travelBounds : p.burnBounds
            b.minX = min(b.minX, 0); b.minY = min(b.minY, 0)
        } else if let (w, h) = machineArea {
            b.add(0, 0); b.add(w, h)
        } else { b.add(0, 0); b.add(300, 200) }
        let pad: CGFloat = 36
        let w = CGFloat(max(b.width, 1)), h = CGFloat(max(b.height, 1))
        let availW = size.width - 2 * pad, availH = size.height - 2 * pad
        let s: CGFloat = max(0.05, min(availW / w, availH / h))
        let extraX: CGFloat = (availW - w * s) / 2
        let extraY: CGFloat = (availH - h * s) / 2
        let ox: CGFloat = pad - CGFloat(b.minX) * s + extraX
        let oy: CGFloat = pad - CGFloat(b.minY) * s + extraY
        scale = s
        origin = CGPoint(x: ox, y: oy)
    }

    /// Work position of the laser, like the X/Y read-out of the Windows version.
    private var readout: some View {
        let p = controller.workPosition
        return Text(L("X: %.3f   Y: %.3f", p.x, p.y))
            .font(.system(.callout, design: .monospaced))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(panelColor.opacity(reduceTransparency ? 1 : 0.85), in: RoundedRectangle(cornerRadius: 6))
            .foregroundColor(inkColor)
            .padding(8)
            .accessibilityLabel(Text("Position"))
            .accessibilityValue(Text(String(format: "X %.3f, Y %.3f", p.x, p.y)))
    }

    private var accessibilitySummary: String {
        guard let p = controller.program else { return L("Open a G-code file or import an image") }
        var text = L("Estimated time %@", GCodeProgram.formatDuration(p.estimatedSeconds))
        if !p.burnBounds.isEmpty {
            text = L("Size %.1f × %.1f mm   Origin X%.1f Y%.1f", p.burnBounds.width, p.burnBounds.height, p.burnBounds.minX, p.burnBounds.minY) + ". " + text
        }
        return p.name + ". " + text
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { zoom(to: min(200, scale * 1.4), around: CGPoint(x: lastSize.width / 2, y: lastSize.height / 2)) } label: { IconLabel("Zoom in", icon: "zoomin", size: 14) }
                .help("Zoom in")
            Button { zoom(to: max(0.05, scale / 1.4), around: CGPoint(x: lastSize.width / 2, y: lastSize.height / 2)) } label: { IconLabel("Zoom out", icon: "zoomout", size: 14) }
                .help("Zoom out")
            Button { fit(size: lastSize) } label: { IconLabel("Fit to window", icon: "fit", size: 14) }
                .help("Fit to window")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(8)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let p = controller.program {
                Text(p.name).font(.caption).bold()
                if !p.burnBounds.isEmpty {
                    Text(L("Size %.1f × %.1f mm   Origin X%.1f Y%.1f", p.burnBounds.width, p.burnBounds.height, p.burnBounds.minX, p.burnBounds.minY)).font(.caption2)
                }
                Text(L("Estimated time %@", GCodeProgram.formatDuration(p.estimatedSeconds))).font(.caption2)
            }
        }
        .padding(6)
        .background(panelColor.opacity(reduceTransparency ? 1 : 0.85), in: RoundedRectangle(cornerRadius: 6))
        .foregroundColor(inkColor)
        .padding(8)
    }
}
