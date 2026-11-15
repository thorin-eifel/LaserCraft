import SwiftUI
import UniformTypeIdentifiers
import LaserGRBLCore

/// Grbl "$" settings table with descriptions, editing, export and import.
struct GrblConfigView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var controller: GrblController
    @Environment(\.dismiss) var dismiss
    @State private var edits: [Int: String] = [:]

    private var keys: [Int] { controller.settings.keys.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Grbl configuration").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("Read Again") { edits.removeAll(); controller.refreshSettings() }
            }
            Text("Change a value and press Return to write it to the machine. Wrong values can make the machine behave unexpectedly.")
                .font(.callout).foregroundStyle(.secondary)
            Table(keys.map { Row(id: $0) }) {
                TableColumn("$") { r in Text("$\(r.id)").monospacedDigit() }.width(40)
                TableColumn("Setting") { r in Text(GrblParser.describeSetting(r.id)?.name ?? "—") }.width(min: 150, ideal: 190)
                TableColumn("Value") { r in
                    TextField("Value", text: Binding(
                        get: { edits[r.id] ?? controller.settings[r.id] ?? "" },
                        set: { edits[r.id] = $0 }))
                    .labelsHidden()
                    .onSubmit { write(r.id) }
                }.width(90)
                TableColumn("Units") { r in Text(GrblParser.describeSetting(r.id)?.units ?? "").foregroundStyle(.secondary) }.width(90)
                TableColumn("Description") { r in
                    let d = GrblParser.describeSetting(r.id)?.detail ?? ""
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(d)
                }
            }
            .frame(minHeight: 340)
            HStack {
                Button("Export…") { exportSettings() }
                Button("Import…") { importSettings() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 880, height: 540)
    }

    struct Row: Identifiable { let id: Int }

    private func write(_ n: Int) {
        guard let v = edits[n]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return }
        controller.send("$\(n)=\(v)")
        edits[n] = nil
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "grbl-settings.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = keys.map { "$\($0)=\(controller.settings[$0] ?? "")" }.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("$") && $0.contains("=") }
        let a = NSAlert()
        a.messageText = L("Write %d settings to the machine?", lines.count)
        a.informativeText = L("This replaces the current Grbl configuration.")
        a.addButton(withTitle: L("Write")); a.addButton(withTitle: L("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        lines.forEach { controller.send($0) }
        controller.refreshSettings()
    }
}

// MARK: - Settings window (⌘,)

struct SettingsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label { Text("General") } icon: { UIcon(name: "settings", size: 16) } }
            ConnectionSettings()
                .tabItem { Label { Text("Connection") } icon: { UIcon(name: "plug", size: 16) } }
            JobSettingsTab(controller: app.controller)
                .tabItem { Label { Text("Job") } icon: { UIcon(name: "play", size: 16) } }
            PreviewSettings()
                .tabItem { Label { Text("Preview") } icon: { UIcon(name: "image", size: 16) } }
            ButtonSettings()
                .tabItem { Label { Text("Buttons") } icon: { UIcon(name: "list", size: 16) } }
        }
        .frame(width: 560, height: 560)
    }
}

