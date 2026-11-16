import SwiftUI
import AppKit
import LaserGRBLCore

// MARK: - keyboard settings

struct KeyboardSettings: View {
    @EnvironmentObject var app: AppModel
    @AppStorage("continuousJog") private var continuousJog = false
    @StateObject private var recorder = HotkeyRecorder()
    @State private var recordingFor: HotkeyAction?
    @State private var conflict: (action: HotkeyAction, other: HotkeyAction, combo: KeyCombo)?

    private func title(_ a: HotkeyAction) -> String {
        if let i = a.buttonIndex { return L("Custom button %d", i + 1) }
        return L(a.title)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Hold a key or pad button to keep moving", isOn: $continuousJog)
            } header: { Text("Jogging") } footer: {
                Text("Moves while the key is held and stops when it is released. Needs Grbl 1.1; the big steps (⌥) always move one step.")
            }
            Section {
                ForEach(HotkeyAction.allCases, id: \.self) { a in
                    HStack {
                        Text(title(a))
                        Spacer()
                        Button {
                            if recordingFor == a { recorder.stop(); recordingFor = nil } else { begin(a) }
                        } label: {
                            Text(recordingFor == a ? L("Press a key…") : (app.hotkeys.combo(for: a)?.display ?? "–"))
                                .frame(minWidth: 84)
                                .monospacedDigit()
                        }
                        .help("Click, then press the new shortcut. Esc cancels, ⌫ clears it.")
                    }
                }
            } header: { Text("Keyboard Shortcuts") } footer: {
                Text("Shortcuts work only when the main window is active and no text field is being edited.")
            }
            if let c = conflict {
                Section {
                    HStack {
                        Text(L("%@ is already used for “%@”.", c.combo.display, title(c.other)))
                        Spacer()
                        Button("Replace") { app.hotkeys.set(c.combo, for: c.action, steal: true); app.saveHotkeys(); conflict = nil }
                        Button("Cancel") { conflict = nil }
                    }
                }
            }
            Section {
                HStack { Spacer(); Button("Restore Default Shortcuts") { app.hotkeys.reset(); app.saveHotkeys(); conflict = nil } }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .onDisappear { recorder.stop() }
    }

    private func begin(_ a: HotkeyAction) {
        conflict = nil
        recordingFor = a
        recorder.onCombo = { combo in
            recordingFor = nil
            guard let combo = combo else { app.hotkeys.set(nil, for: a); app.saveHotkeys(); return }
            if let other = app.hotkeys.set(combo, for: a) { conflict = (a, other, combo) } else { app.saveHotkeys() }
        }
        recorder.start()
    }
}

// MARK: - remote notification (in General settings)

struct RemoteNotificationSection: View {
    @EnvironmentObject var app: AppModel
    @AppStorage("remoteEnabled") private var enabled = false
    @AppStorage("remoteURL") private var address = ""
    @AppStorage("remoteMinMinutes") private var minMinutes = 10.0
    @AppStorage("remoteIncludeName") private var includeName = false

