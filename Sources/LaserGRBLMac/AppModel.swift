import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LaserGRBLCore

struct CustomButton: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var gcode: String
    var confirm = false
    /// Name of one of the bundled icons (Resources/Icons), shown beside the title.
    var icon: String? = nil
    /// English text of a built-in button's title. While set, the title is shown in the current language
    /// (so the default buttons are not stuck in the language that was active when they were first saved).
    var titleKey: String? = nil

    /// What the button says right now.
    var displayTitle: String { titleKey.map { L($0) } ?? title }
}

/// Everything the window shares: the machine controller plus what the person picked in the UI.
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let controller = GrblController()

    @Published var ports: [String] = []
    @Published var selectedPort: String {
        didSet { UserDefaults.standard.set(selectedPort, forKey: "port") }
    }
    @Published var baud: Int {
        didSet { UserDefaults.standard.set(baud, forKey: "baud") }
    }
    @Published var jogStep: Double {
        didSet { UserDefaults.standard.set(jogStep, forKey: "jogStep") }
    }
    @Published var jogFeed: Double {
        didSet { UserDefaults.standard.set(jogFeed, forKey: "jogFeed") }
    }
    @Published var customButtons: [CustomButton] = [] {
        didSet { saveButtons() }
    }
    @Published var preview = PreviewModel()
    @Published var showImageImport = false
    @Published var importURL: URL?
    @Published var showGrblConfig = false
    @Published var alertMessage: String?
    @Published var framePower: Double = 0
    @Published var showConsole: Bool = UserDefaults.standard.object(forKey: "showConsole") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showConsole, forKey: "showConsole") }
    }
    @Published var showInspector: Bool = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }

    static let bauds = [9600, 19200, 38400, 57600, 115200, 230400, 250000, 460800, 921600]

    private var refreshTimer: Timer?

    // MARK: preferences (also edited in the Settings window through @AppStorage)

    private func flag(_ key: String, _ fallback: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }

    /// Speed used for rapid moves in time estimates until the machine reports `$110`.
    var rapidRate: Double {
        Double(controller.settings[110] ?? "") ?? (UserDefaults.standard.object(forKey: "rapidRate") as? Double ?? 2000)
    }

    /// "system", "light" or "dark".
    func applyAppearance() {
        switch UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: NSApplication.shared.appearance = nil
        }
    }

    /// Stores the language for the next launch ("system" follows macOS).
    func setLanguage(_ code: String) {
        if code == "system" { UserDefaults.standard.set(nil, forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
    }

    /// Starts a fresh copy of the app (needed to switch language) and quits this one.
    func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else {
            alertMessage = L("Please quit and open the app again to use the new language.")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; open -n \"$0\"", path]
        try? p.run()
        controller.disconnect()
        NSApp.terminate(nil)
    }

    func resetPreferences() {
        let d = UserDefaults.standard
        for k in ["appearance", "appLanguage", "soundOnFinish", "soundVolume", "notifyOnFinish", "alertOnError", "autoConnect", "rapidRate",
                  "previewShowTravel", "previewShowGrid", "previewFollowsAppearance", "AppleLanguages"] { d.set(nil, forKey: k) }
        applyAppearance()
    }

    init() {
        let d = UserDefaults.standard
        selectedPort = d.string(forKey: "port") ?? ""
        baud = d.object(forKey: "baud") as? Int ?? 115200
        jogStep = d.object(forKey: "jogStep") as? Double ?? 10
        jogFeed = d.object(forKey: "jogFeed") as? Double ?? 3000
        if let data = d.data(forKey: "customButtons"), let b = try? JSONDecoder().decode([CustomButton].self, from: data) {
            customButtons = AppModel.migrated(b)
        } else {
            customButtons = AppModel.defaultButtons()
        }
        if let h = d.string(forKey: "header") { controller.jobSettings.header = h }
        if let f = d.string(forKey: "footer") { controller.jobSettings.footer = f }
        refreshPorts()
        applyAppearance()
        controller.onEvent = { [weak self] event in self?.handle(event) }
        if flag("autoConnect", false), !selectedPort.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self, self.controller.state == .disconnected, self.ports.contains(self.selectedPort) else { return }
                self.controller.connect(path: self.selectedPort, baud: self.baud)
            }
        }
        // A file given on the command line (or via "Open With") is loaded at start-up.
        if let path = CommandLine.arguments.dropFirst().first(where: { FileManager.default.fileExists(atPath: $0) }) {
            DispatchQueue.main.async { self.openFile(URL(fileURLWithPath: path)) }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, !self.controller.isConnected else { return }
            self.refreshPorts()
        }
    }

    /// The built-in buttons; their titles follow the app language.
    static func defaultButtons() -> [CustomButton] {
        func make(_ key: String, _ gcode: String, icon: String, confirm: Bool = false) -> CustomButton {
            CustomButton(title: L(key), gcode: gcode, confirm: confirm, icon: icon, titleKey: key)
        }
        return [
            make("Home", "$H", icon: "home"),
            make("Unlock", "$X", icon: "unlock"),
            make("Set Zero Here", "G92 X0 Y0", icon: "target", confirm: true),
            make("Go to Zero", "G90\nG0 X0 Y0", icon: "fit"),
            make("Aim (Laser 1%)", "M3 S10", icon: "target"),
            make("Laser Off", "M5", icon: "stop"),
        ]
    }

    /// Buttons saved by an earlier version carry their title in whatever language was active then
    /// (for example French). Recognise the built-in ones and make them follow the app language again.
    static func migrated(_ buttons: [CustomButton], languages: [Bundle] = ["en", "de", "fr"].compactMap { lang -> Bundle? in
        Bundle.main.path(forResource: lang, ofType: "lproj").flatMap { Bundle(path: $0) }
    }) -> [CustomButton] {
        let defaults = defaultButtons()
        return buttons.map { b in
            guard b.titleKey == nil,
                  let d = defaults.first(where: { $0.gcode == b.gcode && $0.confirm == b.confirm }),
                  let key = d.titleKey else { return b }
            let known = languages.map { $0.localizedString(forKey: key, value: key, table: nil) } + [key]
            guard known.contains(b.title) else { return b }
            var m = b
            m.titleKey = key
            if m.icon == nil { m.icon = d.icon }
            return m
        }
    }

    private func saveButtons() {
        if let data = try? JSONEncoder().encode(customButtons) { UserDefaults.standard.set(data, forKey: "customButtons") }
    }

    func saveJobSettings() {
        UserDefaults.standard.set(controller.jobSettings.header, forKey: "header")
        UserDefaults.standard.set(controller.jobSettings.footer, forKey: "footer")
    }

    func refreshPorts() {
        let list = SerialPort.availablePorts()
        if list != ports { ports = list }
        if selectedPort.isEmpty || !list.contains(selectedPort) {
            if let usb = list.first(where: { $0.contains("usb") }) ?? list.first { selectedPort = usb }
        }
    }

    func toggleConnection() {
        if controller.state == .disconnected {
            guard !selectedPort.isEmpty else {
                alertMessage = L("No serial port found. Plug in the laser's USB cable and refresh the list of ports.")
                return
            }
            controller.connect(path: selectedPort, baud: baud)
        } else {
            controller.disconnect()
        }
    }

    // MARK: files

    func openGCode() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["nc", "gcode", "gc", "ngc", "tap", "cnc", "txt", "gco"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
        panel.message = L("Choose a G-code file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadGCode(url)
    }

    func openFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "bmp", "tif", "tiff", "gif", "heic"].contains(ext) {
            importURL = url; showImageImport = true
        } else { loadGCode(url) }
    }

    func loadGCode(_ url: URL) {
        guard !controller.jobRunning else { alertMessage = L("Stop the running job first."); return }
        let rapid = rapidRate
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let p = try GCodeProgram(contentsOf: url, rapidRate: rapid)
                DispatchQueue.main.async { self.setProgram(p) }
            } catch {
                DispatchQueue.main.async { self.alertMessage = L("Could not read the file: %@", error.localizedDescription) }
            }
        }
    }

    func setProgram(_ p: GCodeProgram) {
        controller.load(p)
        preview.set(program: p)
        preview.requestFit = true
        objectWillChange.send()
    }

    func saveGCode() {
        guard let p = controller.program else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (p.name as NSString).deletingPathExtension + ".nc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let js = controller.jobSettings
        var out = js.header + "\n"
        for _ in 0..<max(1, js.passes) { out += p.text + "\n" }
        out += js.footer + "\n"
        do { try out.write(to: url, atomically: true, encoding: .utf8) }
        catch { alertMessage = L("Could not save: %@", error.localizedDescription) }
    }

    func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .bmp, .tiff, .gif, .heic]
        panel.message = L("Choose an image to engrave")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importURL = url
        showImageImport = true
    }

    func runCustomButton(_ b: CustomButton) {
        if LaserSafety.firesLaser(b.gcode) {
            // anything that switches the laser on needs the eye-protection check
            guard LaserSafety.confirm(title: b.displayTitle, confirmButton: L("Switch Laser On"), extra: b.gcode) else { return }
        } else if b.confirm {
            let a = NSAlert()
            a.messageText = b.displayTitle
            a.informativeText = L("Send this to the machine?") + "\n\n" + b.gcode
            a.addButton(withTitle: L("Send")); a.addButton(withTitle: L("Cancel"))
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        b.gcode.split(whereSeparator: \.isNewline).forEach { controller.send(String($0)) }
    }

    /// Traces the outline of the job; with a power above 0 the laser is on, so the safety check applies.
    func runFrame() {
        if framePower > 0 {
            guard LaserSafety.confirm(title: L("Frame"), confirmButton: L("Switch Laser On"),
                                      extra: L("The laser will trace the outline at low power.")) else { return }
        }
        controller.runFrame(power: Int(framePower))
    }

    /// Start button, menu item and shortcut all end up here. The job only starts after the eye-protection
    /// check has been confirmed; this cannot be switched off.
    func confirmStart() {
        guard controller.canStartJob, let p = controller.program else { return }
        let time = L("Estimated time: %@", GCodeProgram.formatDuration(p.estimatedSeconds))
        guard LaserSafety.confirm(title: L("Start “%@”?", p.name), confirmButton: L("Start"), extra: time) else { return }
        Notifier.requestPermission()
        controller.startJob()
    }

    // MARK: sounds, alerts and notifications

    private var jobErrorAlerted = false
    private var alertShowing = false

    private func handle(_ event: ControllerEvent) {
        switch event {
        case .connected:
            Sounds.play(.connected)
        case .connectionFailed(let message):
            Sounds.play(.connectionFailed)
            present(title: L("Connection failed"),
                    message: message + "\n\n" + L("Check that the USB cable is plugged in, the laser is switched on and the baud rate matches."),
                    style: .warning)
        case .jobStarted:
            jobErrorAlerted = false
            Sounds.play(.started)
        case .lineError(let message, let line):
            Sounds.play(.error)
            guard !jobErrorAlerted else { return }
            jobErrorAlerted = true
            present(title: L("Grbl reported an error"),
                    message: message + "\n\n" + L("Line: %@", line) + "\n\n" + L("The job continues. Further errors are listed in the console."),
                    style: .warning)
        case .alarm(let message):
            Sounds.play(.alarm)
            present(title: L("Machine alarm"),
                    message: message + "\n\n" + L("Unlock the machine to continue, or home it if its position may be lost."),
                    style: .critical, actions: [(L("Unlock"), { [weak self] in self?.controller.unlock() }),
                                                (L("Home"), { [weak self] in self?.controller.home() })])
        case .connectionLost:
            Sounds.play(.error)
            present(title: L("Connection lost"),
                    message: L("The connection to the machine was lost and the job was stopped. If the laser is still on, switch the machine off with its own power switch."),
                    style: .critical)
        case .controllerRestarted:
            Sounds.play(.error)
            present(title: L("Controller restarted"),
                    message: L("The controller restarted during the job, so the job was stopped."), style: .warning)
        case .jobFinished(let aborted, let errors, let seconds, let name):
            guard !aborted else { return }
            Sounds.play(.finished)
            let time = GCodeProgram.formatDuration(seconds)
            var body = L("“%@” finished in %@.", name, time)
            if errors > 0 { body += " " + L("%d errors", errors) }
            if flag("notifyOnFinish", true) { Notifier.post(title: L("Job finished"), body: body) }
            if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
            if errors > 0 {
                present(title: L("Job finished with errors"), message: body + "\n\n" + L("Check the console for the lines Grbl rejected."), style: .warning)
            }
        }
    }

    /// Shows a sheet on the main window (or a dialog when there is none); only one at a time.
    private func present(title: String, message: String, style: NSAlert.Style, actions: [(String, () -> Void)] = []) {
        guard flag("alertOnError", true), !alertShowing else { return }
        alertShowing = true
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        for (name, _) in actions { alert.addButton(withTitle: name) }
        alert.addButton(withTitle: L("Close"))
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.alertShowing = false
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if index >= 0, index < actions.count { actions[index].1() }
        }
        if let window = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet && $0.canBecomeMain }) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
    }
}
