import XCTest
@testable import LaserGRBLCore

final class ResumeStateTests: XCTestCase {
    let job = GCodeProgram(text: """
    G21
    G90
    M4
    G0 X10 Y5
    G1 X20 Y5 F1200 S300
    G1 X20 Y15
    G91
    G1 X5
    G1 Y5 S800
    M5
    G0 X0 Y0
    """, name: "resume.nc")

    func testStateAfterAbsoluteMoves() {
        let st = job.resumeState(before: 6)          // after "G1 X20 Y15"
        XCTAssertEqual(st.x, 20); XCTAssertEqual(st.y, 15)
        XCTAssertEqual(st.feed, 1200); XCTAssertEqual(st.power, 300)
        XCTAssertEqual(st.laser, 4); XCTAssertEqual(st.motion, 1)
        XCTAssertTrue(st.absolute); XCTAssertFalse(st.inches)
    }

    func testRelativeMovesAndLaserOff() {
        let rel = job.resumeState(before: 9)         // after "G1 Y5 S800" in relative mode
        XCTAssertFalse(rel.absolute)
        XCTAssertEqual(rel.x, 25); XCTAssertEqual(rel.y, 20)
        XCTAssertEqual(rel.power, 800)
        let off = job.resumeState(before: 10)        // after M5
        XCTAssertNil(off.laser)
    }

    func testInchesAreConvertedToMillimetres() {
        let p = GCodeProgram(text: "G20\nG90\nG1 X1 Y2 F10\nG1 X2")
        let st = p.resumeState(before: 4)
        XCTAssertEqual(st.x, 50.8, accuracy: 0.001)
        XCTAssertEqual(st.y, 50.8, accuracy: 0.001)
        XCTAssertEqual(st.feed, 254, accuracy: 0.001)
        XCTAssertTrue(st.inches)
    }

    func testRestoreLinesBringTheMachineBackIntoTheSameState() {
        let lines = job.resumeCommands(from: 8)      // continue at "G1 Y5 S800"
        XCTAssertEqual(lines.first, "M5", "the laser is off while travelling to the resume point")
        XCTAssertEqual(lines[1], "G90"); XCTAssertEqual(lines[2], "G21")
        XCTAssertEqual(lines[3], "G0 X25.000 Y15.000")
        XCTAssertTrue(lines.contains("F1200"))
        XCTAssertTrue(lines.contains("G1"))
        XCTAssertTrue(lines.contains("G91"), "relative mode comes back after the absolute travel move")
        XCTAssertEqual(lines.last, "M4 S300", "the laser comes on last, with the power of the previous line")
        XCTAssertLessThan(lines.firstIndex(of: "G0 X25.000 Y15.000")!, lines.firstIndex(of: "G91")!)
    }

    func testNothingToRestoreAtTheStartOrPastTheEnd() {
        XCTAssertEqual(job.resumeCommands(from: 0), [])
        XCTAssertEqual(job.resumeCommands(from: 999), [])
    }
}

final class ResumeJobTests: XCTestCase {
    var sim: GrblSimulator!
    var ctl: GrblController!

    override func setUp() { sim = GrblSimulator(speedFactor: 60); ctl = GrblController() }
    override func tearDown() { ctl.disconnect(); sim.stop() }

