import XCTest
@testable import LaserGRBLCore

final class HotkeyTests: XCTestCase {
    func testDefaultsAndLookup() {
        let m = HotkeyMap.defaults
        XCTAssertEqual(m.action(for: KeyCombo("left")), .jogLeft)
        XCTAssertEqual(m.action(for: KeyCombo("left", .option)), .bigLeft)
        XCTAssertEqual(m.action(for: KeyCombo("up", .control)), .powerUp)
        XCTAssertEqual(m.action(for: KeyCombo("3", .control)), .button3)
        XCTAssertEqual(HotkeyAction.button3.buttonIndex, 2)
        XCTAssertEqual(m.action(for: KeyCombo("[")), .speedDown)
        XCTAssertNil(m.action(for: KeyCombo("q")))
        XCTAssertEqual(HotkeyAction.jogLeft.direction, .w)
        XCTAssertTrue(HotkeyAction.bigUp.isBigStep); XCTAssertFalse(HotkeyAction.jogUp.isBigStep)
        XCTAssertTrue(HotkeyAction.zUp.isJog); XCTAssertFalse(HotkeyAction.stepUp.isJog)
        // no two actions share a key by default
        XCTAssertEqual(Set(m.bindings.values).count, m.bindings.count)
    }

    func testConflictsAreDetectedAndCanBeResolved() {
        var m = HotkeyMap.defaults
        XCTAssertEqual(m.set(KeyCombo("left"), for: .jogUpLeft), .jogLeft, "refused: taken by Jog left")
        XCTAssertNil(m.combo(for: .jogUpLeft))
        XCTAssertNil(m.set(KeyCombo("q"), for: .jogUpLeft))
        XCTAssertEqual(m.combo(for: .jogUpLeft), KeyCombo("q"))
        XCTAssertEqual(m.set(KeyCombo("left"), for: .jogUpRight, steal: true), .jogLeft)
        XCTAssertNil(m.combo(for: .jogLeft), "the other action lost its key")
        XCTAssertEqual(m.action(for: KeyCombo("left")), .jogUpRight)
        m.set(nil, for: .jogUpRight)
        XCTAssertNil(m.combo(for: .jogUpRight))
        m.reset()
        XCTAssertEqual(m, HotkeyMap.defaults)
    }

    func testSavingAndReadingBack() throws {
        var m = HotkeyMap.defaults
        m.set(KeyCombo("j", [.control, .shift]), for: .jogDownLeft)
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyMap.self, from: data), m)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("jogDownLeft"), "plain action names in the file")
    }

    func testKeyEventsBecomeCombos() {
        XCTAssertEqual(KeyCombo.make(characters: "", keyCode: 126, modifiers: .control), KeyCombo("up", .control))
        XCTAssertEqual(KeyCombo.make(characters: "+", keyCode: 24, modifiers: .shift), KeyCombo("+"), "shift is already in the character")
        XCTAssertEqual(KeyCombo.make(characters: "J", keyCode: 38, modifiers: .shift), KeyCombo("j", .shift), "shift counts for letters")
        XCTAssertEqual(KeyCombo.make(characters: "1", keyCode: 18, modifiers: .control), KeyCombo("1", .control))
        XCTAssertNil(KeyCombo.make(characters: "", keyCode: 200, modifiers: []))
        XCTAssertEqual(KeyCombo("up", [.control, .option]).display, "⌃⌥↑")
        XCTAssertEqual(KeyCombo("[").display, "[")
    }
}

final class RemoteTests: XCTestCase {
    let msg = RemoteNotification.Message(title: "Job finished", body: "0:12:30", failed: false)

    func testNtfyRequests() throws {
        let r = try XCTUnwrap(RemoteNotification.request(address: "ntfy://my-laser", message: msg))
        XCTAssertEqual(r.url?.absoluteString, "https://ntfy.sh/my-laser")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Title"), "Job finished")
        XCTAssertEqual(String(decoding: r.httpBody ?? Data(), as: UTF8.self), "0:12:30")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Priority"), "default")
        var bad = msg; bad.failed = true
        XCTAssertEqual(RemoteNotification.request(address: "https://ntfy.example.org/laser", message: bad)?.value(forHTTPHeaderField: "Priority"), "high")
    }

