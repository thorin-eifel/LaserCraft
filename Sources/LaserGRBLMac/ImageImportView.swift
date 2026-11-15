import SwiftUI
import AppKit
import LaserGRBLCore

/// Saved import settings ("presets"): the built-in ones plus the person's own, kept in the user defaults.
final class PresetStore: ObservableObject {
    @Published private(set) var user: [ImagePreset]

    init() {
        if let data = UserDefaults.standard.data(forKey: "imagePresets"),
           let list = try? JSONDecoder().decode([ImagePreset].self, from: data) { user = list } else { user = [] }
    }

    var all: [ImagePreset] { ImagePreset.builtIns + user }

    func add(_ preset: ImagePreset) {
        user.removeAll { $0.name == preset.name }      // saving under an existing name replaces it
        user.append(preset)
        save()
    }

    func remove(_ id: UUID) {
        user.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(user) { UserDefaults.standard.set(data, forKey: "imagePresets") }
    }
}

/// Image import window: pick size and quality, crop and tune the picture, preview, then build the engraving G-code.
struct ImageImportView: View {
    let url: URL
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    @StateObject private var presets = PresetStore()
    @AppStorage("laserSpotSize") private var spotSize = 0.15

    @State private var source: CGImage?
    @State private var options = RasterOptions()
    @State private var cropNote: String?
    @State private var lockAspect = true
    @State private var aspect = 1.0                    // height / width after cropping and rotating
    @State private var previewImage: NSImage?
    @State private var working = false
    @State private var errorText: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var maxPowerPercent = 100.0
    @State private var minPowerPercent = 0.0
    @State private var selectedPreset: UUID?

    private var smax: Int { Int(app.controller.settings[30] ?? "") ?? 1000 }

