import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LaserGRBLCore

private func numField(_ v: Binding<Double>, _ r: ClosedRange<Double> = 0...100_000, width: CGFloat = 80) -> some View {
    TextField("", value: Binding(get: { v.wrappedValue }, set: { v.wrappedValue = min(r.upperBound, max(r.lowerBound, $0)) }),
              format: .number.grouping(.never).precision(.fractionLength(0...3)))
        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: width)
}

private struct SheetFrame<Content: View>: View {
    let title: LocalizedStringKey
    var width: CGFloat = 560
    @ViewBuilder var content: Content
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2).fontWeight(.semibold)
            content
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: width)
    }
}

// MARK: - test patterns

struct TestPatternsSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    enum Kind: String, CaseIterable, Identifiable { case powerSpeed, cutting, shake, resolution, calibration; var id: String { rawValue } }
    @State private var kind: Kind = .powerSpeed
    @State private var grid = TestPatterns.PowerSpeedGrid()
    @State private var cut = TestPatterns.CuttingGrid()
    @State private var cutSpeedsText = "100, 200, 300, 400, 600"
    @State private var cutPassesText = "1, 2, 3"
    @State private var shake = TestPatterns.Shake()
    @State private var squareSize = 100.0
    @State private var squarePower = 10.0
    @State private var squareSpeed = 1500.0
    @State private var measured = 100.0
    @State private var cleanFeed = 3000.0
    @State private var nominalKerf = 10.0
    @State private var measuredPiece = 9.8
    @State private var pickCol = 0
    @State private var pickRow = 0
    @State private var materialName = ""
    @State private var savedNote: String?

    private var maxS: Double { app.maxS }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test Patterns").font(.title2).fontWeight(.semibold)
            Picker("Test", selection: $kind) {
                Text("Power and speed").tag(Kind.powerSpeed); Text("Cutting test").tag(Kind.cutting); Text("Shake test").tag(Kind.shake)
                Text("Line distance and focus").tag(Kind.resolution); Text("Calibration square").tag(Kind.calibration)
            }
            ScrollView { VStack(alignment: .leading, spacing: 10) { form }.frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 330)
            if let n = savedNote { Text(n).font(.caption).foregroundStyle(.green) }
            HStack {
                Text("The test is a normal job: you confirm the laser safety check when you start it.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create G-code") { create() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 600)
    }

    @ViewBuilder private var form: some View {
        switch kind {
        case .powerSpeed:
            Text("A matrix of squares: speed grows to the right, power grows upwards. Burn it on a scrap of your material and pick the square that looks best.")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: Metrics.group, verticalSpacing: Metrics.related) {
                GridRow { Text(""); Text("from").foregroundStyle(.secondary); Text("to").foregroundStyle(.secondary); Text("steps").foregroundStyle(.secondary) }
                GridRow { Text("Speed (mm/min)"); numField($grid.speedMin, 1...30000); numField($grid.speedMax, 1...30000); Stepper("\(grid.speedSteps)", value: $grid.speedSteps, in: 2...12) }
                GridRow { Text("Power (%)"); numField($grid.powerMin, 0...100); numField($grid.powerMax, 0...100); Stepper("\(grid.powerSteps)", value: $grid.powerSteps, in: 2...12) }
                GridRow { Text("Square size (mm)"); numField($grid.cell, 2...30) }
                GridRow { Text("Gap (mm)"); numField($grid.gap, 0...20) }
                GridRow { Text("Line distance (mm)"); numField($grid.lineSpacing, 0.02...1) }
                GridRow { Text("Passes"); Stepper("\(grid.passes)", value: $grid.passes, in: 1...10) }
            }
            Text(L("Size %.0f × %.0f mm", grid.width, grid.height)).font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Which square was best?").font(.headline)
            HStack {
                Text("Column"); Stepper("\(pickCol + 1)", value: $pickCol, in: 0...(grid.speedSteps - 1))
                Text("Row"); Stepper("\(pickRow + 1)", value: $pickRow, in: 0...(grid.powerSteps - 1))
                Text(L("%.0f mm/min, %.0f %%", grid.speed(column: pickCol), grid.power(row: pickRow))).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Material name", text: $materialName).textFieldStyle(.roundedBorder)
                Button("Save as Material") { saveMaterial(action: .engrave, speed: grid.speed(column: pickCol), power: grid.power(row: pickRow), passes: grid.passes) }
                    .disabled(materialName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .cutting:
            Text("Squares are cut with different speeds (columns) and numbers of passes (rows). The squares that fall out show what cuts through.")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow { Text("Speeds (mm/min)"); TextField("", text: $cutSpeedsText).textFieldStyle(.roundedBorder) }
                GridRow { Text("Passes"); TextField("", text: $cutPassesText).textFieldStyle(.roundedBorder) }
                GridRow { Text("Power (%)"); numField($cut.powerPercent, 1...100) }
                GridRow { Text("Square size (mm)"); numField($cut.size, 2...50) }
            }
            Divider()
            Text("Cut width (kerf)").font(.headline)
            HStack {
                Text("Square cut"); numField($nominalKerf, 1...200); Text("mm, piece measures"); numField($measuredPiece, 0.1...200); Text("mm")
            }
            let k = TestPatterns.kerf(nominal: nominalKerf, measuredPiece: measuredPiece)
            Text(L("The beam removes %.2f mm of material. Move the cutting line outwards by %.2f mm for exact pieces.", k.kerf, k.offset)).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Material name", text: $materialName).textFieldStyle(.roundedBorder)
                Button("Save as Material") {
                    saveMaterial(action: .cut, speed: Double(parseList(cutSpeedsText).first ?? 200), power: cut.powerPercent, passes: parseList(cutPassesText).first.map(Int.init) ?? 1)
                }.disabled(materialName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .shake:
            Text("Short back-and-forth lines at growing feed rates with weak power. If the line turns wavy or jumps at some feed, the machine loses steps there.")
                .font(.callout).foregroundStyle(.secondary)
            HStack { Text("Stroke (mm)"); numField($shake.length, 5...200); Text("Strokes"); Stepper("\(shake.repeats)", value: $shake.repeats, in: 2...50) }
            HStack { Text("Power (%)"); numField($shake.powerPercent, 1...30) }
            Divider()
            Text("Highest feed that still looked clean").font(.headline)
            HStack {
                numField($cleanFeed, 100...30000); Text("mm/min")
                let a = TestPatterns.accelerationEstimate(cleanFeed: cleanFeed, stroke: shake.length)
                Text(L("→ try about %.0f mm/s² for $120 and $121", a)).foregroundStyle(.secondary)
            }
            Text("This is only a starting point. Change the setting, repeat the test and lower it if the machine shakes.").font(.caption).foregroundStyle(.secondary)
        case .resolution:
            Text("Blocks of lines with decreasing distance. The finest block that still shows separate lines is the best line distance for your laser; the narrowest, sharpest line shows good focus.")
                .font(.callout).foregroundStyle(.secondary)
        case .calibration:
            Text("Burns a square. Measure its sides with a ruler or calipers and enter the result: LaserCraft calculates new steps per mm for $100 and $101.")
                .font(.callout).foregroundStyle(.secondary)
            HStack { Text("Size (mm)"); numField($squareSize, 10...400); Text("Speed"); numField($squareSpeed, 100...10000); Text("Power (%)"); numField($squarePower, 1...50) }
            Divider()
            Text("Measured side length").font(.headline)
            HStack { numField($measured, 1...1000); Text("mm") }
            ForEach([(100, "X"), (101, "Y")], id: \.0) { n, axis in
                if let cur = Double(app.controller.settings[n] ?? ""), let new = TestPatterns.stepsPerMM(current: cur, asked: squareSize, measured: measured) {
                    HStack {
                        Text(L("$%d (%@ steps/mm): %.3f → %.3f", n, axis, cur, new))
                        Spacer()
                        Button("Write to the machine") { app.controller.send("$\(n)=\(new)"); app.controller.refreshSettings() }
                            .disabled(!app.controller.isConnected || app.controller.jobRunning || abs(new - cur) < 0.0005)
                    }
                } else {
                    Text(L("$%d: connect to the machine to read the current value.", n)).foregroundStyle(.secondary).font(.caption)
                }
            }
        }
    }

    private func parseList(_ s: String) -> [Double] {
        s.split(whereSeparator: { ",; ".contains($0) }).compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }.filter { $0 > 0 }
    }

    private func machineName() -> String {
        app.activeProfile?.materialMachine.nonEmpty ?? app.activeProfile?.name ?? ""
    }

    private func saveMaterial(action: MaterialAction, speed: Double, power: Double, passes: Int) {
        let m = LaserMaterial(machine: machineName(), name: materialName.trimmingCharacters(in: .whitespaces), action: action,
                              power: power.rounded(), speed: speed.rounded(), passes: passes, notes: L("From a test pattern"))
        app.materials.add(m)
        savedNote = L("Saved “%@” in the material list.", m.title)
    }

    private func create() {
        let lines: [String]
        let dyn = app.dynamicPowerDefault
        switch kind {
        case .powerSpeed: var g = grid; g.dynamicPower = dyn; lines = TestPatterns.powerVsSpeed(g, maxS: maxS)
        case .cutting:
            var c = cut; c.dynamicPower = dyn
            let s = parseList(cutSpeedsText); let p = parseList(cutPassesText).map { Int($0) }
            if !s.isEmpty { c.speeds = s }
            if !p.isEmpty { c.passes = p }
            lines = TestPatterns.cuttingTest(c, maxS: maxS)
        case .shake: var s = shake; s.dynamicPower = dyn; lines = TestPatterns.shakeTest(s, maxS: maxS)
        case .resolution: lines = TestPatterns.resolutionTest(dynamicPower: dyn, maxS: maxS)
        case .calibration: lines = TestPatterns.calibrationSquare(size: squareSize, speed: squareSpeed, powerPercent: squarePower, dynamicPower: dyn, maxS: maxS)
        }
        let name = ["Power and speed test", "Cutting test", "Shake test", "Line distance test", "Calibration square"][Kind.allCases.firstIndex(of: kind)!]
        app.setProgram(GCodeProgram(text: lines.joined(separator: "\n"), name: name + ".nc", rapidRate: app.rapidRate))
        app.mainMode = .job
        dismiss()
    }
}

