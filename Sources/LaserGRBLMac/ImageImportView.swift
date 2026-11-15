import SwiftUI
import AppKit
import LaserGRBLCore

/// Image import window: pick size and quality, tune the picture, preview, then build the engraving G-code.
struct ImageImportView: View {
    let url: URL
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss

    @State private var source: CGImage?
    @State private var options = RasterOptions()
    @State private var lockAspect = true
    @State private var previewImage: NSImage?
    @State private var working = false
    @State private var errorText: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var maxPowerPercent = 100.0
    @State private var minPowerPercent = 0.0

    private var aspect: Double {
        guard let s = source else { return 1 }
        return Double(s.height) / Double(s.width)
    }

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
                .frame(minWidth: 380, minHeight: 380)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.4)))
            }
            .padding(12)

            Form {
                Section("Size and position") {
                    HStack {
                        Text("Width"); numberField($options.widthMM, 1...2000) { w in
                            if lockAspect { options.heightMM = (w * aspect * 100).rounded() / 100 }
                        }; Text("mm")
                    }
                    HStack {
                        Text("Height"); numberField($options.heightMM, 1...2000) { h in
                            if lockAspect { options.widthMM = (h / aspect * 100).rounded() / 100 }
                        }; Text("mm")
                        Toggle("Lock", isOn: $lockAspect).toggleStyle(.checkbox)
                    }
                    HStack {
                        Text("Offset X"); numberField($options.offsetX, -5000...5000) { _ in }
                        Text("Y"); numberField($options.offsetY, -5000...5000) { _ in }
                    }
                }

                Section("Conversion") {
                    Picker("Tool", selection: $options.tool) {
                        ForEach(RasterTool.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }
                    Picker("Direction", selection: $options.direction) {
                        ForEach(FillDirection.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }
                    Toggle("Engrave in one direction only", isOn: $options.unidirectional)
                    HStack {
                        Text("Quality")
                        Stepper(value: $options.linesPerMM, in: 0.5...20, step: 0.5) {
                            Text(L("%.1f lines/mm", options.linesPerMM)).monospacedDigit()
                        }
                    }
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
                    HStack {
                        Text("Speed"); TextField("", value: $options.markSpeed, format: .number).frame(width: 70)
                        Text("mm/min")
                    }
                    HStack {
                        Text("Power min"); Text("\(Int(minPowerPercent))%").frame(width: 38)
                        Slider(value: $minPowerPercent, in: 0...100, step: 1)
                    }
                    HStack {
                        Text("Power max"); Text("\(Int(maxPowerPercent))%").frame(width: 38)
                        Slider(value: $maxPowerPercent, in: 1...100, step: 1)
                    }
                    Picker("Laser mode", selection: $options.laserOn) {
                        Text("M3 constant power").tag("M3")
                        Text("M4 dynamic power").tag("M4")
                    }
                    Toggle("Machine supports power control (PWM)", isOn: $options.pwm)
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
        .frame(minWidth: 820, minHeight: 640)
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
        .onChange(of: minPowerPercent) { _, v in options.minPower = Int(Double(smax) * v / 100) }
        .onChange(of: maxPowerPercent) { _, v in options.maxPower = Int(Double(smax) * v / 100) }
    }

    // MARK: helpers

    private var summary: String {
        let (w, h) = RasterConverter.pixelSize(options)
        return L("%d × %d lines · %.0f × %.0f mm", w, h, options.widthMM, options.heightMM)
    }

    private func slider(_ name: LocalizedStringKey, _ v: Binding<Int>, _ r: ClosedRange<Int>) -> some View {
        HStack {
            Text(name).frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { Double(v.wrappedValue) }, set: { v.wrappedValue = Int($0) }), in: Double(r.lowerBound)...Double(r.upperBound), step: 1)
            Text("\(v.wrappedValue)").monospacedDigit().frame(width: 32, alignment: .trailing)
        }
    }

    private func numberField(_ v: Binding<Double>, _ r: ClosedRange<Double>, changed: @escaping (Double) -> Void) -> some View {
        TextField("", value: Binding(get: { v.wrappedValue }, set: { v.wrappedValue = min(r.upperBound, max(r.lowerBound, $0)); changed(v.wrappedValue) }), format: .number)
            .frame(width: 70).textFieldStyle(.roundedBorder)
    }

    private func load() {
        options.maxPower = smax
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            errorText = L("This file could not be read as an image.")
            return
        }
        source = img
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
        var o = options
        // preview at most ~700 px so sliders stay responsive
        let (pw, ph) = RasterConverter.pixelSize(o)
        let k = min(1.0, 700.0 / Double(max(pw, ph)))
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            let w = max(1, Int(Double(pw) * k)), h = max(1, Int(Double(ph) * k))
            o.widthMM = o.widthMM
            let result: CGImage? = await Task.detached(priority: .userInitiated) {
                guard let bmp = RasterImage(cgImage: img, width: w, height: h) else { return nil }
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
