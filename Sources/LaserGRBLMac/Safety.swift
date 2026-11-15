import AppKit
import LaserGRBLCore

/// Drives the countdown and the check box of the safety alert: the confirm button is only released when the
/// countdown is over AND the person ticked the box. Every second a tick sound is played.
final class SafetyState: NSObject {
    let confirmButton: NSButton
    let baseTitle: String
    var remaining: Int
    var boxTicked = false
    weak var checkBox: NSButton?
    var timer: Timer?

    init(confirmButton: NSButton, baseTitle: String, seconds: Int) {
        self.confirmButton = confirmButton
        self.baseTitle = baseTitle
        self.remaining = seconds
        super.init()
        refresh()
    }

    func start() {
        Sounds.play(.tick)
        // `.common` keeps the timer running while the alert is modal
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard remaining > 0 else { return }
        remaining -= 1
        if remaining == 0 { Sounds.play(.go); stop() } else { Sounds.play(.tick) }
        refresh()
    }

    @objc func toggled(_ sender: NSButton) {
        boxTicked = sender.state == .on
        refresh()
    }

    func refresh() {
        confirmButton.title = remaining > 0 ? "\(baseTitle) (\(remaining))" : baseTitle
        confirmButton.isEnabled = remaining == 0 && boxTicked
    }
}

enum LaserSafety {
    /// Seconds the warning stays up before the confirm button can be used.
    static let countdownSeconds = 5

    /// True when the lines would switch the laser on (M3 / M4).
    static func firesLaser(_ gcode: String) -> Bool {
        gcode.range(of: #"(?i)(^|[^A-Za-z0-9.])M0?[34]($|[^0-9])"#, options: .regularExpression) != nil
    }

    /// Builds the warning (not yet shown) and the object that drives its countdown and check box.
    static func makeAlert(title: String, confirmButton: String, extra: String? = nil) -> (NSAlert, SafetyState) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        var text = L("Laser light can permanently damage your eyes and can start fires. Before you continue:") + "\n\n"
            + "• " + L("Wear laser safety glasses that match your laser's wavelength.") + "\n"
            + "• " + L("Make sure everyone nearby is protected, or that the machine is enclosed.") + "\n"
            + "• " + L("Check that the material is safe to burn and nothing flammable is close.") + "\n"
            + "• " + L("Stay at the machine and keep a fire extinguisher within reach.")
        if let extra = extra { text += "\n\n" + extra }
        alert.informativeText = text

        let start = alert.addButton(withTitle: confirmButton)
        alert.addButton(withTitle: L("Cancel"))
        let state = SafetyState(confirmButton: start, baseTitle: confirmButton, seconds: countdownSeconds)
        let box = NSButton(checkboxWithTitle: L("I am wearing laser safety glasses."), target: state, action: #selector(SafetyState.toggled(_:)))
        box.setAccessibilityLabel(L("I am wearing laser safety glasses."))
        box.sizeToFit()
        state.checkBox = box
        alert.accessoryView = box
        alert.window.initialFirstResponder = box
        return (alert, state)
    }

    /// Modal eye-protection check with a sound countdown. Returns true only when the countdown is over, the person
    /// ticked the box and pressed the confirm button.
    static func confirm(title: String, confirmButton: String, extra: String? = nil) -> Bool {
        let (alert, state) = makeAlert(title: title, confirmButton: confirmButton, extra: extra)
        state.start()
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        state.stop()
        return confirmed
    }
}
