import XCTest
import AppKit
@testable import LaserGRBLMac
import LaserGRBLCore

/// The Mac must stay awake exactly while a job is running. `pmset -g assertions` shows what macOS really holds.
@MainActor
final class SleepTests: XCTestCase {
    var grbl: FakeGrbl!

    override func tearDown() {
        UserDefaults.standard.set(nil, forKey: "keepAwake")
        UserDefaults.standard.set(nil, forKey: "keepDisplayOn")
        grbl?.shutdown(); grbl = nil
    }

    /// Names of the power assertions currently held by any process.
    func assertions() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func holdsJobAssertion() throws -> Bool { try assertions().contains(SleepGuard.reason) }

    func wait(_ seconds: TimeInterval, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testGuardHoldsAndReleasesTheAssertion() throws {
        let g = SleepGuard()
        XCTAssertFalse(try holdsJobAssertion())
        g.begin()
        XCTAssertTrue(g.isActive)
        XCTAssertTrue(try holdsJobAssertion(), "macOS should show the 'prevent sleep' assertion while the guard is active")
        g.begin()                      // a second call must not stack another assertion
        g.end()
        XCTAssertFalse(g.isActive)
        XCTAssertFalse(try holdsJobAssertion(), "the assertion must be gone after the guard ends")
    }

    func testDisplayStaysOnOnlyWhenAsked() throws {
        let g = SleepGuard()
        g.begin(keepDisplayOn: true)
        let text = try assertions()
        XCTAssertTrue(text.contains("PreventUserIdleDisplaySleep") && text.contains(SleepGuard.reason))
        g.end()
    }

    private func runJob(model: AppModel) throws {
        grbl = FakeGrbl(); grbl.lineDelay = 20_000; grbl.start()
        model.controller.connect(path: grbl.slavePath, baud: 115200)
        wait(5) { model.controller.state == .idle }
        var text = ""
        for i in 0..<50 { text += "G1 X\(i) F1000 S100\n" }
        model.setProgram(GCodeProgram(text: text, name: "sleep-test.nc"))
        XCTAssertFalse(try holdsJobAssertion(), "the Mac may sleep before the job")
        model.controller.startJob()      // the safety dialog is part of the Start button, not of the controller
    }

    func testMacStaysAwakeOnlyWhileTheJobRuns() throws {
        let model = AppModel()
        try runJob(model: model)
        XCTAssertTrue(model.controller.jobRunning)
        XCTAssertTrue(model.keepingAwake)
        XCTAssertTrue(try holdsJobAssertion(), "no sleep while the job is running")
        wait(30) { !model.controller.jobRunning }
        XCTAssertFalse(model.controller.jobRunning)
        XCTAssertFalse(model.keepingAwake)
        XCTAssertFalse(try holdsJobAssertion(), "the Mac may sleep again after the job")
    }

    func testStoppingTheJobAlsoReleasesTheMac() throws {
        let model = AppModel()
        try runJob(model: model)
        XCTAssertTrue(try holdsJobAssertion())
        model.controller.abortJob()
        XCTAssertFalse(try holdsJobAssertion(), "a stopped job must not keep the Mac awake")
    }

    func testSettingCanTurnItOff() throws {
        UserDefaults.standard.set(false, forKey: "keepAwake")
        let model = AppModel()
        try runJob(model: model)
        XCTAssertFalse(model.keepingAwake)
        XCTAssertFalse(try holdsJobAssertion())
        model.controller.abortJob()
    }
}
