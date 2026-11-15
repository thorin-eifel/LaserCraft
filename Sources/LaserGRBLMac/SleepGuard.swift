import Foundation
import AppKit

/// Keeps the Mac from going to sleep (and App Nap from slowing the app down) while a job is running.
/// Before and after the job the Mac sleeps as usual. A MacBook still sleeps when its lid is closed.
final class SleepGuard {
    static let reason = "LaserCraft is running a laser job"

    private var token: NSObjectProtocol?

    var isActive: Bool { token != nil }

    /// Starts the "stay awake" assertion. `keepDisplayOn` also keeps the screen from dimming and turning off.
    func begin(keepDisplayOn: Bool = false) {
        guard token == nil else { return }
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled,
                                                    .suddenTerminationDisabled, .automaticTerminationDisabled]
        if keepDisplayOn { options.insert(.idleDisplaySleepDisabled) }
        token = ProcessInfo.processInfo.beginActivity(options: options, reason: SleepGuard.reason)
    }

    /// Ends the assertion; the Mac may sleep again.
    func end() {
        guard let t = token else { return }
        ProcessInfo.processInfo.endActivity(t)
        token = nil
    }

    deinit { end() }
}
