import SwiftUI
import AppKit
import LaserGRBLCore

// MARK: - keyboard

/// Turns key presses into machine actions: jogging, jog step and speed, power override, custom buttons.
/// Keys only work when the main window is active and no text field is being edited.
final class HotkeyManager {
    static let shared = HotkeyManager()
    private var monitors: [Any] = []
    /// Set while a shortcut is being recorded in the settings.
    var suspended = false
    private var held: (action: HotkeyAction, key: String)?
    private weak var app: AppModel?

    func install(app: AppModel) {
        guard monitors.isEmpty else { return }
        self.app = app
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.keyDown(e) ?? e } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] e in self?.keyUp(e) ?? e } as Any)
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.releaseHeld() }
    }

    static func modifiers(_ f: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.shift) { m.insert(.shift) }
        return m
    }

    static func combo(for e: NSEvent) -> KeyCombo? {
        KeyCombo.make(characters: e.charactersIgnoringModifiers ?? "", keyCode: e.keyCode, modifiers: modifiers(e.modifierFlags))
    }

    /// Keys are not for the machine while the person types.
    private func keysAreFree() -> Bool {
        guard !suspended, NSApp.isActive, let w = NSApp.keyWindow, w.attachedSheet == nil, w.sheetParent == nil, !(w is NSPanel) else { return false }
        if w.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true { return false }
        if w.firstResponder is NSText { return false }
        return true
    }

    private func keyDown(_ e: NSEvent) -> NSEvent? {
        guard let app = app, keysAreFree(), let combo = HotkeyManager.combo(for: e), !combo.modifiers.contains(.command),
              let action = app.hotkeys.action(for: combo) else { return e }
        if e.isARepeat { return nil }                           // a held key is handled by the first press
        if action.isJog, let dir = action.direction, app.continuousJogEnabled, !action.isBigStep {
            held = (action, combo.key)
            app.controller.beginContinuousJog(dir, feed: app.jogFeed)
        } else {
            app.perform(hotkey: action)
        }
        return nil
    }

    private func keyUp(_ e: NSEvent) -> NSEvent? {
        guard let h = held else { return e }
        let key = KeyCombo.make(characters: e.charactersIgnoringModifiers ?? "", keyCode: e.keyCode, modifiers: [])?.key
        if key == h.key { releaseHeld() }
        return e
    }

    func releaseHeld() {
        guard held != nil else { return }
        held = nil
        app?.controller.endContinuousJog()
    }
}

extension AppModel {
    static let jogSteps: [Double] = [0.1, 0.5, 1, 5, 10, 50, 100]
    static let jogSpeeds: [Double] = [100, 200, 500, 1000, 2000, 3000, 5000, 8000, 10000]

    var continuousJogEnabled: Bool { UserDefaults.standard.object(forKey: "continuousJog") as? Bool ?? false }

    /// One key press (not held).
    func perform(hotkey a: HotkeyAction) {
        if a.isJog, let dir = a.direction {
            controller.jog(dir, step: a.isBigStep ? jogStep * 10 : jogStep, feed: jogFeed)
            return
        }
        switch a {
        case .stepUp: if let i = AppModel.jogSteps.firstIndex(of: jogStep), i + 1 < AppModel.jogSteps.count { jogStep = AppModel.jogSteps[i + 1] }
        case .stepDown: if let i = AppModel.jogSteps.firstIndex(of: jogStep), i > 0 { jogStep = AppModel.jogSteps[i - 1] }
        case .speedUp: jogFeed = AppModel.jogSpeeds.first { $0 > jogFeed } ?? jogFeed
        case .speedDown: jogFeed = AppModel.jogSpeeds.last { $0 < jogFeed } ?? jogFeed
        case .powerUp: controller.setOverrides(spindle: controller.targetOverrides.spindle + 10)
        case .powerDown: controller.setOverrides(spindle: controller.targetOverrides.spindle - 10)
        default:
            if let i = a.buttonIndex, i < customButtons.count, controller.isConnected, !controller.jobRunning { runCustomButton(customButtons[i]) }
        }
    }

    func saveHotkeys() {
        if let d = try? JSONEncoder().encode(hotkeys) { UserDefaults.standard.set(d, forKey: "hotkeys") }
    }

