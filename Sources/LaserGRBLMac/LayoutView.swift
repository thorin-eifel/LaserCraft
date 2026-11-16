import SwiftUI
import AppKit
import LaserGRBLCore

// MARK: - inspector

struct LayoutInspector: View {
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

func numberField(_ title: String, _ value: Double, _ set: @escaping (Double) -> Void, width: CGFloat = 64) -> some View {
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
                Text("Rotation").foregroundStyle(.secondary)
                NumberInput(value: Binding(get: { object.rotation }, set: { v in edit { o in
                    var r = v.truncatingRemainder(dividingBy: 360); if r < 0 { r += 360 }
                    o.rotation = r
                } }), digits: 1, width: 60)
                Text(verbatim: "°").foregroundStyle(.secondary)
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
                if layer.passes > 1 {
                    HStack(spacing: 8) {
                        Text("Lower focus per pass"); numberField("mm", layer.focusStep, { v in edit { $0.focusStep = min(20, max(-20, v)) } }, width: 46)
                    }.font(.caption)
                    .help("Moves the Z axis down by this many mm with every further pass (0 = no Z movement). Z0 must be the focus you set before the job.")
                }
                Toggle("Pause before this layer", isOn: Binding(get: { layer.pauseBefore }, set: { v in edit { $0.pauseBefore = v } }))
                    .font(.caption)
                    .help("The job stops here with a message, for example to flip the material. Resume continues it.")
                if layer.pauseBefore {
                    TextField("Message shown at the pause", text: Binding(get: { layer.pauseNote }, set: { v in edit { $0.pauseNote = String(v.prefix(60)) } }))
                        .textFieldStyle(.roundedBorder).font(.caption)
                }
            }
            .padding(2)
        }
    }
}