    func testGenericWebhookGetsJSON() throws {
        let r = try XCTUnwrap(RemoteNotification.request(address: " https://hooks.example.com/abc ", message: msg))
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r.httpBody)) as? [String: String])
        XCTAssertEqual(json["title"], "Job finished"); XCTAssertEqual(json["message"], "0:12:30")
        XCTAssertEqual(json["text"], "Job finished: 0:12:30")
    }

    func testUnusableAddressesAndMinimumDuration() {
        for a in ["", "   ", "ftp://x", "not a url", "https://", "file:///etc/passwd"] { XCTAssertNil(RemoteNotification.request(address: a, message: msg), a) }
        XCTAssertTrue(RemoteNotification.shouldSend(seconds: 600, minMinutes: 10))
        XCTAssertFalse(RemoteNotification.shouldSend(seconds: 599, minMinutes: 10))
        XCTAssertTrue(RemoteNotification.shouldSend(seconds: 1, minMinutes: 0))
    }

    func testMessageNeverContainsTheFileNameUnlessAsked() {
        let a = RemoteNotification.message(jobName: "secret-order.nc", seconds: 750, aborted: false, errors: 0, includeName: false, duration: "0:12:30",
                                           finishedTitle: "Job finished", stoppedTitle: "Job stopped", errorsText: "2 errors")
        XCTAssertFalse((a.title + a.body).contains("secret")); XCTAssertFalse(a.failed)
        let b = RemoteNotification.message(jobName: "secret-order.nc", seconds: 750, aborted: true, errors: 2, includeName: true, duration: "0:12:30",
                                           finishedTitle: "Job finished", stoppedTitle: "Job stopped", errorsText: "2 errors")
        XCTAssertEqual(b.title, "Job stopped"); XCTAssertEqual(b.body, "secret-order.nc · 0:12:30 · 2 errors"); XCTAssertTrue(b.failed)
    }

    func testDockLabel() {
        XCTAssertEqual(DockProgressText.label(progress: 0.634, remainingSeconds: 750), "63% · 13 min")
        XCTAssertEqual(DockProgressText.label(progress: 0.5, remainingSeconds: 30), "50%")
        XCTAssertEqual(DockProgressText.label(progress: 0.1, remainingSeconds: 3 * 3600), "10% · 3 h")
        XCTAssertEqual(DockProgressText.label(progress: 2, remainingSeconds: nil), "100%")
    }
}

final class HistoryAndSaveTests: XCTestCase {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("lc-hist-\(UUID().uuidString)") }

    func testHistoryKeepsTheLastJobsWithTheirGCode() throws {
        let dir = tmp()
        let h = JobHistoryStore(directory: dir, limit: 3)
        var ids: [String] = []
        for i in 0..<5 {
            let r = h.add(JobRecord(date: Date().addingTimeInterval(Double(i)), name: "job\(i).nc", seconds: 60, outcome: i == 1 ? .stopped : .finished, machine: "Ortur", lines: 10, errors: 0),
                          gcode: "G0 X\(i)", thumbnail: Data([1, 2, 3]))
            ids.append(r.id)
        }
        XCTAssertEqual(h.records.map { $0.name }, ["job4.nc", "job3.nc", "job2.nc"], "newest first, only the last three")
        XCTAssertEqual(h.gcode(for: ids[4]), "G0 X4")
        XCTAssertNil(h.gcode(for: ids[0]), "the files of dropped jobs are gone")
        XCTAssertEqual(h.thumbnail(for: ids[3]), Data([1, 2, 3]))
        XCTAssertTrue(h.records[0].hasGCode && h.records[0].hasThumbnail)
        let again = JobHistoryStore(directory: dir, limit: 3)
        XCTAssertEqual(again.records.map { $0.id }, h.records.map { $0.id })
        again.delete(id: ids[3])
        XCTAssertEqual(again.records.count, 2); XCTAssertNil(again.gcode(for: ids[3]))
        again.clear()
        XCTAssertTrue(JobHistoryStore(directory: dir).records.isEmpty)
    }

    func testSaveOptions() {
        let p = GCodeProgram(text: "G0 X1\nG1 X2 F100")
        var o = SaveOptions()
        XCTAssertEqual(GCodeExporter.text(program: p, header: "G21\nG90", footer: "M5", options: o), "G21\nG90\nG0X1\nG1X2F100\nM5\n")
        o.includeHeader = false; o.includeFooter = false; o.passes = 2
        XCTAssertEqual(GCodeExporter.text(program: p, header: "G21", footer: "M5", options: o), "G0X1\nG1X2F100\nG0X1\nG1X2F100\n")
        o.lineEnding = .crlf; o.passes = 1
        XCTAssertEqual(GCodeExporter.text(program: p, header: "", footer: "", options: o), "G0X1\r\nG1X2F100\r\n")
    }

    func testConsoleFilter() {
        let lines = [ConsoleLine(id: 1, text: "G0 X5", kind: .sent, date: Date()), ConsoleLine(id: 2, text: "ok", kind: .received, date: Date()),
                     ConsoleLine(id: 3, text: "error:20 Unsupported command", kind: .error, date: Date()), ConsoleLine(id: 4, text: "Connected", kind: .info, date: Date())]
        var f = ConsoleFilter()
        XCTAssertFalse(f.isActive); XCTAssertEqual(f.apply(lines).count, 4)
        f.sent = false; f.received = false; f.info = false
        XCTAssertEqual(f.apply(lines).map { $0.id }, [3], "errors only")
        f = ConsoleFilter(); f.search = "x5"
        XCTAssertEqual(f.apply(lines).map { $0.id }, [1])
        f.search = "UNSUPPORTED"
        XCTAssertEqual(f.apply(lines).map { $0.id }, [3], "search ignores case")
    }
}

