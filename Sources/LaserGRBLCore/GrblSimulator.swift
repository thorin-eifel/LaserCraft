import Foundation
import Darwin

/// A Grbl 1.1 look-alike for trying LaserCraft without a laser ("Simulator" in the port list) and for tests.
///
/// It lives on the master side of a pseudo terminal; the app connects to `slavePath` like to any USB serial port.
/// It answers `?`, `$$`, `$I`, `$J=…`, jogs, real-time overrides, hold / resume / reset, G-code moves (the head
/// really travels at the programmed feed rate, `speedFactor` times faster) and a planner buffer of 15 blocks,
/// so progress, buffer fill, position and overrides in the app behave like on a machine. Like many diode lasers it has no
/// homing switches: `$H` answers `error:5`.
public final class GrblSimulator {
    /// 1 = real speed. The demo uses a faster value so a job does not take minutes.
    public var speedFactor: Double
    public private(set) var slavePath = ""

    // pseudo terminal
    private var master: Int32 = -1
    private var slave: Int32 = -1
    private var thread: Thread?
    private let lock = NSLock()
    private var stopFlag = false

    // machine state (touched only by the simulator thread)
    private struct Block { var from: (Double, Double); var to: (Double, Double); var feed: Double; var rapid: Bool; var power: Double; var jog: Bool }
    private var pos = (x: 0.0, y: 0.0, z: 0.0)
    private var wco = (x: 0.0, y: 0.0, z: 0.0)
    private var queue: [Block] = []
    private var progress = 0.0            // 0...1 through queue[0]
    private var hold = false
    private var alarm = false
    private var modalMotion = 0
    private var feed = 1000.0, spindle = 0.0, laserOn = false, absolute = true, inches = false
    private var overrides = (feed: 100, rapid: 100, spindle: 100)
    private var pending: [String] = []    // lines received but not yet taken by the planner
    private var rxUsed: [Int] = []        // bytes of lines the planner has not finished yet
    private var settings: [Int: String] = [
        0: "10", 1: "25", 2: "0", 3: "0", 4: "0", 5: "0", 6: "0", 10: "1", 11: "0.010", 12: "0.002", 13: "0",
        20: "0", 21: "0", 22: "0", 23: "0", 24: "25.000", 25: "500.000", 26: "250", 27: "1.000",
        30: "1000", 31: "0", 32: "1", 100: "80.000", 101: "80.000", 102: "250.000",
        110: "3000.000", 111: "3000.000", 112: "500.000", 120: "200.000", 121: "200.000", 122: "10.000",
        130: "400.000", 131: "400.000", 132: "200.000",
    ]
    private let rapidRate = 3000.0

    public init(speedFactor: Double = 4) { self.speedFactor = speedFactor }
    deinit { stop() }

    public var isRunning: Bool { thread != nil }

    /// Creates the pseudo terminal and starts the simulator thread. Returns the device path to connect to.
    @discardableResult
    public func start() -> String? {
        guard thread == nil else { return slavePath }
        var m: Int32 = 0, s: Int32 = 0
        guard openpty(&m, &s, nil, nil, nil) == 0 else { return nil }
        master = m; slave = s
        slavePath = String(cString: ttyname(s))
        var tio = termios()
        tcgetattr(m, &tio); cfmakeraw(&tio); tcsetattr(m, TCSANOW, &tio)
        stopFlag = false
        let t = Thread { [unowned self] in self.run() }
        t.name = "GrblSimulator"
        t.start()
        thread = t
        return slavePath
    }

    public func stop() {
        guard thread != nil else { return }
        lock.lock(); stopFlag = true; lock.unlock()
        Thread.sleep(forTimeInterval: 0.06)
        Darwin.close(master); Darwin.close(slave)
        master = -1; slave = -1
        thread = nil
    }

    // MARK: thread

    private func send(_ text: String) {
        guard master >= 0 else { return }
        _ = text.withCString { Darwin.write(master, $0, strlen($0)) }
    }