    var body: some View {
        Section {
            Toggle("Send a push message when a job ends", isOn: $enabled)
            if enabled {
                ControlRow("Address") {
                    TextField("Address", text: $address, prompt: Text("ntfy://my-laser or https://…")).labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(width: 270)
                }
                UnitRow("Only for jobs longer than", value: $minMinutes, range: 0...600, unit: L("minutes"), digits: 0)
                Toggle("Include the file name", isOn: $includeName)
                HStack { Spacer(); Button("Send Test Message") { app.sendRemoteTest() }.disabled(address.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        } header: { Text("Remote Notification") } footer: {
            Text("A message to your iPhone through ntfy.sh (install the ntfy app and choose a secret topic name) or to any webhook that accepts JSON. The file name is only sent when you switch it on.")
        }
    }
}

// MARK: - console filter

struct ConsoleFilterBar: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var controller: GrblController

    var body: some View {
        HStack(spacing: Metrics.related) {
            Menu {
                Toggle("Sent", isOn: $app.consoleFilter.sent)
                Toggle("Received", isOn: $app.consoleFilter.received)
                Toggle("Messages", isOn: $app.consoleFilter.info)
                Toggle("Errors", isOn: $app.consoleFilter.errors)
                Divider()
                Button("Show All") { var f = ConsoleFilter(); f.search = app.consoleFilter.search; app.consoleFilter = f }
                Button("Errors Only") { var f = ConsoleFilter(); f.sent = false; f.received = false; f.info = false; f.search = app.consoleFilter.search; app.consoleFilter = f }
                Divider()
                Toggle("Show Timestamps", isOn: $app.consoleTimestamps)
                Toggle("Auto-Scroll", isOn: $app.consoleAutoScroll)
            } label: {
                Label { Text("Filter") } icon: { Image(systemName: app.consoleFilter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
            }
            .menuStyle(.borderlessButton).fixedSize()
            TextField("Search", text: $app.consoleFilter.search).textFieldStyle(.roundedBorder).controlSize(.small)
            Button { app.saveConsoleLog() } label: { IconLabel("Save Console Log…", icon: "save", size: 12) }
                .help("Save the console as a text file")
            Button { controller.clearConsole() } label: { IconLabel("Clear Console", icon: "trash", size: 12) }
                .help("Clear the console")
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless)
        .padding(.horizontal, 6).padding(.top, 6)
    }
}

// MARK: - emergency stop

struct EmergencyStopButton: View {
    @ObservedObject var controller: GrblController

    var body: some View {
        Button { controller.emergencyStop() } label: {
            Label { Text("Emergency Stop") } icon: { Image(systemName: "exclamationmark.octagon.fill") }
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .disabled(!controller.isConnected)
        .help("Stop at once and switch the laser off, whatever the machine is doing (⌥⌘.)")
        .accessibilityLabel(Text("Emergency Stop"))
    }
}

// MARK: - jog pad button (single step, or continuous while held)

struct JogHoldButton<Label: View>: View {
    @EnvironmentObject var app: AppModel
    let direction: JogDirection
    let step: () -> Void
    @ViewBuilder var label: Label
    @State private var holding = false

    var body: some View {
        if app.continuousJogEnabled && direction != .home {
            label
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(holding ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18)))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !holding else { return }
                        holding = true
                        app.controller.beginContinuousJog(direction, feed: app.jogFeed)
                    }
                    .onEnded { _ in
                        holding = false
                        app.controller.endContinuousJog()
                    })
        } else {
            Button(action: step) { label }
        }
    }
}

// MARK: - save dialog options

struct SaveOptionsView: View {
    @ObservedObject var model: SaveOptionsModel
    var hasHeader: Bool
    var hasFooter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.related) {
            Toggle("Write the header", isOn: $model.options.includeHeader).disabled(!hasHeader)
            Toggle("Write the footer", isOn: $model.options.includeFooter).disabled(!hasFooter)
            ControlRow("Passes") { Stepper(value: $model.options.passes, in: 1...50) { Text("\(model.options.passes)").monospacedDigit() } }
            ControlRow("Line endings") {
                Picker("", selection: $model.options.lineEnding) {
                    Text("LF (macOS, Linux)").tag(LineEnding.lf)
                    Text("CRLF (Windows)").tag(LineEnding.crlf)
                }.labelsHidden().frame(width: 190)
            }
        }
        .padding(Metrics.dialog)
        .frame(width: 380)
    }
}

// MARK: - job history

struct JobHistorySheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var selection: String?
    @State private var tick = 0

    private func icon(_ o: UsageEntry.Outcome) -> (String, Color, String) {
        switch o {
        case .finished: return ("checkmark.circle.fill", .green, L("Finished"))
        case .stopped: return ("stop.circle.fill", .orange, L("Stopped"))
        case .failed: return ("exclamationmark.triangle.fill", .red, L("Failed"))
        }
    }

    var body: some View {
        let records = app.history.records
        VStack(alignment: .leading, spacing: Metrics.group) {
            Text("Job History").font(.title2).fontWeight(.semibold)
            if records.isEmpty {
                Text("Finished and stopped jobs appear here, so that you can open them again.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                List(records, selection: $selection) { r in
                    HStack(spacing: Metrics.group) {
                        thumbnail(r)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).fontWeight(.medium)
                            Text(r.date.formatted(date: .abbreviated, time: .shortened) + " · " + GCodeProgram.formatDuration(r.seconds)).font(.caption).foregroundStyle(.secondary)
                            Text(r.machine + " · " + L("%d lines", r.lines) + (r.errors > 0 ? " · " + L("%d errors", r.errors) : "")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let o = icon(r.outcome)
                        Label { Text(o.2) } icon: { Image(systemName: o.0).foregroundStyle(o.1) }.font(.caption)
                    }
                    .padding(.vertical, 3)
                    .tag(r.id)
                    .contextMenu {
                        Button("Open Again") { app.reopen(r); dismiss() }.disabled(!r.hasGCode)
                        Button("Delete Button") { app.history.delete(id: r.id); tick += 1 }
                    }
                    .onTapGesture(count: 2) { if r.hasGCode { app.reopen(r); dismiss() } }
                }
                .frame(height: 360)
            }
            HStack {
                Button("Clear History…") { app.history.clear(); selection = nil; tick += 1 }.disabled(records.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open Again") {
                    if let r = records.first(where: { $0.id == selection }) { app.reopen(r); dismiss() }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(!(records.first { $0.id == selection }?.hasGCode ?? false))
            }
        }
        .padding(Metrics.dialog).frame(width: 640)
        .id(tick)
    }

    @ViewBuilder private func thumbnail(_ r: JobRecord) -> some View {
        Group {
            if r.hasThumbnail, let d = app.history.thumbnail(for: r.id), let img = NSImage(data: d) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "doc.text").font(.system(size: 22)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 60)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
    }
}