final class SafetyAndJoggingTests: XCTestCase {
    var sim: GrblSimulator!
    var ctl: GrblController!

    override func setUp() { sim = GrblSimulator(speedFactor: 4); ctl = GrblController() }
    override func tearDown() { ctl.disconnect(); sim.stop() }

    @discardableResult
    func wait(_ seconds: TimeInterval = 10, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return cond()
    }

    func connect() throws {
        ctl.connect(path: try XCTUnwrap(sim.start()), baud: 115200)
        XCTAssertTrue(wait { ctl.state == .idle && ctl.settings[130] != nil && ctl.version != nil })
    }

    func testHoldingAKeyMovesTheHeadUntilItIsReleased() throws {
        try connect()
        ctl.beginContinuousJog(.e, feed: 6000)
        XCTAssertTrue(ctl.isContinuousJogging)
        XCTAssertTrue(wait { ctl.machinePosition.x > 60 }, "keeps going far beyond one step: x = \(ctl.machinePosition.x)")
        ctl.endContinuousJog()
        XCTAssertFalse(ctl.isContinuousJogging)
        wait(0.7) { false }                       // let the status reports catch up
        let stopped = ctl.machinePosition.x
        wait(0.7) { false }
        XCTAssertEqual(ctl.machinePosition.x, stopped, accuracy: 0.01, "nothing moves after the release")
        XCTAssertLessThan(stopped, 400, "stays inside the machine")
    }

    func testContinuousJogOnlyWhenIdle() throws {
        try connect()
        ctl.load(GCodeProgram(text: "G0 X5\nG1 X50 F100\nM5"))
        ctl.startJob()
        XCTAssertTrue(wait { ctl.jobRunning })
        ctl.beginContinuousJog(.n, feed: 3000)
        XCTAssertFalse(ctl.isContinuousJogging, "never while a job runs")
        ctl.abortJob()
    }

    func testEmergencyStopEndsAJobAtOnce() throws {
        try connect()
        var events: [String] = []
        ctl.onEvent = { if case .emergencyStopped = $0 { events.append("stop") }; if case .jobFinished(let aborted, _, _, _) = $0 { events.append(aborted ? "aborted" : "done") } }
        ctl.load(GCodeProgram(text: (0..<40).map { "G1 X\($0 * 5) Y\($0 * 3) F300" }.joined(separator: "\n") + "\nM5"))
        ctl.startJob()
        XCTAssertTrue(wait { ctl.jobExecuted > 3 })
        ctl.emergencyStop()
        XCTAssertFalse(ctl.jobRunning)
        XCTAssertTrue(events.contains("stop")); XCTAssertTrue(events.contains("aborted"))
        wait(0.7) { false }
        XCTAssertEqual(ctl.state, .idle, "state: \(ctl.state)")
        let x = ctl.machinePosition.x
        wait(0.7) { false }
        XCTAssertEqual(ctl.machinePosition.x, x, accuracy: 0.01, "the machine stands still")
        XCTAssertTrue(ctl.console.contains { $0.text == "Emergency stop" })
    }

    func testEmergencyStopWorksWithoutAJobAndWhileJogging() throws {
        try connect()
        ctl.beginContinuousJog(.e, feed: 6000)
        XCTAssertTrue(wait { ctl.machinePosition.x > 10 })
        ctl.emergencyStop()
        XCTAssertFalse(ctl.isContinuousJogging)
        wait(0.7) { false }
        let x = ctl.machinePosition.x
        wait(0.7) { false }
        XCTAssertEqual(ctl.machinePosition.x, x, accuracy: 0.01)
    }

    func testALostOkDoesNotFreezeTheJob() throws {
        try connect()
        ctl.bufferStuckSeconds = 0.6
        var resynced = 0
        var finished = false
        ctl.onEvent = { if case .bufferResynced(let n) = $0 { resynced = n }; if case .jobFinished(let aborted, _, _, _) = $0 { finished = !aborted } }
        sim.dropAcknowledgements = 1
        ctl.load(GCodeProgram(text: "G21\nG90\nG0 X1 Y1\nG1 X5 F6000\nG1 X9\nM5"))
        ctl.startJob()
        XCTAssertTrue(wait(15) { finished }, "the job finishes although one answer got lost")
        XCTAssertGreaterThan(resynced, 0)
        XCTAssertEqual(ctl.bufferResyncs, 1)
        XCTAssertTrue(ctl.console.contains { $0.text.hasPrefix("Buffer out of sync") })
    }

    func testNoFalseAlarmDuringNormalWork() throws {
        try connect()
        ctl.bufferStuckSeconds = 0.3
        var finished = false
        ctl.onEvent = { if case .jobFinished = $0 { finished = true } }
        ctl.load(GCodeProgram(text: (0..<60).map { "G1 X\($0 % 40) Y\($0 % 7) F6000" }.joined(separator: "\n") + "\nM5"))
        ctl.startJob()
        XCTAssertTrue(wait(20) { finished })
        XCTAssertEqual(ctl.bufferResyncs, 0)
    }
}