    private func run() {
        var acc = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 512)
        var last = Date()
        while true {
            lock.lock(); let done = stopFlag; lock.unlock()
            if done { return }
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 5) > 0 {
                let n = Darwin.read(master, &buf, buf.count)
                if n > 0 { for b in buf[0..<n] { handle(byte: b, acc: &acc) } }
            }
            let now = Date()
            advance(now.timeIntervalSince(last))
            last = now
            drainPending()
        }
    }

    private func handle(byte b: UInt8, acc: inout [UInt8]) {
        switch b {
        case 0x3F: sendStatus()
        case 0x18: reset()
        case 0x21: hold = true
        case 0x7E: hold = false
        case 0x85: queue.removeAll { $0.jog }; progress = 0
        case 0x90: overrides.feed = 100
        case 0x91: overrides.feed = min(200, overrides.feed + 10)
        case 0x92: overrides.feed = max(10, overrides.feed - 10)
        case 0x93: overrides.feed = min(200, overrides.feed + 1)
        case 0x94: overrides.feed = max(10, overrides.feed - 1)
        case 0x95: overrides.rapid = 100
        case 0x96: overrides.rapid = 50
        case 0x97: overrides.rapid = 25
        case 0x99: overrides.spindle = 100
        case 0x9A: overrides.spindle = min(200, overrides.spindle + 10)
        case 0x9B: overrides.spindle = max(10, overrides.spindle - 10)
        case 0x9C: overrides.spindle = min(200, overrides.spindle + 1)
        case 0x9D: overrides.spindle = max(10, overrides.spindle - 1)
        case 0x0A:
            let line = String(decoding: acc, as: UTF8.self)
            rxUsed.append(acc.count + 1)
            acc.removeAll()
            pending.append(line)
        case 0x0D: break
        default: acc.append(b)
        }
    }

    private func reset() {
        queue.removeAll(); pending.removeAll(); rxUsed.removeAll(); progress = 0
        hold = false; alarm = false; laserOn = false; spindle = 0
        overrides = (100, 100, 100)
        send("\r\nGrbl 1.1h ['$' for help]\r\n")
    }

    private func sendStatus() {
        let state: String
        if alarm { state = "Alarm" }
        else if hold { state = "Hold:0" }
        else if !queue.isEmpty { state = queue[0].jog ? "Jog" : "Run" }
        else { state = "Idle" }
        let free = max(0, 15 - queue.count)
        let rx = max(0, 127 - rxUsed.reduce(0, +))
        let power = laserOn ? spindle * Double(overrides.spindle) / 100 : 0
        let f = queue.first.map { $0.rapid ? rapidRate : $0.feed * Double(overrides.feed) / 100 } ?? 0
        send(String(format: "<%@|MPos:%.3f,%.3f,%.3f|Bf:%d,%d|FS:%d,%d|WCO:%.3f,%.3f,%.3f|Ov:%d,%d,%d>\r\n",
                    state, pos.x, pos.y, pos.z, free, rx, Int(f), Int(power), wco.x, wco.y, wco.z,
                    overrides.feed, overrides.rapid, overrides.spindle))
    }

    // MARK: motion

    private func advance(_ dt: Double) {
        guard !hold, !alarm, dt > 0, !queue.isEmpty else { return }
        var budget = dt * speedFactor
        while budget > 0, !queue.isEmpty {
            let b = queue[0]
            let len = hypot(b.to.0 - b.from.0, b.to.1 - b.from.1)
            let rate = (b.rapid ? rapidRate * Double(overrides.rapid) / 100 : b.feed * Double(overrides.feed) / 100) / 60   // mm/s
            if len < 0.0001 || rate <= 0 { queue.removeFirst(); progress = 0; continue }
            let duration = len / rate
            let remaining = (1 - progress) * duration
            if budget >= remaining {
                budget -= remaining
                pos.x = b.to.0; pos.y = b.to.1
                queue.removeFirst(); progress = 0
            } else {
                progress += budget / duration
                pos.x = b.from.0 + (b.to.0 - b.from.0) * progress
                pos.y = b.from.1 + (b.to.1 - b.from.1) * progress
                budget = 0
            }
        }
    }

    /// The planner buffer holds 15 blocks; a line is acknowledged ("ok") as soon as it fits, like Grbl does.
    private func drainPending() {
        while let line = pending.first {
            let clean = line.trimmingCharacters(in: .whitespaces).uppercased()
            let isMotion = clean.contains("X") || clean.contains("Y") || clean.hasPrefix("$J=")
            if isMotion && queue.count >= 15 { return }
            pending.removeFirst()
            execute(clean)
        }
    }

    private func ack(_ text: String = "ok") {
        if !rxUsed.isEmpty { rxUsed.removeFirst() }
        send(text + "\r\n")
    }

    // MARK: lines

    private func words(_ line: String) -> [(Character, Double)] {
        var out: [(Character, Double)] = []
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]; i = line.index(after: i)
            guard c.isLetter else { continue }
            var j = i
            while j < line.endIndex, "+-.0123456789".contains(line[j]) { j = line.index(after: j) }
            if let v = Double(line[i..<j]) { out.append((c, v)) }
            i = j
        }
        return out
    }

    private func execute(_ lineIn: String) {
        let line = GrblParser.cleanLine(lineIn).uppercased()
        if line.isEmpty { ack(); return }
        if line == "$$" {
            for k in settings.keys.sorted() { send("$\(k)=\(settings[k] ?? "")\r\n") }
            ack(); return
        }
        if line == "$I" { send("[VER:1.1h.20190825:LaserCraft simulator]\r\n[OPT:V,15,128]\r\n"); ack(); return }
        if line == "$H" { ack("error:5"); return }
        if line == "$X" { alarm = false; send("[MSG:Caution: Unlocked]\r\n"); ack(); return }
        if line.hasPrefix("$J=") { jog(String(line.dropFirst(3))); return }
        if line.hasPrefix("$"), let eq = line.firstIndex(of: "="), let n = Int(line[line.index(after: line.startIndex)..<eq]) {
            settings[n] = String(line[line.index(after: eq)...]); ack(); return
        }
        if line.hasPrefix("$") { ack("error:3"); return }
        if alarm { ack("error:9"); return }
        gcode(line)
    }

    private func jog(_ body: String) {
        var abs = false
        var tx = pos.x - wco.x, ty = pos.y - wco.y
        var f = 1000.0
        var rel = false
        let ws = words(body)
        for (c, v) in ws where c == "G" { if Int(v) == 90 { abs = true } else if Int(v) == 91 { rel = true } }
        for (c, v) in ws {
            switch c {
            case "X": tx = abs ? v : (rel ? tx + v : v)
            case "Y": ty = abs ? v : (rel ? ty + v : v)
            case "F": f = v
            default: break
            }
        }
        if body.range(of: "G9[01]", options: .regularExpression) == nil { ack("error:16"); return }
        let tmx = tx + wco.x, tmy = ty + wco.y
        queue.append(Block(from: (pos.x, pos.y), to: (tmx, tmy), feed: f, rapid: false, power: 0, jog: true))
        ack()
    }

    private func gcode(_ line: String) {
        var motion = -1
        var nx: Double?, ny: Double?, ni = 0.0, nj = 0.0
        var dwell: Double?
        var setWCO = false
        for (c, v) in words(line) {
            switch c {
            case "G":
                switch Int(v) {
                case 0, 1, 2, 3: motion = Int(v)
                case 4: dwell = 0
                case 20: inches = true
                case 21: inches = false
                case 90: absolute = true
                case 91: absolute = false
                case 92: setWCO = true
                default: break
                }
            case "M": if Int(v) == 3 || Int(v) == 4 { laserOn = true } else if Int(v) == 5 { laserOn = false }
            case "S": spindle = v
            case "F": feed = v * (inches ? 25.4 : 1)
            case "X": nx = v
            case "Y": ny = v
            case "I": ni = v
            case "J": nj = v
            case "P": if dwell != nil { dwell = v }
            default: break
            }
        }
        if setWCO {
            // G92 X0 Y0: the current position becomes (X, Y) in work coordinates
            if let x = nx { wco.x = pos.x - x }
            if let y = ny { wco.y = pos.y - y }
            ack(); return
        }
        if motion >= 0 { modalMotion = motion }
        if nx != nil || ny != nil {
            let k = inches ? 25.4 : 1.0
            // the last queued block's end is where this move starts
            let start = queue.last?.to ?? (pos.x, pos.y)
            let sx = start.0 - wco.x, sy = start.1 - wco.y
            let tx = nx.map { absolute ? $0 * k : sx + $0 * k } ?? sx
            let ty = ny.map { absolute ? $0 * k : sy + $0 * k } ?? sy
            let m = modalMotion
            let rapid = m == 0
            let power = (laserOn && !rapid) ? spindle : 0
            if m >= 2 {
                let pts = GCodeProgram.arc(from: (sx, sy), to: (tx, ty), i: ni * k, j: nj * k, r: nil, clockwise: m == 2)
                var prev = (sx, sy)
                for p in pts {
                    queue.append(Block(from: (prev.0 + wco.x, prev.1 + wco.y), to: (p.0 + wco.x, p.1 + wco.y), feed: feed, rapid: false, power: power, jog: false))
                    prev = p
                }
            } else {
                queue.append(Block(from: start, to: (tx + wco.x, ty + wco.y), feed: feed, rapid: rapid, power: power, jog: false))
            }
        }
        ack()
    }
}
