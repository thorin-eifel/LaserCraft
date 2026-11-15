import XCTest
import Darwin
@testable import LaserGRBLCore

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

final class ControllerTests: XCTestCase {
    var grbl: FakeGrbl!
    var ctl: GrblController!

    override func setUp() {
        grbl = FakeGrbl(); grbl.start()
        ctl = GrblController()
    }

    override func tearDown() {
        ctl.disconnect()
        grbl.shutdown()
    }

    @discardableResult
    func wait(_ seconds: TimeInterval = 5, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return cond()
    }

    func testConnectReadsSettingsAndStatus() {
        ctl.connect(path: grbl.slavePath, baud: 115200)
        XCTAssertEqual(ctl.state, .connecting)
        XCTAssertTrue(wait { ctl.state == .idle })
        XCTAssertTrue(wait { ctl.settings[30] == "1000" }, "settings: \(ctl.settings)")
        XCTAssertEqual(ctl.settings[130], "400")
        XCTAssertTrue(wait { ctl.version != nil })
        XCTAssertTrue(wait { ctl.buffer != nil })
    }

    func testJobStreamsWithoutOverflowingTheBuffer() {
        ctl.connect(path: grbl.slavePath, baud: 115200)
        XCTAssertTrue(wait { ctl.state == .idle && ctl.settings[30] != nil })

        var text = ""
        for i in 0..<300 { text += "G1 X\(i).123 Y\(i % 7).456 F1000 S\(i)\n" }
        ctl.load(GCodeProgram(text: text, name: "test"))
        XCTAssertTrue(ctl.canStartJob)
        ctl.startJob()
        XCTAssertTrue(ctl.jobRunning)
        XCTAssertTrue(wait(30) { !ctl.jobRunning }, "executed \(ctl.jobExecuted)/\(ctl.jobTarget)")
        XCTAssertEqual(grbl.overflowViolations, 0, "max unacked \(grbl.maxUnacked)")
        XCTAssertGreaterThan(grbl.maxUnacked, 40, "streaming should keep the buffer filled")
        XCTAssertEqual(ctl.jobErrors, 0)
        XCTAssertEqual(ctl.jobExecuted, ctl.jobTarget)
        let lines = grbl.lines
        XCTAssertEqual(lines.first(where: { !$0.hasPrefix("$") }), "G90")
        XCTAssertEqual(lines.last, "G0X0Y0")
        XCTAssertTrue(lines.contains("G1X299.123Y5.456F1000S299"))
        XCTAssertEqual(ctl.jobProgress, 1, accuracy: 0.0001)
    }

    func testErrorsAreCountedAndExplained() {
        ctl.connect(path: grbl.slavePath, baud: 115200)
        XCTAssertTrue(wait { ctl.state == .idle })
        ctl.load(GCodeProgram(text: "G1 X1 F100\nBAD\nG1 X2"))
        ctl.startJob()
        XCTAssertTrue(wait { !ctl.jobRunning })
        XCTAssertEqual(ctl.jobErrors, 1)
        XCTAssertTrue(ctl.console.contains { $0.kind == .error && $0.text.contains("error:20") })
    }

    func testEventsForSoundsAlertsAndNotifications() {
        ctl.connect(path: grbl.slavePath, baud: 115200)
        XCTAssertTrue(wait { ctl.state == .idle })
        var events: [String] = []
        ctl.onEvent = { e in
            switch e {
            case .jobStarted: events.append("started")
            case .lineError(let m, let line): events.append("error:\(line)"); XCTAssertTrue(m.contains("error:20"))
            case .jobFinished(let aborted, let errors, _, let name): events.append("finished:\(aborted):\(errors):\(name)")
            default: events.append("other")
            }
        }
        ctl.load(GCodeProgram(text: "G1 X1 F100\nBAD\nG1 X2", name: "demo.nc"))
        ctl.startJob()
        XCTAssertTrue(wait { !ctl.jobRunning })
        XCTAssertEqual(events, ["started", "error:BAD", "finished:false:1:demo.nc"])
    }

    func testJogAndRealtimeCommands() {
        ctl.connect(path: grbl.slavePath, baud: 115200)
        XCTAssertTrue(wait { ctl.state == .idle })
        ctl.jog(.e, step: 10, feed: 1500)
        ctl.jog(.sw, step: 1, feed: 1500)
        XCTAssertTrue(wait { grbl.lines.contains("$J=G91X-1.0Y-1.0F1500") })
        XCTAssertTrue(grbl.lines.contains("$J=G91X10.0F1500"))
        ctl.feedHold()
        XCTAssertTrue(wait { ctl.state == .hold || ctl.state == .autoHold })
        XCTAssertTrue(grbl.rt.contains(0x21))
        ctl.resume()
        XCTAssertTrue(wait { ctl.state == .idle })
        ctl.cancelJog()
        XCTAssertTrue(wait { grbl.rt.contains(0x85) })
    }

    func testOverridesStepTowardsTarget() {
        ctl.connect(path: grbl.slavePath, baud: 115200)
        XCTAssertTrue(wait { ctl.state == .idle })
        ctl.setOverrides(feed: 123, spindle: 80)
        XCTAssertTrue(wait(8) { ctl.overrideFeed == 123 && ctl.overrideSpindle == 80 }, "\(ctl.overrideFeed) \(ctl.overrideSpindle)")
        ctl.setOverrides(feed: 100, spindle: 100)
        XCTAssertTrue(wait(8) { ctl.overrideFeed == 100 && ctl.overrideSpindle == 100 })
    }

    func testAbortStopsAndResets() {
        ctl.connect(path: grbl.slavePath, baud: 115200)
        XCTAssertTrue(wait { ctl.state == .idle && ctl.settings[30] != nil })
        grbl.lineDelay = 20_000
        var text = ""
        for i in 0..<500 { text += "G1 X\(i) F1000 S100\n" }
        ctl.load(GCodeProgram(text: text))
        ctl.startJob()
        XCTAssertTrue(wait { ctl.jobExecuted > 5 })
        ctl.abortJob()
        XCTAssertFalse(ctl.jobRunning)
        XCTAssertTrue(wait { grbl.rt.contains(0x21) && grbl.rt.contains(0x18) })
        XCTAssertLessThan(grbl.lines.count, 500)
        XCTAssertTrue(wait { ctl.state == .idle })
    }

    func testFrameCommandsUseBurnBounds() {
        ctl.load(GCodeProgram(text: "G0 X5 Y5\nM3\nG1 X15 Y5 F100 S100\nG1 X15 Y25"))
        let f = ctl.frameCommands()!
        XCTAssertTrue(f.contains("G0 X5.000 Y5.000"))
        XCTAssertTrue(f.contains("G1 X15.000 Y25.000"))
    }

    func testConnectionEventsForSounds() {
        var events: [String] = []
        ctl.onEvent = { e in
            switch e {
            case .connected: events.append("connected")
            case .connectionFailed: events.append("failed")
            default: break
            }
        }
        ctl.connect(path: "/dev/cu.does-not-exist", baud: 115200)
        XCTAssertEqual(events, ["failed"])
        ctl.connect(path: grbl.slavePath, baud: 115200)
        XCTAssertTrue(wait { ctl.state == .idle })
        XCTAssertEqual(events, ["failed", "connected"])
    }

    func testConnectToMissingPortLogsError() {
        ctl.connect(path: "/dev/cu.does-not-exist", baud: 115200)
        XCTAssertEqual(ctl.state, .disconnected)
        XCTAssertTrue(ctl.console.contains { $0.kind == .error })
    }
}