extension String { var nonEmpty: String? { isEmpty ? nil : self } }

// MARK: - materials

struct MaterialsSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var machine = UserDefaults.standard.string(forKey: "materialMachine") ?? ""
    @State private var search = ""
    @State private var selection: String?
    @State private var editing: LaserMaterial?
    @State private var tick = 0

    var body: some View {
        let list = app.materials.materials(machine: machine, search: search)
        VStack(alignment: .leading, spacing: 10) {
            Text("Materials").font(.title2).fontWeight(.semibold)
            HStack {
                Picker("Machine", selection: $machine) {
                    Text("All machines").tag("")
                    ForEach(app.materials.machines, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: machine) { UserDefaults.standard.set(machine, forKey: "materialMachine") }
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            Table(Array(list.prefix(400)), selection: $selection) {
                TableColumn("Material") { m in Text(m.title + (m.builtin ? "" : " ★")) }
                TableColumn("Action") { m in Text(m.action == .cut ? L("Cut") : L("Engrave")) }.width(70)
                TableColumn("Speed") { m in Text("\(Int(m.speed))") }.width(56)
                TableColumn("Power") { m in Text("\(Int(m.power)) %") }.width(56)
                TableColumn("Passes") { m in Text("\(m.passes)") }.width(50)
                TableColumn("Machine") { m in Text(m.machine).foregroundStyle(.secondary) }
            }
            .frame(height: 280)
            if let m = list.first(where: { $0.id == selection }), !m.notes.isEmpty {
                Text(m.notes).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack {
                Button("New Material…") { editing = LaserMaterial(machine: machine, name: "") }
                Button("Edit") { editing = list.first { $0.id == selection } }
                    .disabled(list.first { $0.id == selection }.map { $0.builtin } ?? true)
                Button("Duplicate") {
                    if var m = list.first(where: { $0.id == selection }) { m.id = UUID().uuidString; m.builtin = false; m.name += " copy"; app.materials.add(m); tick += 1 }
                }.disabled(selection == nil)
                Button("Delete Button") { if let id = selection { app.materials.remove(id: id); selection = nil; tick += 1 } }
                    .disabled(list.first { $0.id == selection }.map { $0.builtin } ?? true)
                Spacer()
                Button("Import…") { importMaterials() }
                Button("Export…") { exportMaterials() }.disabled(app.materials.custom.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Entries marked ★ are your own. The built-in list comes from LaserGRBL and is only a starting point: test on a scrap first.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 760)
        .id(tick)
        .sheet(item: $editing) { m in MaterialEditor(material: m) { app.materials.add($0); tick += 1 } }
    }

    private func importMaterials() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let n = try app.materials.importMaterials(Data(contentsOf: url)); app.presentInfo(title: L("Materials"), message: L("%d materials imported.", n)); tick += 1 }
        catch { app.alertMessage = L("Could not read the file: %@", error.localizedDescription) }
    }

    private func exportMaterials() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LaserCraft-materials.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try app.materials.exportCustom().write(to: url) } catch { app.alertMessage = L("Could not save: %@", error.localizedDescription) }
    }
}