    static func loadHotkeys() -> HotkeyMap {
        if let d = UserDefaults.standard.data(forKey: "hotkeys"), let m = try? JSONDecoder().decode(HotkeyMap.self, from: d) { return m }
        return .defaults
    }
}

/// Records the next key combination.
final class HotkeyRecorder: ObservableObject {
    @Published var recording = false
    private var monitor: Any?
    var onCombo: ((KeyCombo?) -> Void)?

    func start() {
        stop()
        recording = true
        HotkeyManager.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self else { return e }
            if e.keyCode == 53 { self.finish(nil, cancelled: true) }                                       // Esc
            else if e.keyCode == 51 || e.keyCode == 117 { self.finish(nil, cancelled: false) }              // Delete clears
            else if let c = HotkeyManager.combo(for: e), !c.modifiers.contains(.command) { self.finish(c, cancelled: false) }
            return nil
        }
    }

    private func finish(_ c: KeyCombo?, cancelled: Bool) {
        stop()
        if !cancelled { onCombo?(c) }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        HotkeyManager.shared.suspended = false
    }

    deinit { stop() }
}

// MARK: - Dock

/// Progress bar and percentage on the Dock icon while a job runs.
final class DockProgress {
    private final class TileView: NSView {
        var progress = 0.0
        override func draw(_ dirtyRect: NSRect) {
            (NSApp.applicationIconImage ?? NSImage()).draw(in: bounds)
            let bar = NSRect(x: bounds.width * 0.1, y: bounds.height * 0.06, width: bounds.width * 0.8, height: bounds.height * 0.1)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: bar.insetBy(dx: -2, dy: -2), xRadius: bar.height, yRadius: bar.height).fill()
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * progress), height: bar.height), xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        }
    }
    private let view = TileView()
    private(set) var label: String?

    /// `progress` nil clears the Dock icon again.
    func update(progress: Double?, remaining: Double?) {
        let tile = NSApp.dockTile
        guard let p = progress else {
            label = nil
            tile.contentView = nil; tile.badgeLabel = nil; tile.display()
            return
        }
        label = DockProgressText.label(progress: p, remainingSeconds: remaining)
        view.progress = min(1, max(0, p))
        view.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
        tile.contentView = view
        tile.badgeLabel = label
        tile.display()
    }
}

// MARK: - remote notification

enum RemoteSender {
    /// Sends the message; `completion` gets nil on success or the reason.
    static func send(_ message: RemoteNotification.Message, to address: String, session: URLSession = .shared, completion: @escaping (String?) -> Void) {
        guard let req = RemoteNotification.request(address: address, message: message) else {
            completion(L("The address is not valid. Use https://… or ntfy://topic.")); return
        }
        session.dataTask(with: req) { _, response, error in
            DispatchQueue.main.async {
                if let e = error { completion(e.localizedDescription) }
                else if let r = response as? HTTPURLResponse, !(200..<300).contains(r.statusCode) { completion("HTTP \(r.statusCode)") }
                else { completion(nil) }
            }
        }.resume()
    }
}

extension AppModel {
    var remoteEnabled: Bool { UserDefaults.standard.bool(forKey: "remoteEnabled") }
    var remoteAddress: String { UserDefaults.standard.string(forKey: "remoteURL") ?? "" }
    var remoteMinMinutes: Double { UserDefaults.standard.object(forKey: "remoteMinMinutes") as? Double ?? 10 }
    var remoteIncludeName: Bool { UserDefaults.standard.bool(forKey: "remoteIncludeName") }

    func remoteMessage(name: String, seconds: Double, aborted: Bool, errors: Int) -> RemoteNotification.Message {
        RemoteNotification.message(jobName: name, seconds: seconds, aborted: aborted, errors: errors, includeName: remoteIncludeName,
                                   duration: GCodeProgram.formatDuration(seconds), finishedTitle: L("Job finished"), stoppedTitle: L("Job stopped"),
                                   errorsText: L("%d errors", errors))
    }

    /// After a job: a push message when it ran long enough.
    func sendRemoteNotification(name: String, seconds: Double, aborted: Bool, errors: Int) {
        guard remoteEnabled, !remoteAddress.isEmpty, RemoteNotification.shouldSend(seconds: seconds, minMinutes: remoteMinMinutes) else { return }
        RemoteSender.send(remoteMessage(name: name, seconds: seconds, aborted: aborted, errors: errors), to: remoteAddress) { [weak self] error in
            if let e = error { self?.controller.noteExternal(L("Push message failed: %@", e)) }
        }
    }

