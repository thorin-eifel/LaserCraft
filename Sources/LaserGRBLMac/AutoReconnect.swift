import Foundation

/// Tries to get the connection back after the USB cable was jiggled (never during a job).
/// Every `interval` seconds it looks whether the port is there again and asks to connect; it gives up after `maxAttempts`.
final class AutoReconnect {
    var isPortAvailable: (String) -> Bool = { _ in false }
    var connect: (String) -> Void = { _ in }
    var onGiveUp: () -> Void = {}

    let interval: TimeInterval
    let maxAttempts: Int
    private var timer: Timer?
    private(set) var attempts = 0

    init(interval: TimeInterval = 2, maxAttempts: Int = 30) {
        self.interval = interval
        self.maxAttempts = maxAttempts
    }

    var isActive: Bool { timer != nil }

    func start(port: String) {
        stop()
        attempts = 0
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.attempts += 1
            if self.isPortAvailable(port) { self.connect(port) }
            if self.attempts >= self.maxAttempts { self.stop(); self.onGiveUp() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    deinit { stop() }
}