private struct MaterialEditor: View {
    @State var material: LaserMaterial
    var onSave: (LaserMaterial) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Material").font(.title3).fontWeight(.semibold)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { Text("Name"); TextField("", text: $material.name).textFieldStyle(.roundedBorder) }
                GridRow { Text("Thickness (mm)"); TextField("", text: $material.thickness).textFieldStyle(.roundedBorder) }
                GridRow { Text("Machine"); TextField("", text: $material.machine).textFieldStyle(.roundedBorder) }
                GridRow {
                    Text("Action")
                    Picker("", selection: $material.action) { Text("Engrave").tag(MaterialAction.engrave); Text("Cut").tag(MaterialAction.cut) }
                        .pickerStyle(.segmented).labelsHidden()
                }
                GridRow { Text("Speed (mm/min)"); numField($material.speed, 1...30000) }
                GridRow { Text("Power (%)"); numField($material.power, 0...100) }
                GridRow { Text("Passes"); Stepper("\(material.passes)", value: $material.passes, in: 1...50) }
                GridRow { Text("Notes"); TextField("", text: $material.notes, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(material); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(material.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 440)
    }
}

// MARK: - machine profiles

struct ProfilesSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var selection: String?
    @State private var tick = 0

    private var profile: MachineProfile? { app.profiles.profile(id: selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.group) {
            Text("Machine Profiles").font(.title2).fontWeight(.semibold)
            HStack(alignment: .top, spacing: Metrics.dialog) {
                VStack(alignment: .leading, spacing: Metrics.related) {
                    List(app.profiles.profiles, selection: $selection) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            if p.id == app.activeProfileID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Active") }
                        }.tag(p.id)
                    }
                    .frame(width: 200)
                    HStack(spacing: Metrics.related) {
                        Button { var p = MachineProfile(name: L("New Laser")); p.connection = app.selectedPort == AppModel.simulatorPort ? "" : app.selectedPort
                            p.baud = app.baud; p.header = app.controller.jobSettings.header; p.footer = app.controller.jobSettings.footer
                            app.profiles.upsert(p); selection = p.id; tick += 1 } label: { IconLabel("Add", icon: "plus", size: 12) }
                            .labelStyle(.iconOnly).help("Add")
                        Button { if let id = selection { app.profiles.delete(id: id); if app.activeProfileID == id { app.activeProfileID = nil }; selection = nil; tick += 1 } } label: { IconLabel("Delete Button", icon: "trash", size: 12) }
                            .labelStyle(.iconOnly).help("Delete Button")
                            .disabled(selection == nil)
                    }
                }
                Divider()
                if let p = profile {
                    ProfileForm(profile: p) { app.profiles.upsert($0); tick += 1 }
                        .id(p.id)
                } else {
                    Text("A profile stores baud rate, header and footer, rapid speed and laser data for one machine and is loaded when you connect to its port or address.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(Metrics.dialog)
        .frame(width: 700, height: 600, alignment: .topLeading)
        .id(tick)
        .onAppear { selection = app.activeProfileID ?? app.profiles.profiles.first?.id }
    }
}

private struct ProfileForm: View {
    @State var profile: MachineProfile
    var onChange: (MachineProfile) -> Void
    @EnvironmentObject var app: AppModel

    private func row<C: View>(_ title: LocalizedStringKey, top: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: top ? .top : .center, spacing: Metrics.related) {
            Text(title).frame(width: 130, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func editor(_ text: Binding<String>, mono: Bool = false, height: CGFloat = 52) -> some View {
        TextEditor(text: text).font(mono ? .system(size: 11, design: .monospaced) : .body)
            .frame(height: height).border(Color.gray.opacity(0.3))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.related) {
                row("Name") { TextField("", text: $profile.name).textFieldStyle(.roundedBorder) }
                row("Port or address") {
                    Picker("", selection: $profile.connection) {
                        Text("None").tag("")
                        ForEach(app.ports.filter { $0 != AppModel.simulatorPort }, id: \.self) { Text(app.portName($0)).tag($0) }
                        if !profile.connection.isEmpty && !app.ports.contains(profile.connection) { Text(profile.connection).tag(profile.connection) }
                    }.labelsHidden()
                }
                row("Baud rate") {
                    Picker("", selection: $profile.baud) { ForEach(AppModel.bauds, id: \.self) { Text(verbatim: String($0)).tag($0) } }.labelsHidden()
                }
                row("Rapid speed") { HStack(spacing: Metrics.related) { NumberInput(value: $profile.rapidRate, range: 100...30000, digits: 0); unit("mm/min") } }
                row("Laser spot size") { HStack(spacing: Metrics.related) { NumberInput(value: $profile.spotSize, range: 0.01...2); unit("mm") } }
                row("Laser power") { HStack(spacing: Metrics.related) { NumberInput(value: $profile.laserWatts, range: 0...500); unit("W") } }
                row("Rated life") { HStack(spacing: Metrics.related) { NumberInput(value: $profile.ratedHours, range: 0...100_000, digits: 0); unit("h") } }
                row("Materials for") {
                    Picker("", selection: $profile.materialMachine) {
                        Text("None").tag("")
                        ForEach(app.materials.machines, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                row("Header", top: true) { editor($profile.header, mono: true) }
                row("Footer", top: true) { editor($profile.footer, mono: true) }
                row("Notes", top: true) { editor($profile.notes, height: 44) }
                HStack {
                    Button("Use This Profile Now") {
                        app.activeProfileID = profile.id
                        app.applyProfile(forConnection: profile.connection.isEmpty ? "\u{0}" : profile.connection)
                        if profile.connection.isEmpty {
                            app.baud = profile.baud; app.controller.jobSettings.header = profile.header; app.controller.jobSettings.footer = profile.footer
                            app.saveJobSettings()
                        }
                    }
                    Spacer()
                }.padding(.top, Metrics.related)
            }
            .onChange(of: profile) { _, new in onChange(new) }
            .padding(.trailing, Metrics.related)
        }
    }

    private func unit(_ s: String) -> some View {
        Text(verbatim: s).font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - statistics

struct StatisticsSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var selection: String?
    @State private var tick = 0

    var body: some View {
        let profiles = app.profiles.profiles
        let p = app.profiles.profile(id: selection) ?? profiles.first
        VStack(alignment: .leading, spacing: 12) {
            Text("Laser Statistics").font(.title2).fontWeight(.semibold)
            if profiles.isEmpty {
                Text("Statistics are counted per laser. Finish a job on a connected machine, or add a profile in Machine Profiles.").foregroundStyle(.secondary)
            }
            if let p = p {
                Picker("Laser", selection: Binding(get: { p.id }, set: { selection = $0 })) { ForEach(profiles) { Text($0.name).tag($0.id) } }
                let s = app.profiles.summary(for: p)
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    GridRow { Text("Jobs"); Text("\(s.jobs) (\(s.finished) finished)") }
                    GridRow { Text("Running time"); Text(String(format: "%.1f h", s.totalHours)) }
                    GridRow { Text("Laser on"); Text(String(format: "%.1f h", s.laserHours)) }
                    GridRow { Text("Laser life used"); Text(String(format: "%.1f h of %.0f h at full power (%.0f %%)", s.fullPowerHours, p.ratedHours, s.lifeUsed * 100)) }
                    GridRow { Text("Remaining"); Text(String(format: "%.0f h", s.remainingHours)) }
                }
                ProgressView(value: min(1, s.lifeUsed)).tint(s.lifeUsed > 0.9 ? .red : .accentColor)
                Text("“Laser on” counts only the time the laser burns; the life used is weighted with the power, so 1 hour at half power counts as half an hour. Times are estimates from the G-code.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Recent jobs").font(.headline)
                Table(app.profiles.history(profileID: p.id, limit: 40)) {
                    TableColumn("Date") { e in Text(e.date.formatted(date: .abbreviated, time: .shortened)) }.width(130)
                    TableColumn("Job") { e in Text(e.job) }
                    TableColumn("Time") { e in Text(GCodeProgram.formatDuration(e.seconds)) }.width(70)
                    TableColumn("Result") { e in Text(e.outcome == .finished ? L("Finished") : e.outcome == .stopped ? L("Stopped") : L("Failed")) }.width(70)
                }
                .frame(height: 170)
                HStack {
                    Button("Laser Replaced") { app.profiles.laserReplaced(id: p.id); tick += 1 }
                        .help("Start counting from zero for a new laser or a new module")
                    Button("Clear History…") { app.profiles.clearUsage(profileID: p.id); tick += 1 }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            } else {
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .padding(20).frame(width: 600)
        .id(tick)
    }
}

// MARK: - network machines

struct NetworkSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var kind: NetworkKind = .telnet
    @State private var host = ""
    @State private var portText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Network Machines").font(.title2).fontWeight(.semibold)
            Text("Connect to a controller over WiFi or Ethernet: FluidNC and Grbl_ESP32 (Telnet), ESP8266 add-ons such as Ortur WiFi (WebSocket, port 81) or a serial-to-network bridge (TCP).")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Type", selection: $kind) {
                Text("Telnet (FluidNC, Grbl_ESP32)").tag(NetworkKind.telnet)
                Text("WebSocket (ESP8266, Ortur WiFi)").tag(NetworkKind.webSocket)
                Text("TCP (bridge)").tag(NetworkKind.tcp)
            }
            HStack {
                TextField("Address, for example 192.168.1.50 or fluidnc.local", text: $host).textFieldStyle(.roundedBorder)
                TextField(String(kind.defaultPort), text: $portText).textFieldStyle(.roundedBorder).frame(width: 70)
            }
            if !app.discovered.isEmpty {
                Text("Found on this network").font(.headline)
                ForEach(app.discovered, id: \.self) { f in
                    HStack {
                        Text(f.name); Text(f.address.url).foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Button("Use") { app.addNetworkMachine(f.address); dismiss() }
                    }
                }
            }
            if !app.networkMachines.isEmpty {
                Text("Saved").font(.headline)
                ForEach(app.networkMachines, id: \.self) { u in
                    HStack {
                        Text(u)
                        Spacer()
                        Button("Delete Button") { app.forgetNetworkMachine(u) }
                    }
                }
            }
            Text("After adding, select the machine in the port list and press Connect. macOS asks once for permission to use the local network.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Search Network") { app.startDiscovery() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let h = host.trimmingCharacters(in: .whitespaces)
                    guard !h.isEmpty else { return }
                    app.addNetworkMachine(NetworkAddress(kind: kind, host: h, port: Int(portText)))
                    dismiss()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { app.startDiscovery() }
        .onDisappear { app.discovery.stop() }
    }
}