    func sendRemoteTest() {
        let m = RemoteNotification.Message(title: "LaserCraft", body: L("This is a test message."), failed: false)
        RemoteSender.send(m, to: remoteAddress) { [weak self] error in
            self?.presentInfo(title: L("Push message"), message: error.map { L("Could not send: %@", $0) } ?? L("The test message was sent."))
        }
    }

    // MARK: Dock

    func startDockProgress() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, self.controller.jobRunning else { return }
            self.dock.update(progress: self.controller.jobProgress, remaining: self.controller.remainingSeconds)
        }
        dock.update(progress: 0, remaining: controller.program?.estimatedSeconds)
    }

    func stopDockProgress() {
        progressTimer?.invalidate(); progressTimer = nil
        dock.update(progress: nil, remaining: nil)
    }
}

// MARK: - job history

enum ThumbnailRenderer {
    /// A small picture of what the job burns (PNG).
    static func png(for program: GCodeProgram, size: CGSize = CGSize(width: 192, height: 144)) -> Data? {
        let b = program.burnBounds
        guard !b.isEmpty, b.width > 0 || b.height > 0 else { return nil }
        let w = Int(size.width), h = Int(size.height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        let m = 8.0
        let s = min((Double(w) - 2 * m) / max(b.width, 0.001), (Double(h) - 2 * m) / max(b.height, 0.001))
        let ox = (Double(w) - b.width * s) / 2, oy = (Double(h) - b.height * s) / 2
        let path = NSBezierPath()
        path.lineWidth = 0.8
        var last: (Float, Float)?
        for seg in program.segments where seg.power > 0 {
            let a = (Float(ox) + (seg.x0 - Float(b.minX)) * Float(s), Float(oy) + (seg.y0 - Float(b.minY)) * Float(s))
            let c = (Float(ox) + (seg.x1 - Float(b.minX)) * Float(s), Float(oy) + (seg.y1 - Float(b.minY)) * Float(s))
            if last == nil || abs(last!.0 - a.0) > 0.01 || abs(last!.1 - a.1) > 0.01 { path.move(to: NSPoint(x: Double(a.0), y: Double(a.1))) }
            path.line(to: NSPoint(x: Double(c.0), y: Double(c.1)))
            last = c
        }
        NSColor.black.setStroke(); path.stroke()
        return rep.representation(using: .png, properties: [:])
    }
}

extension AppModel {
    /// Remembers a finished or stopped job (with a copy of its G-code) so that it can be opened again.
    func recordHistory(aborted: Bool, errors: Int, seconds: Double, name: String) {
        guard let p = controller.program else { return }
        let machine = selectedPort == AppModel.simulatorPort ? L("Simulator (demo machine)") : (activeProfile?.name ?? portName(selectedPort))
        let outcome: UsageEntry.Outcome = aborted ? (errors > 0 ? .failed : .stopped) : .finished
        let rec = JobRecord(name: name, seconds: seconds, outcome: outcome, machine: machine, lines: p.commands.count, errors: errors)
        history.add(rec, gcode: p.text, thumbnail: ThumbnailRenderer.png(for: p))
        objectWillChange.send()
    }

    func reopen(_ record: JobRecord) {
        guard !controller.jobRunning else { alertMessage = L("Stop the running job first."); return }
        guard let text = history.gcode(for: record.id) else { alertMessage = L("The G-code of this job is no longer stored."); return }
        setProgram(GCodeProgram(text: text, name: record.name, rapidRate: rapidRate))
        mainMode = .job
    }
}

// MARK: - save dialog

final class SaveOptionsModel: ObservableObject {
    @Published var options: SaveOptions {
        didSet { if let d = try? JSONEncoder().encode(options) { UserDefaults.standard.set(d, forKey: "saveOptions") } }
    }
    init(passes: Int) {
        var o = SaveOptions()
        if let d = UserDefaults.standard.data(forKey: "saveOptions"), let saved = try? JSONDecoder().decode(SaveOptions.self, from: d) { o = saved }
        o.passes = passes                                           // the number of passes follows the job setting
        options = o
    }
}