/// Language, light / dark appearance, notifications and safety.
struct AppearanceSettings: View {
    @EnvironmentObject var app: AppModel
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage("soundOnFinish") private var playSounds = true
    @AppStorage("notifyOnFinish") private var notifyOnFinish = true
    @AppStorage("soundVolume") private var soundVolume = 0.7
    @AppStorage("alertOnError") private var alertOnError = true
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck = true
    @State private var languageChanged = false
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { app.applyAppearance() }
            } header: { Text("Appearance") } footer: {
                Text("“System” follows the setting in System Settings.")
            }

            Section {
                Picker("Language", selection: $language) {
                    Text("System").tag("system")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Deutsch").tag("de")
                    Text(verbatim: "Français").tag("fr")
                    Text(verbatim: "Español").tag("es")
                    Text(verbatim: "Italiano").tag("it")
                    Text(verbatim: "Português (Brasil)").tag("pt-BR")
                }
                .onChange(of: language) { app.setLanguage(language); languageChanged = true }
                if languageChanged {
                    LabeledContent {
                        Button("Restart Now") { app.relaunch() }
                    } label: {
                        Text("The new language is used after a restart.").foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Language") }

            Section {
                Toggle("Play sounds", isOn: $playSounds)
                LabeledContent("Volume") {
                    HStack(spacing: 8) {
                        Slider(value: $soundVolume, in: 0.1...1).frame(width: 150)
                        Button("Play Test Sound") { Sounds.play(.finished, force: true) }
                    }
                }
                .disabled(!playSounds)
                Toggle("Show a notification when a job ends", isOn: $notifyOnFinish)
                Toggle("Show an alert when something goes wrong", isOn: $alertOnError)
            } header: { Text("Sounds and Alerts") } footer: {
                Text("The laser safety check before every start cannot be turned off.")
            }

            Section {
                Toggle("Check for updates automatically", isOn: $autoUpdateCheck)
                HStack { Spacer(); Button("Check for Updates…") { app.checkForUpdates(silent: false) } }
            } header: { Text("Updates") } footer: {
                Text("LaserCraft only looks for a newer version on GitHub; it never installs anything by itself.")
            }

            Section {
                Button("Restore Default Settings", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(L("Restore all settings to their defaults?"), isPresented: $confirmReset) {
            Button("Restore Default Settings", role: .destructive) {
                app.resetPreferences()
                appearance = "system"; language = "system"; playSounds = true; soundVolume = 0.7; notifyOnFinish = true; alertOnError = true
                languageChanged = true
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct ConnectionSettings: View {
    @EnvironmentObject var app: AppModel
    @AppStorage("autoConnect") private var autoConnect = false
    @AppStorage("showSimulator") private var showSimulator = true
    @AppStorage("autoReconnect") private var autoReconnect = true

    var body: some View {
        Form {
            Section {
                Picker("Baud rate", selection: $app.baud) {
                    ForEach(AppModel.bauds, id: \.self) { Text(verbatim: String($0)).tag($0) }
                }
                Toggle("Connect automatically at launch", isOn: $autoConnect)
                Toggle("Reconnect automatically if the USB connection drops", isOn: $autoReconnect)
                Toggle("Show the simulator (demo machine) in the port list", isOn: $showSimulator)
                    .onChange(of: showSimulator) { app.refreshPorts() }
            } header: { Text("Connection") } footer: {
                Text("Most Grbl controllers use 115200 baud. Automatic connection uses the port selected in the main window.")
            }
            Section {
                UnitRow("Jog speed", value: $app.jogFeed, range: 1...30000, unit: "mm/min", digits: 0)
                Picker("Jog step", selection: $app.jogStep) {
                    ForEach([0.1, 0.5, 1, 5, 10, 50, 100], id: \.self) { Text(L("%@ mm", $0.formatted())).tag($0) }
                }
            } header: { Text("Jogging") }
        }
        .formStyle(.grouped)
    }
}

struct JobSettingsTab: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var controller: GrblController
    @AppStorage("rapidRate") private var rapidRate = 2000.0
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("keepDisplayOn") private var keepDisplayOn = false
    @AppStorage("coolingEnabled") private var coolingEnabled = false
    @AppStorage("coolRunMinutes") private var coolRunMinutes = 5
    @AppStorage("coolPauseMinutes") private var coolPauseMinutes = 1

    var body: some View {
        Form {
            Section {
                TextEditor(text: $controller.jobSettings.header)
                    .font(.system(.body, design: .monospaced)).frame(height: 56)
                    .onChange(of: controller.jobSettings.header) { app.saveJobSettings() }
            } header: { Text("Header (sent before the job)") }
            Section {
                TextEditor(text: $controller.jobSettings.footer)
                    .font(.system(.body, design: .monospaced)).frame(height: 56)
                    .onChange(of: controller.jobSettings.footer) { app.saveJobSettings() }
            } header: { Text("Footer (sent after the job)") }
            Section {
                Stepper(L("Passes: %d", controller.jobSettings.passes), value: $controller.jobSettings.passes, in: 1...50)
                LabeledContent("Frame power") {
                    HStack(spacing: 6) {
                        Slider(value: $app.framePower, in: 0...30, step: 1).frame(width: 150)
                        Text("\(Int(app.framePower))").monospacedDigit().frame(width: 24, alignment: .trailing)
                    }
                }
                .help("0 = trace the outline with the laser off; a low value lets you see it")
                UnitRow("Rapid speed for time estimates", value: $rapidRate, range: 1...30000, unit: "mm/min", digits: 0)
                .help("Used when the machine's $110 setting is not known yet")
            } footer: {
                Text("Header and footer are also written when you save G-code.")
            }
            Section {
                Toggle("Pause regularly to let the laser cool down", isOn: $coolingEnabled)
                    .onChange(of: coolingEnabled) { app.applyCoolingPrefs() }
                Stepper(L("Work for %d minutes", coolRunMinutes), value: $coolRunMinutes, in: 1...120)
                    .disabled(!coolingEnabled).onChange(of: coolRunMinutes) { app.applyCoolingPrefs() }
                Stepper(L("then rest for %d minutes", coolPauseMinutes), value: $coolPauseMinutes, in: 1...30)
                    .disabled(!coolingEnabled).onChange(of: coolPauseMinutes) { app.applyCoolingPrefs() }
            } header: { Text("Cooling") } footer: {
                Text("Long engravings with a diode laser can overheat it. The job is paused (laser off) and continues by itself afterwards.")
            }
            Section {
                Toggle("Keep the Mac awake while a job is running", isOn: $keepAwake)
                Toggle("Also keep the display on", isOn: $keepDisplayOn).disabled(!keepAwake)
            } header: { Text("Power") } footer: {
                Text("The Mac can sleep before and after a job. A MacBook still sleeps when its lid is closed; the job is then paused.")
            }
        }
        .formStyle(.grouped)
    }
}

struct PreviewSettings: View {
    @AppStorage("previewShowTravel") private var showTravel = true
    @AppStorage("previewShowGrid") private var showGrid = true
    @AppStorage("previewFollowsAppearance") private var followsAppearance = false

    var body: some View {
        Form {
            Section {
                Toggle("Show travel moves", isOn: $showTravel)
                Toggle("Show grid lines", isOn: $showGrid)
                Toggle("Use a dark sheet in Dark appearance", isOn: $followsAppearance)
            } header: { Text("Preview") } footer: {
                Text("By default the preview is a white sheet, like the material it shows.")
            }
        }
        .formStyle(.grouped)
    }
}

struct ButtonSettings: View {
    @EnvironmentObject var app: AppModel
    @State private var buttonToDelete: CustomButton?
    @State private var confirmRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each button sends its G-code lines to the machine. Turn on “Ask first” for anything risky.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach($app.customButtons) { $b in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Name", text: Binding(get: { b.displayTitle }, set: { b.title = $0; b.titleKey = nil })).frame(width: 190)
                            Picker("Icon", selection: Binding(get: { b.icon ?? "" }, set: { b.icon = $0.isEmpty ? nil : $0 })) {
                                Text("None").tag("")
                                ForEach(["home", "unlock", "lock", "target", "fit", "play", "pause", "stop", "refresh", "settings", "up", "down", "left", "right", "plus"], id: \.self) { n in
                                    UIcon(name: n, size: 14).tag(n)
                                }
                            }
                            .frame(width: 130)
                            Toggle("Ask first", isOn: $b.confirm)
                            Spacer()
                            Button(role: .destructive) { buttonToDelete = b } label: {
                                IconLabel("Delete Button", icon: "trash", size: 13)
                            }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                        TextEditor(text: $b.gcode).font(.system(.body, design: .monospaced)).frame(height: 44)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    }
                    .padding(.vertical, 3)
                }
            }
            HStack {
                Button { app.customButtons.append(CustomButton(title: L("New button"), gcode: "")) } label: {
                    IconLabel("Add Button", icon: "plus", size: 12)
                }
                Button("Restore Defaults") { confirmRestore = true }
                Spacer()
            }
        }
        .padding(16)
        .confirmationDialog(L("Delete this button?"), isPresented: Binding(get: { buttonToDelete != nil }, set: { if !$0 { buttonToDelete = nil } }), presenting: buttonToDelete) { b in
            Button("Delete Button", role: .destructive) { app.customButtons.removeAll { $0.id == b.id } }
            Button("Cancel", role: .cancel) {}
        } message: { b in Text(b.displayTitle) }
        .confirmationDialog(L("Replace all buttons with the defaults?"), isPresented: $confirmRestore) {
            Button("Restore Defaults", role: .destructive) { app.customButtons = AppModel.defaultButtons() }
            Button("Cancel", role: .cancel) {}
        }
    }
}
