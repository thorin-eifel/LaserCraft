import XCTest
import Darwin

/// A tiny Grbl 1.1 look-alike living on the master side of a pseudo terminal.
final class FakeGrbl {
    let master: Int32
    let slavePath: String
    private var thread: Thread?
    private let lock = NSLock()
    private var stop = false

    // observations
    private(set) var receivedLines: [String] = []
    private(set) var realtime: [UInt8] = []
    private(set) var maxUnacked = 0
    private(set) var overflowViolations = 0
    var pos = (x: 0.0, y: 0.0)
    var state = "Idle"
    var ov = (100, 100, 100)
    var lineDelay: useconds_t = 1500

    init() {
        var m: Int32 = 0, s: Int32 = 0
        precondition(openpty(&m, &s, nil, nil, nil) == 0)
        master = m
        slavePath = String(cString: ttyname(s))
        // keep the slave open so the pty stays alive until the controller opens it
        slaveFD = s
        var tio = termios()
        tcgetattr(m, &tio); cfmakeraw(&tio); tcsetattr(m, TCSANOW, &tio)
    }
    private var slaveFD: Int32

    func start() {
        let t = Thread { [unowned self] in self.run() }
        t.start()
        thread = t
    }

    func shutdown() {
        lock.lock(); stop = true; lock.unlock()
        Thread.sleep(forTimeInterval: 0.05)
        Darwin.close(master); Darwin.close(slaveFD)
    }

    private func send(_ s: String) { _ = s.withCString { Darwin.write(master, $0, strlen($0)) } }

    private func run() {
        var acc = [UInt8]()
        var unacked: [Int] = []
        var todo: [String] = []
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            lock.lock(); let s = stop; lock.unlock()
            if s { return }
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            var n = 0
            if poll(&pfd, 1, todo.isEmpty ? 20 : 0) > 0 { n = Darwin.read(master, &buf, buf.count) }
            if n <= 0 && todo.isEmpty { continue }
            if n <= 0 { n = 0 }
            defer {
                if !todo.isEmpty {
                    usleep(lineDelay)
                    let line = todo.removeFirst()
                    reply(to: line)
                    if !unacked.isEmpty { unacked.removeFirst() }
                }
            }
            for b in buf[0..<n] {
                switch b {
                case 0x3F: // ?
                    send("<\(state)|MPos:\(String(format: "%.3f,%.3f", pos.x, pos.y)),0.000|Bf:15,127|FS:0,0|WCO:0.000,0.000,0.000|Ov:\(ov.0),\(ov.1),\(ov.2)>\r\n")
                case 0x18:
                    lock.lock(); realtime.append(b); lock.unlock()
                    unacked.removeAll(); acc.removeAll(); todo.removeAll()
                    ov = (100, 100, 100); state = "Idle"
                    send("\r\nGrbl 1.1h ['$' for help]\r\n")
                case 0x21, 0x7E, 0x85:
                    lock.lock(); realtime.append(b); lock.unlock()
                    if b == 0x21 { state = "Hold:0" } else if b == 0x7E { state = "Idle" }
                case 0x90: ov.0 = 100; rec(b)
                case 0x91: ov.0 += 10; rec(b)
                case 0x92: ov.0 -= 10; rec(b)
                case 0x93: ov.0 += 1; rec(b)
                case 0x94: ov.0 -= 1; rec(b)
                case 0x99: ov.2 = 100; rec(b)
                case 0x9A: ov.2 += 10; rec(b)
                case 0x9B: ov.2 -= 10; rec(b)
                case 0x9C: ov.2 += 1; rec(b)
                case 0x9D: ov.2 -= 1; rec(b)
                case 0x0A:
                    let line = String(decoding: acc, as: UTF8.self)
                    unacked.append(acc.count + 1)
                    acc.removeAll()
                    let total = unacked.reduce(0, +)
                    lock.lock()
                    maxUnacked = max(maxUnacked, total)
                    if total > 127 { overflowViolations += 1 }
                    receivedLines.append(line)
                    lock.unlock()
                    todo.append(line)
                case 0x0D: break
                default: acc.append(b)
                }
            }
        }
    }

    private func rec(_ b: UInt8) { lock.lock(); realtime.append(b); lock.unlock() }

    private func reply(to line: String) {
        if line == "$$" {
            send("$0=10\r\n$30=1000\r\n$32=1\r\n$130=400\r\n$131=400\r\nok\r\n")
        } else if line == "$I" {
            send("[VER:1.1h.20190825:]\r\n[OPT:V,15,128]\r\nok\r\n")
        } else if line.hasPrefix("G0") || line.hasPrefix("G1") {
            for part in line.split(whereSeparator: { "GM".contains($0) }) { _ = part }
            var i = line.startIndex
            while i < line.endIndex {
                let c = line[i]
                if c == "X" || c == "Y" {
                    var j = line.index(after: i)
                    while j < line.endIndex, "+-.0123456789".contains(line[j]) { j = line.index(after: j) }
                    if let v = Double(line[line.index(after: i)..<j]) { if c == "X" { pos.x = v } else { pos.y = v } }
                    i = j
                } else { i = line.index(after: i) }
            }
            send("ok\r\n")
        } else if line.contains("BAD") {
            send("error:20\r\n")
        } else {
            send("ok\r\n")
        }
    }

    var lines: [String] { lock.lock(); defer { lock.unlock() }; return receivedLines }
    var rt: [UInt8] { lock.lock(); defer { lock.unlock() }; return realtime }
}

