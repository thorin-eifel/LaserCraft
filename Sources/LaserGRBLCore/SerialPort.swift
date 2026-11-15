import Foundation
import Darwin

public enum SerialError: Error, LocalizedError {
    case openFailed(String, Int32)
    case configureFailed(Int32)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let code): return "Cannot open \(path): \(String(cString: strerror(code)))"
        case .configureFailed(let code): return "Cannot configure the port: \(String(cString: strerror(code)))"
        case .notOpen: return "The port is not open"
        }
    }
}

/// Minimal POSIX serial port (8N1, raw) with a dispatch-source reader.
public final class SerialPort {
    public private(set) var path: String
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "lasergrbl.serial")

    /// Called on the main queue with received bytes.
    public var onData: ((Data) -> Void)?
    /// Called on the main queue when the device disappears or reading fails.
    public var onClose: (() -> Void)?

    public init(path: String) { self.path = path }
    deinit { shutdown() }

    public var isOpen: Bool { fd >= 0 }

    /// Lists callout devices that look like USB/serial adapters.
    public static func availablePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth-Incoming") && !$0.contains("debug-console") }
            .map { "/dev/" + $0 }
            .sorted()
    }

    public func open(baud: Int) throws {
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if f < 0 { throw SerialError.openFailed(path, errno) }

        var tio = termios()
        if tcgetattr(f, &tio) != 0 { let e = errno; Darwin.close(f); throw SerialError.configureFailed(e) }
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        tio.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        cfsetspeed(&tio, speed_t(baud))
        if tcsetattr(f, TCSANOW, &tio) != 0 { let e = errno; Darwin.close(f); throw SerialError.configureFailed(e) }
        tcflush(f, TCIOFLUSH)

        fd = f
        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable(f) }
        src.setCancelHandler { Darwin.close(f) }
        readSource = src
        src.resume()
    }

    private func readAvailable(_ f: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(f, &buf, buf.count)
        if n > 0 {
            let data = Data(buf[0..<n])
            DispatchQueue.main.async { [weak self] in self?.onData?(data) }
        } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
            // device unplugged / hung up
            readSource?.cancel()
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.fd >= 0 else { return }
                self.fd = -1
                self.readSource = nil
                self.onClose?()
            }
        }
    }

    public func write(_ data: Data) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        let bytes = [UInt8](data)
        var offset = 0
        var spins = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 { offset += n; spins = 0 }
            else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                spins += 1
                if spins > 2000 { throw SerialError.notOpen }
                usleep(1000)
            } else { throw SerialError.notOpen }
        }
    }

    public func write(_ string: String) throws { try write(Data(string.utf8)) }
    public func write(byte: UInt8) throws { try write(Data([byte])) }

    private func shutdown() {
        if let src = readSource {
            readSource = nil
            fd = -1
            src.cancel()          // cancel handler closes the descriptor
        }
    }

    public func close() { shutdown() }
}
