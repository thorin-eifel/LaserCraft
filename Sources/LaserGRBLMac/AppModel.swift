import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
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
    // layout, tools, materials, profiles
    let layout = LayoutModel()
    // keyboard, console, history, Dock
    @Published var hotkeys = AppModel.loadHotkeys()
    @Published var consoleFilter = ConsoleFilter()
    @Published var consoleTimestamps = UserDefaults.standard.bool(forKey: "consoleTimestamps") {
        didSet { UserDefaults.standard.set(consoleTimestamps, forKey: "consoleTimestamps") }
    }
    @Published var consoleAutoScroll = UserDefaults.standard.object(forKey: "consoleAutoScroll") as? Bool ?? true {
        didSet { UserDefaults.standard.set(consoleAutoScroll, forKey: "consoleAutoScroll") }
    }
    let history = JobHistoryStore(directory: AppModel.supportDirectory.appendingPathComponent("history", isDirectory: true))
    let dock = DockProgress()
    var progressTimer: Timer?
    @Published var mainMode: MainMode = .job
    @Published var tool: ToolSheet?
    /// True when the loaded job was generated from the layout (it is made again before a start if the layout changed).
    var jobFromLayout = false
    let materials = MaterialDB(builtinData: AppModel.builtinMaterialsData(),
                               userFile: AppModel.supportDirectory.appendingPathComponent("materials.json"))
    let profiles = ProfileStore(directory: AppModel.supportDirectory)
    @Published var activeProfileID: String?
    @Published var networkMachines: [String] = UserDefaults.standard.stringArray(forKey: "networkMachines") ?? []
    @Published var discovered: [NetworkDiscovery.Found] = []
    let discovery = NetworkDiscovery()
    @Published var showImageImport = false
    @Published var importURL: URL?
    @Published var showGrblConfig = false
    @Published var alertMessage: String?
    @Published var framePower: Double = 0
    /// True while the Mac is being kept awake for a running job.
    @Published private(set) var keepingAwake = false
    let sleepGuard = SleepGuard()
    @Published var showConsole: Bool = UserDefaults.standard.object(forKey: "showConsole") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showConsole, forKey: "showConsole") }
    }
    @Published var showInspector: Bool = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }

    static let bauds = [9600, 19200, 38400, 57600, 115200, 230400, 250000, 460800, 921600]

    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: resume a stopped job

    /// Where the last job stopped (kept for the next launch, so a job can be continued after a crash or a power cut).
    struct StopInfo: Codable, Equatable { var name: String; var count: Int; var line: Int }
    @Published var stopInfo: StopInfo? = {
        UserDefaults.standard.data(forKey: "lastStop").flatMap { try? JSONDecoder().decode(StopInfo.self, from: $0) }
    }()
    @Published var showResume = false
    @Published var resumeLine = 0            // 0-based program line the Resume sheet starts with

    /// Grbl acknowledges lines before it has moved: take a few lines back so nothing is skipped.
    static let resumeSafetyLines = 16

    private func rememberStop(_ info: StopInfo?) {
        stopInfo = info
        if let info = info, let data = try? JSONEncoder().encode(info) { UserDefaults.standard.set(data, forKey: "lastStop") }
        else { UserDefaults.standard.removeObject(forKey: "lastStop") }
    }

    /// The line to suggest in the Resume sheet for the loaded job.
    var suggestedResumeLine: Int {
        guard let p = controller.program else { return 0 }
        if let s = stopInfo, s.name == p.name, s.count == p.commands.count { return min(max(0, s.line), p.commands.count - 1) }
        return 0
    }

    func openResume(line: Int? = nil) {
        guard controller.program != nil else { return }
        resumeLine = line ?? suggestedResumeLine
        showResume = true
    }

    /// Continue the job at `line` (0-based) — after the same safety check as a normal start.
    func resumeJob(fromLine line: Int) {
        confirmStart(fromCommand: line)
    }

    // MARK: cooling pauses and reconnecting

    @Published private(set) var reconnecting = false
    let reconnect = AutoReconnect()

    func applyCoolingPrefs() {
        let d = UserDefaults.standard
        controller.coolingEnabled = d.object(forKey: "coolingEnabled") as? Bool ?? false
        controller.coolingRunSeconds = Double(d.object(forKey: "coolRunMinutes") as? Int ?? 5) * 60
        controller.coolingPauseSeconds = Double(d.object(forKey: "coolPauseMinutes") as? Int ?? 1) * 60
    }

    private func setUpReconnect() {
        reconnect.isPortAvailable = { SerialPort.availablePorts().contains($0) }
        reconnect.connect = { [weak self] port in
            guard let self = self, self.controller.state == .disconnected else { return }
            self.controller.connect(path: port, baud: self.baud)
        }
        reconnect.onGiveUp = { [weak self] in
            guard let self = self else { return }
            self.reconnecting = false
            self.present(title: L("Could not reconnect"),
                         message: L("The laser did not come back. Check the USB cable and the power, then press Connect."), style: .warning)
        }
    }

    // MARK: updates

    /// "1.0.0-beta.2" from Info.plist (CFBundleShortVersionString is kept numeric for macOS).
    var currentVersion: AppVersion {
        let text = Bundle.main.object(forInfoDictionaryKey: "LaserCraftVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return AppVersion(text) ?? AppVersion(major: 0, minor: 0, patch: 0)
    }

    /// `silent`: the automatic check at launch only speaks up when there is something new.
    func checkForUpdates(silent: Bool) {
        if AutoUpdater.shared.isEnabled { if !silent { AutoUpdater.shared.checkForUpdates() }; return }
        UpdateChecker.check(current: currentVersion) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let release?):
                let a = NSAlert()
                a.messageText = L("A new version is available")
                a.informativeText = L("%@ is available. You are using %@.", release.name, self.currentVersion.description)
                a.addButton(withTitle: L("Download"))
                a.addButton(withTitle: L("Later"))
                if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.url) }
            case .success(nil):
                if !silent { self.alertMessage = L("LaserCraft is up to date (%@).", self.currentVersion.description) }
            case .failure:
                if !silent { self.alertMessage = L("Could not check for updates. Are you online?") }
            }
        }
    }

    private func autoCheckForUpdates() {
        guard !AutoUpdater.shared.isEnabled else { return }          // Sparkle checks by itself
        let d = UserDefaults.standard
        guard d.object(forKey: "autoUpdateCheck") as? Bool ?? true, Notifier.isAvailable else { return }
        let last = d.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        d.set(Date(), forKey: "lastUpdateCheck")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.checkForUpdates(silent: true) }
    }

    // MARK: simulator ("demo machine")

    /// Port name of the built-in simulated machine; it appears in the port list like a USB port.
    static let simulatorPort = "simulator"
    let simulator = GrblSimulator(speedFactor: 4)

    func portName(_ path: String) -> String {
        if path == AppModel.simulatorPort { return L("Simulator (demo machine)") }
        if let a = NetworkAddress.parse(path) {
            return "\(a.host) (\(a.kind == .webSocket ? "WebSocket" : a.kind == .telnet ? "Telnet" : "TCP"))"
        }
        return (path as NSString).lastPathComponent
    }

    // MARK: recent files

    @Published var recentFiles: [URL] = (UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }

    func noteRecent(_ url: URL) {
        var list = recentFiles.filter { $0 != url }
        list.insert(url, at: 0)
        recentFiles = Array(list.prefix(10))
        UserDefaults.standard.set(recentFiles.map { $0.path }, forKey: "recentFiles")
    }

    func clearRecents() {
        recentFiles = []
        UserDefaults.standard.set([String](), forKey: "recentFiles")
    }

    // MARK: diagnostics

    private var versionText: String {
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(currentVersion) (\(b))"
    }

    func copyDiagnosticReport() {
        let report = Diagnostics.report(appVersion: versionText, system: ProcessInfo.processInfo.operatingSystemVersionString,
                                        port: selectedPort, baud: baud, controller: controller)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        alertMessage = L("The diagnostic report was copied to the clipboard. Paste it into your bug report.")
    }

    func saveConsoleLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "lasercraft-console.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Diagnostics.consoleText(controller.console).appending("\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { alertMessage = L("Could not save: %@", error.localizedDescription) }
    }

    // MARK: warnings before a job

    /// Problems of the loaded job for the machine that is connected (empty while the machine's settings are unknown).
    var jobWarnings: [JobWarning] {
        guard let p = controller.program, !controller.settings.isEmpty else { return [] }
        return JobCheck.run(program: p, settings: controller.settings, workOffset: controller.workOffset)
    }

    /// Double-click in the preview: move the laser head (laser off) to this work position.
    func jogToPoint(x: Double, y: Double) {
        controller.jogTo(x: x, y: y, feed: jogFeed)
    }

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
        for k in ["appearance", "appLanguage", "soundOnFinish", "soundVolume", "showSimulator", "autoReconnect", "autoUpdateCheck", "coolingEnabled", "coolRunMinutes", "coolPauseMinutes", "keepAwake", "keepDisplayOn", "notifyOnFinish", "alertOnError", "autoConnect", "rapidRate",
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
            customButtons = AppModel.addingCenterButton(AppModel.migrated(b))
        } else {
            customButtons = AppModel.defaultButtons()
        }
        if let h = d.string(forKey: "header") { controller.jobSettings.header = h }
        if let f = d.string(forKey: "footer") { controller.jobSettings.footer = f }
        refreshPorts()
        applyAppearance()
        HotkeyManager.shared.install(app: self)
        controller.onEvent = { [weak self] event in self?.handle(event) }
        observeSleep()
        applyCoolingPrefs()
        setUpReconnect()
        autoCheckForUpdates()
        controller.$state.sink { [weak self] state in
            guard let self = self, state == .disconnected, self.simulator.isRunning else { return }
            DispatchQueue.main.async { self.simulator.stop() }
        }.store(in: &cancellables)
        if flag("autoConnect", false), !selectedPort.isEmpty, selectedPort != AppModel.simulatorPort {
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
            make("Go to Center", "G90\nG0 X{centerX} Y{centerY}", icon: "center"),
            make("Aim (Laser 1%)", "M3 S10", icon: "target"),
            make("Laser Off", "M5", icon: "stop"),
        ]
    }

    /// Buttons saved by an earlier version carry their title in whatever language was active then
    /// (for example French). Recognise the built-in ones and make them follow the app language again.
    static func migrated(_ buttons: [CustomButton], languages: [Bundle] = ["en", "de", "fr", "es", "it", "pt-BR", "nl", "pl"].compactMap { lang -> Bundle? in
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

    /// Buttons saved before "Go to Center" existed get it once, right after "Go to Zero" (later it can be deleted again).
    static func addingCenterButton(_ buttons: [CustomButton], defaults: UserDefaults = .standard) -> [CustomButton] {
        guard !defaults.bool(forKey: "centerButtonAdded") else { return buttons }
        defaults.set(true, forKey: "centerButtonAdded")
        guard !buttons.contains(where: { $0.gcode.contains("{centerX}") }),
              let center = defaultButtons().first(where: { $0.gcode.contains("{centerX}") }) else { return buttons }
        var list = buttons
        if let i = list.firstIndex(where: { $0.titleKey == "Go to Zero" || $0.gcode == "G90\nG0 X0 Y0" }) { list.insert(center, at: i + 1) }
        else { list.append(center) }
        return list
    }

    private func saveButtons() {
        if let data = try? JSONEncoder().encode(customButtons) { UserDefaults.standard.set(data, forKey: "customButtons") }
    }

    func saveJobSettings() {
        UserDefaults.standard.set(controller.jobSettings.header, forKey: "header")
        UserDefaults.standard.set(controller.jobSettings.footer, forKey: "footer")
    }

    func refreshPorts() {
        let real = SerialPort.availablePorts()
        let showSim = UserDefaults.standard.object(forKey: "showSimulator") as? Bool ?? true
        var network = networkMachines
        for f in discovered where !network.contains(f.address.url) { network.append(f.address.url) }
        let list = real + network + (showSim ? [AppModel.simulatorPort] : [])
        if list != ports { ports = list }
        if selectedPort.isEmpty || !list.contains(selectedPort) {
            if let usb = real.first(where: { $0.contains("usb") }) ?? list.first { selectedPort = usb }
        }
    }

    func toggleConnection() {
        reconnect.stop(); reconnecting = false
        if controller.state == .disconnected {
            guard !selectedPort.isEmpty else {
                alertMessage = L("No serial port found. Plug in the laser's USB cable and refresh the list of ports.")
                return
            }
            applyProfile(forConnection: selectedPort)
            if selectedPort == AppModel.simulatorPort {
                guard let path = simulator.start() else { alertMessage = L("The simulator could not be started."); return }
                controller.connect(path: path, baud: baud)
            } else {
                controller.connect(path: selectedPort, baud: baud)
            }
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
        } else if VectorFileKind.extensions.contains(ext) {
            tool = .vector(.svg(url))
        } else if ext == ProjectIO.fileExtension {
            openProject(url)
        } else { loadGCode(url) }
        noteRecent(url)
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

    func setProgram(_ p: GCodeProgram, fromLayout: Bool = false) {
        jobFromLayout = fromLayout
        controller.load(p)
        preview.set(program: p)
        preview.requestFit = true
        objectWillChange.send()
    }

    func saveGCode() {
        guard let p = controller.program else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (p.name as NSString).deletingPathExtension + ".nc"
        let js = controller.jobSettings
        let model = SaveOptionsModel(passes: js.passes)
        let hosting = NSHostingView(rootView: SaveOptionsView(model: model, hasHeader: !js.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                                              hasFooter: !js.footer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        panel.accessoryView = hosting
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let out = GCodeExporter.text(program: p, header: js.header, footer: js.footer, options: model.options)
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
        var code = b.gcode
        if code.contains("{centerX}") || code.contains("{centerY}") {
            // the middle of the output area ($130 / $131), which the machine has to tell first
            guard let w = Double(controller.settings[130] ?? ""), let h = Double(controller.settings[131] ?? ""), w > 0, h > 0 else {
                alertMessage = L("The size of the work area is not known yet. Connect to the machine so that it can be read ($130, $131).")
                return
            }
            code = code.replacingOccurrences(of: "{centerX}", with: Self.coordinate(w / 2))
                .replacingOccurrences(of: "{centerY}", with: Self.coordinate(h / 2))
        }
        code.split(whereSeparator: \.isNewline).forEach { controller.send(String($0)) }
    }

    static func coordinate(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
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
    func confirmStart(fromCommand start: Int = 0) {
        if mainMode == .layout || jobFromLayout, layout.needsGenerate, controller.canStartJob { useLayoutAsJob() }
        guard controller.canStartJob, let p = controller.program else { return }
        var extra = L("Estimated time: %@", GCodeProgram.formatDuration(p.estimatedSeconds))
        if start > 0 {
            extra = L("The job continues at line %d of %d. The laser first travels to the end of the previous line with the laser off.", start + 1, p.commands.count) + "\n\n" + extra
        }
        let warnings = jobWarnings
        if !warnings.isEmpty {
            extra += "\n\n" + L("Please check before you start:") + "\n" + warnings.map { "⚠︎ " + $0.text }.joined(separator: "\n")
        }
        guard LaserSafety.confirm(title: L("Start “%@”?", p.name), confirmButton: L("Start"), extra: extra) else { return }
        Notifier.requestPermission()
        controller.startJob(fromCommand: start)
    }

    // MARK: keep the Mac awake while a job runs

    /// Called when a job starts: no sleep (and no App Nap) until it ends. Before and after a job the Mac sleeps as usual.
    func beginStayAwake() {
        guard flag("keepAwake", true) else { return }
        sleepGuard.begin(keepDisplayOn: flag("keepDisplayOn", false))
        keepingAwake = sleepGuard.isActive
    }

    func endStayAwake() {
        sleepGuard.end()
        keepingAwake = false
    }

    /// A sleep that cannot be prevented (closing a MacBook lid, low battery, Apple menu → Sleep) must not leave the laser
    /// burning: the job is paused (feed hold) right before the Mac sleeps, and the person is told after waking up.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.controller.jobRunning else { return }
            self.controller.feedHold()
            self.sleptDuringJob = true
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.sleptDuringJob else { return }
            self.sleptDuringJob = false
            if self.controller.jobRunning {
                self.present(title: L("The Mac went to sleep"),
                             message: L("The job was paused when the Mac went to sleep. Check the machine, then press Resume to continue or Stop to end the job."),
                             style: .warning)
            }
        }
    }

    // MARK: sounds, alerts and notifications

    private var jobErrorAlerted = false
    private var sleptDuringJob = false
    private var alertShowing = false

    private func handle(_ event: ControllerEvent) {
        switch event {
        case .connected:
            reconnect.stop()
            if reconnecting { reconnecting = false; alertMessage = nil }
            Sounds.play(.connected)
        case .connectionFailed(let message):
            if reconnecting { return }          // the next attempt is already scheduled
            Sounds.play(.connectionFailed)
            present(title: L("Connection failed"),
                    message: message + "\n\n" + L("Check that the USB cable is plugged in, the laser is switched on and the baud rate matches."),
                    style: .warning)
        case .coolingStarted:
            Sounds.play(.go)
        case .coolingEnded:
            Sounds.play(.started)
        case .bufferResynced:
            Sounds.play(.error)          // the console explains what happened; the job carries on
        case .emergencyStopped:
            Sounds.play(.alarm)
        case .jobStarted:
            startDockProgress()
            CameraModel.shared.jobStarted(name: controller.program?.name ?? "job")
            beginStayAwake()
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
            // A USB wobble without a job: try to get the connection back by itself. During a job it is never safe to
            // carry on automatically, so the person is told instead.
            if !controller.jobRunning, flag("autoReconnect", true), selectedPort != AppModel.simulatorPort, !selectedPort.isEmpty,
               !NetworkAddress.isNetwork(selectedPort) {
                reconnecting = true
                reconnect.start(port: selectedPort)
                return
            }
            present(title: L("Connection lost"),
                    message: L("The connection to the machine was lost and the job was stopped. If the laser is still on, switch the machine off with its own power switch."),
                    style: .critical)
        case .controllerRestarted:
            Sounds.play(.error)
            present(title: L("Controller restarted"),
                    message: L("The controller restarted during the job, so the job was stopped."), style: .warning)
        case .jobFinished(let aborted, let errors, let seconds, let name):
            endStayAwake()   // the Mac may sleep again, whatever the outcome
            CameraModel.shared.jobEnded()
            recordUsage(aborted: aborted, errors: errors, seconds: seconds, name: name)
            recordHistory(aborted: aborted, errors: errors, seconds: seconds, name: name)
            stopDockProgress()
            sendRemoteNotification(name: name, seconds: seconds, aborted: aborted, errors: errors)
            if aborted {
                // remember where it stopped so it can be continued later
                if let p = controller.program, controller.jobExecuted > 0 {
                    rememberStop(StopInfo(name: p.name, count: p.commands.count,
                                          line: max(0, controller.executedProgramCommands - AppModel.resumeSafetyLines)))
                }
                return
            }
            rememberStop(nil)
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

    func presentInfo(title: String, message: String) { present(title: title, message: message, style: .informational) }

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