    var body: some View {
        VStack(spacing: 0) {
        HStack(alignment: .top, spacing: 0) {
            VStack {
                ZStack {
                    Color.white
                    if let img = previewImage {
                        Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit).padding(8)
                    } else if source == nil {
                        Text(errorText ?? L("Loading…")).foregroundStyle(.secondary)
                    } else { ProgressView() }
                }
                .frame(minWidth: 380, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.4)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)

            Form {
                Section("Preset") {
                    HStack {
                        Picker("Preset", selection: $selectedPreset) {
                            Text("Custom").tag(UUID?.none)
                            ForEach(presets.all) { p in
                                (p.builtIn ? Text(LocalizedStringKey(p.name)) : Text(verbatim: p.name)).tag(UUID?.some(p.id))
                            }
                        }
                        .labelsHidden()
                        Button("Save Preset…") { savePreset() }
                        Button { deletePreset() } label: { IconLabel("Delete Preset", icon: "trash", size: 12) }
                            .labelStyle(.iconOnly)
                            .disabled(!(presets.user.contains { $0.id == selectedPreset }))
                            .help("Delete Preset")
                    }
                }
                .onChange(of: selectedPreset) { applySelectedPreset() }

                Section("Size and position") {
                    UnitRow("Width", value: Binding(get: { options.widthMM }, set: { w in
                        options.widthMM = w
                        if lockAspect { options.heightMM = (w * aspect * 100).rounded() / 100 }
                    }), range: 1...2000, unit: "mm", digits: 2)
                    UnitRow("Height", value: Binding(get: { options.heightMM }, set: { h in
                        options.heightMM = h
                        if lockAspect { options.widthMM = (h / aspect * 100).rounded() / 100 }
                    }), range: 1...2000, unit: "mm", digits: 2)
                    Toggle("Lock", isOn: $lockAspect)
                    UnitRow("Offset X", value: $options.offsetX, range: -5000...5000, unit: "mm", digits: 2)
                    UnitRow("Offset Y", value: $options.offsetY, range: -5000...5000, unit: "mm", digits: 2)
                }

                Section("Crop and Rotate") {
                    HStack {
                        Button { options.rotation = (options.rotation + 270) % 360 } label: { IconLabel("Rotate Left", icon: "rotl", size: 13) }
                            .help("Rotate Left")
                        Button { options.rotation = (options.rotation + 90) % 360 } label: { IconLabel("Rotate Right", icon: "rotr", size: 13) }
                            .help("Rotate Right")
                        Spacer()
                        Text(verbatim: "\(options.rotation)°").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .labelStyle(.iconOnly)
                    HStack(spacing: Metrics.related) {
                        Button { autoCrop() } label: { IconLabel("Crop to Subject", icon: "crop", size: 13) }
                            .help("Cut away the empty border around the subject (transparent or flat background)")
                            .disabled(source == nil)
                        if let note = cropNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Reset Crop") { options.cropLeft = 0; options.cropTop = 0; options.cropRight = 0; options.cropBottom = 0; cropNote = nil }
                            .controlSize(.small)
                            .disabled(options.cropLeft + options.cropTop + options.cropRight + options.cropBottom == 0)
                    }
                    Toggle("Mirror horizontally", isOn: $options.flipH)
                    Toggle("Mirror vertically", isOn: $options.flipV)
                    cropSlider("Crop left", $options.cropLeft)
                    cropSlider("Crop top", $options.cropTop)
                    cropSlider("Crop right", $options.cropRight)
                    cropSlider("Crop bottom", $options.cropBottom)
                }

                Section("Conversion") {
                    Picker("Tool", selection: $options.tool) {
                        ForEach(RasterTool.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }
                    Picker("Direction", selection: $options.direction) {
                        ForEach(FillDirection.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }
                    Toggle("Engrave in one direction only", isOn: $options.unidirectional)
                    ControlRow("Quality") {
                        Stepper(value: $options.linesPerMM, in: 0.5...20, step: 0.5) {
                            Text(L("%.1f lines/mm", options.linesPerMM)).monospacedDigit()
                        }
                    }
                    resolutionHelper
                    if options.tool == .dithering {
                        Picker("Dithering", selection: $options.dithering) {
                            ForEach(DitherMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                        }
                    }
                }

                Section("Picture") {
                    Picker("Grayscale", selection: $options.formula) {
                        ForEach(GrayFormula.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }
                    if options.formula == .custom {
                        slider("Red", $options.red, 40...160)
                        slider("Green", $options.green, 40...160)
                        slider("Blue", $options.blue, 40...160)
                    }
                    slider("Brightness", $options.brightness, 40...160)
                    slider("Contrast", $options.contrast, 40...160)
                    slider("White clip", $options.whiteClip, 0...20)
                    Toggle("Invert", isOn: $options.invert)
                }

                Section("Laser") {
                    UnitRow("Speed", value: Binding(get: { Double(options.markSpeed) }, set: { options.markSpeed = Int($0) }),
                            range: 1...30000, unit: "mm/min", digits: 0)
                    HStack {
                        Text("Power min").frame(width: 92, alignment: .leading)
                        Slider(value: $minPowerPercent, in: 0...100, step: 1)
                        Text("\(Int(minPowerPercent))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                    HStack {
                        Text("Power max").frame(width: 92, alignment: .leading)
                        Slider(value: $maxPowerPercent, in: 1...100, step: 1)
                        Text("\(Int(maxPowerPercent))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                    Picker("Laser mode", selection: $options.laserOn) {
                        Text("M3 constant power").tag("M3")
                        Text("M4 dynamic power").tag("M4")
                    }
                    Toggle("Machine supports power control (PWM)", isOn: $options.pwm)
                    UnitRow("Laser spot size", value: $spotSize, range: 0.01...2, unit: "mm")
                    .help("Diameter of the burnt spot of your laser; used to suggest a sensible quality")
                    Text(L("S range 0–%d (from $30)", smax)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)
        }
        .frame(maxHeight: .infinity)
        Divider()
        HStack {
            Text(summary).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(working ? L("Working…") : L("Create G-code")) { create() }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(working || source == nil)
        }
        .padding(12)
        }
        .fullSheetFrame()
        .onAppear(perform: load)
        .onChange(of: options.widthMM) { schedulePreview() }
        .onChange(of: options.linesPerMM) { schedulePreview() }
        .onChange(of: options.tool) { schedulePreview() }
        .onChange(of: options.dithering) { schedulePreview() }
        .onChange(of: options.formula) { schedulePreview() }
        .onChange(of: options.red) { schedulePreview() }
        .onChange(of: options.green) { schedulePreview() }
        .onChange(of: options.blue) { schedulePreview() }
        .onChange(of: options.brightness) { schedulePreview() }
        .onChange(of: options.contrast) { schedulePreview() }
        .onChange(of: options.whiteClip) { schedulePreview() }
        .onChange(of: options.invert) { schedulePreview() }
        .onChange(of: options.rotation) { geometryChanged() }
        .onChange(of: options.flipH) { geometryChanged() }
        .onChange(of: options.flipV) { geometryChanged() }
        .onChange(of: options.cropLeft) { geometryChanged() }
        .onChange(of: options.cropTop) { geometryChanged() }
        .onChange(of: options.cropRight) { geometryChanged() }
        .onChange(of: options.cropBottom) { geometryChanged() }
        .onChange(of: minPowerPercent) { _, v in options.minPower = Int(Double(smax) * v / 100) }
        .onChange(of: maxPowerPercent) { _, v in options.maxPower = Int(Double(smax) * v / 100) }
    }

    // MARK: resolution helper

    @ViewBuilder
    private var resolutionHelper: some View {
        let suggestion = ResolutionHelper.suggestedLinesPerMM(spotSize: spotSize)
        HStack(spacing: 6) {
            Text(L("Suggested for a %.2f mm laser spot: %.1f lines/mm", spotSize, suggestion))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Use") { options.linesPerMM = suggestion }.controlSize(.small)
                .disabled(abs(options.linesPerMM - suggestion) < 0.01)
        }
        if ResolutionHelper.linesOverlap(linesPerMM: options.linesPerMM, spotSize: spotSize) {
            Text("Lines closer together than the laser spot overlap and burn the material twice. Use a lower quality for cleaner results.")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: presets

    private func applySelectedPreset() {
        guard let id = selectedPreset, let p = presets.all.first(where: { $0.id == id }) else { return }
        options = p.applied(to: options)
        minPowerPercent = p.minPowerPercent
        maxPowerPercent = p.maxPowerPercent
        options.minPower = Int(Double(smax) * p.minPowerPercent / 100)
        options.maxPower = Int(Double(smax) * p.maxPowerPercent / 100)
        schedulePreview()
    }

    private func savePreset() {
        let alert = NSAlert()
        alert.messageText = L("Save Preset…")
        alert.informativeText = L("Name of the preset")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L("Preset name")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let preset = ImagePreset(name: name, options: options, minPowerPercent: minPowerPercent, maxPowerPercent: maxPowerPercent)
        presets.add(preset)
        selectedPreset = presets.user.first { $0.name == name }?.id
    }

    private func deletePreset() {
        guard let id = selectedPreset else { return }
        presets.remove(id)
        selectedPreset = nil
    }

    // MARK: helpers

    private var summary: String {
        let (w, h) = RasterConverter.pixelSize(options)
        let seconds = ResolutionHelper.engravingSeconds(widthMM: options.widthMM, heightMM: options.heightMM,
                                                         linesPerMM: options.linesPerMM, speed: options.markSpeed)
        return L("%d × %d lines · %.0f × %.0f mm", w, h, options.widthMM, options.heightMM)
            + " · " + L("Engraving time ≈ %@", GCodeProgram.formatDuration(seconds))
    }

    private func slider(_ name: LocalizedStringKey, _ v: Binding<Int>, _ r: ClosedRange<Int>) -> some View {
        HStack {
            Text(name).frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { Double(v.wrappedValue) }, set: { v.wrappedValue = Int($0) }), in: Double(r.lowerBound)...Double(r.upperBound), step: 1)
            Text("\(v.wrappedValue)").monospacedDigit().frame(width: 32, alignment: .trailing)
        }
    }

    /// Crop in percent of the picture's width / height.
    private func cropSlider(_ name: LocalizedStringKey, _ v: Binding<Double>) -> some View {
        HStack {
            Text(name).frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { v.wrappedValue * 100 }, set: { v.wrappedValue = $0 / 100 }), in: 0...45, step: 1)
            Text("\(Int(v.wrappedValue * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
        }
    }

    private func numberField(_ v: Binding<Double>, _ r: ClosedRange<Double>, changed: @escaping (Double) -> Void) -> some View {
        TextField("", value: Binding(get: { v.wrappedValue }, set: { v.wrappedValue = min(r.upperBound, max(r.lowerBound, $0)); changed(v.wrappedValue) }), format: .number)
            .frame(width: 70).textFieldStyle(.roundedBorder)
    }

    /// Cropping, turning or mirroring changes the proportions: keep the width, adjust the height.
    private func geometryChanged() {
        guard let img = source else { return }
        aspect = RasterConverter.aspect(of: img, options)
        if lockAspect { options.heightMM = max(1, (options.widthMM * aspect * 100).rounded() / 100) }
        schedulePreview()
    }

    /// Cuts away the empty border around the subject.
    private func autoCrop() {
        guard let img = source else { return }
        // the crop is measured on the picture as it is; background means transparent or the colour of the picture's edge
        if let c = RasterConverter.subjectCrop(of: img) {
            options.cropLeft = c.left; options.cropTop = c.top; options.cropRight = c.right; options.cropBottom = c.bottom
            cropNote = nil
        } else {
            cropNote = L("No empty border found.")
        }
    }

    private func load() {
        options.maxPower = smax
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            errorText = L("This file could not be read as an image.")
            return
        }
        source = img
        aspect = Double(img.height) / Double(max(1, img.width))
        // default size from the file's DPI when available, else fit 100 mm wide
        var dpi = 96.0
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any], let d = props[kCGImagePropertyDPIWidth] as? Double, d > 1 { dpi = d }
        let natural = Double(img.width) / dpi * 25.4
        options.widthMM = natural >= 5 && natural <= 600 ? (natural * 10).rounded() / 10 : 100
        options.heightMM = (options.widthMM * aspect * 10).rounded() / 10
        schedulePreview()
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard let img = source else { return }
        let o = options
        // preview at most ~700 px so sliders stay responsive
        let (pw, ph) = RasterConverter.pixelSize(o)
        let k = min(1.0, 700.0 / Double(max(pw, ph)))
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            let w = max(1, Int(Double(pw) * k)), h = max(1, Int(Double(ph) * k))
            let result: CGImage? = await Task.detached(priority: .userInitiated) {
                guard let bmp = RasterImage(cgImage: RasterConverter.transformed(img, o), width: w, height: h) else { return nil }
                return RasterConverter.previewBitmap(bmp, o).makeCGImage()
            }.value
            if Task.isCancelled { return }
            if let r = result { previewImage = NSImage(cgImage: r, size: NSSize(width: r.width, height: r.height)) }
        }
    }

    private func create() {
        guard let img = source else { return }
        working = true
        var o = options
        o.minPower = Int(Double(smax) * minPowerPercent / 100)
        o.maxPower = Int(Double(smax) * maxPowerPercent / 100)
        let name = url.deletingPathExtension().lastPathComponent
        let rapid = app.rapidRate
        Task {
            let text: String? = await Task.detached(priority: .userInitiated) {
                RasterConverter.generate(image: img, options: o)
            }.value
            working = false
            guard let t = text else { errorText = L("The image is too large for this quality."); return }
            let program = GCodeProgram(text: t, name: name + ".nc", rapidRate: rapid)
            app.setProgram(program)
            dismiss()
        }
    }
}