    func wait(_ seconds: TimeInterval = 10, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func connect() throws {
        ctl.connect(path: try XCTUnwrap(sim.start()), baud: 115200)
        wait { ctl.state == .idle && ctl.settings[130] != nil }
        XCTAssertEqual(ctl.state, .idle)
    }

    func testJobContinuesAtALineAndOnlySendsTheRest() throws {
        try connect()
        ctl.jobSettings.header = "G90"
        ctl.jobSettings.footer = ""
        var text = "G90\nM4\nF2000\n"
        for i in 1...30 { text += "G1 X\(i) Y\(i % 5) S100\n" }
        let p = GCodeProgram(text: text, name: "resume.nc")
        ctl.load(p)
        ctl.startJob(fromCommand: 20)
        XCTAssertTrue(ctl.jobRunning)
        wait { !ctl.jobRunning }
        XCTAssertFalse(ctl.jobRunning)
        XCTAssertEqual(ctl.jobErrors, 0)
        XCTAssertEqual(ctl.executedProgramCommands, p.commands.count, "the progress ends at the last line")
        let sent = ctl.console.filter { $0.kind == .info }.map { $0.text }
        XCTAssertTrue(sent.contains { $0.contains("21") }, "the log says where the job continued: \(sent)")
        // the restore lines were part of the job
        XCTAssertGreaterThan(ctl.jobTarget, p.commands.count - 20)
    }

    func testProgressIndexStartsAtTheResumeLine() throws {
        try connect()
        sim.speedFactor = 2
        var text = "M4\nF300\n"
        for i in 1...40 { text += "G1 X\(i * 2) S100\n" }
        ctl.load(GCodeProgram(text: text))
        ctl.startJob(fromCommand: 10)
        wait { ctl.jobExecuted > 8 }
        XCTAssertGreaterThanOrEqual(ctl.executedProgramCommands, 10, "never reports lines before the start line as done by this run")
        ctl.abortJob()
    }
}

final class CoolingTests: XCTestCase {
    var sim: GrblSimulator!
    var ctl: GrblController!

    override func setUp() { sim = GrblSimulator(speedFactor: 3); ctl = GrblController() }
    override func tearDown() { ctl.disconnect(); sim.stop() }

    func wait(_ seconds: TimeInterval, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testJobPausesToCoolDownAndThenContinues() throws {
        ctl.connect(path: try XCTUnwrap(sim.start()), baud: 115200)
        wait(8) { ctl.state == .idle && ctl.settings[130] != nil }
        ctl.coolingEnabled = true
        ctl.coolingRunSeconds = 0.8
        ctl.coolingPauseSeconds = 1.2
        var events: [String] = []
        ctl.onEvent = { e in
            switch e {
            case .coolingStarted: events.append("start")
            case .coolingEnded: events.append("end")
            default: break
            }
        }
        ctl.load(GCodeProgram(text: GCodeTests.longJob(lines: 60)))
        ctl.jobSettings.header = ""; ctl.jobSettings.footer = ""
        ctl.startJob()
        wait(15) { ctl.state == .cooling }
        XCTAssertEqual(ctl.state, .cooling, "the machine rests: Hold turns into Cooling")
        XCTAssertNotNil(ctl.coolingRemaining)
        let frozen = ctl.machinePosition.x
        wait(0.6) { false }
        XCTAssertEqual(ctl.machinePosition.x, frozen, accuracy: 2, "no movement during the pause")
        wait(20) { events.contains("end") }
        XCTAssertEqual(events.prefix(2), ["start", "end"])
        wait(30) { !ctl.jobRunning }
        XCTAssertFalse(ctl.jobRunning, "the job still finishes")
        XCTAssertEqual(ctl.jobErrors, 0)
        XCTAssertNil(ctl.coolingRemaining)
    }

    func testCoolingIsOffByDefault() throws {
        XCTAssertFalse(GrblController().coolingEnabled)
    }

    func testResumeKeyEndsTheCoolingPauseEarly() throws {
        ctl.connect(path: try XCTUnwrap(sim.start()), baud: 115200)
        wait(8) { ctl.state == .idle }
        ctl.coolingEnabled = true; ctl.coolingRunSeconds = 0.5; ctl.coolingPauseSeconds = 60
        ctl.load(GCodeProgram(text: GCodeTests.longJob(lines: 80)))
        ctl.jobSettings.header = ""; ctl.jobSettings.footer = ""
        ctl.startJob()
        wait(15) { ctl.state == .cooling }
        XCTAssertEqual(ctl.state, .cooling)
        ctl.resume()
        wait(8) { ctl.state == .run }
        XCTAssertEqual(ctl.state, .run, "resume cancels the long pause")
        ctl.abortJob()
    }
}


extension GCodeTests {
    /// Many 5 mm moves at 600 mm/min: keeps Grbl's planner busy for a while.
    static func longJob(lines: Int) -> String {
        var t = "G90\nM4\nF600\n"
        for i in 1...lines { t += "G1 X\(i * 5) Y\(i % 2 == 0 ? 0 : 3) S100\n" }
        return t
    }
}
