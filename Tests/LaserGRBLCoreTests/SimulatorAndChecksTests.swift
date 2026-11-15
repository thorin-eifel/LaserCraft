import XCTest
@testable import LaserGRBLCore

final class SimulatorTests: XCTestCase {
    var sim: GrblSimulator!
    var ctl: GrblController!

    override func setUp() {
        sim = GrblSimulator(speedFactor: 60)
        ctl = GrblController()
    }

    override func tearDown() {
        ctl.disconnect()
        sim.stop()
    }

    @discardableResult
    func wait(_ seconds: TimeInterval = 8, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return cond()
    }

    func connect() throws {
        let path = try XCTUnwrap(sim.start())
        ctl.connect(path: path, baud: 115200)
        XCTAssertTrue(wait { ctl.state == .idle && ctl.settings[130] != nil && ctl.version != nil })
    }

    func testConnectsAndReportsLikeGrbl() throws {
        try connect()
        XCTAssertEqual(ctl.settings[32], "1")
        XCTAssertEqual(ctl.settings[130], "400.000")
        XCTAssertGreaterThanOrEqual(ctl.version!, GrblVersion(major: 1, minor: 1))
    }

    func testJobMovesTheHeadAndFinishes() throws {
        try connect()
        sim.speedFactor = 6
        let p = GCodeProgram(text: "G90\nM4\nG0 X10 Y10\nG1 X60 Y10 F1200 S500\nG1 X60 Y40\nM5\nG0 X0 Y0")
        ctl.load(p)
        ctl.startJob()
        XCTAssertTrue(wait { ctl.machinePosition.x > 5 }, "the head should move while the job runs")
        XCTAssertTrue(wait(20) { !ctl.jobRunning })
        XCTAssertEqual(ctl.jobErrors, 0)
        XCTAssertTrue(wait { ctl.state == .idle && abs(ctl.machinePosition.x) < 0.5 && abs(ctl.machinePosition.y) < 0.5 },
                      "the head ends at the origin: \(ctl.machinePosition)")
    }

    func testHoldAndResume() throws {
        try connect()
        sim.speedFactor = 6
        ctl.load(GCodeProgram(text: "G90\nG1 X200 Y0 F600"))
        ctl.startJob()
        XCTAssertTrue(wait { ctl.machinePosition.x > 3 })
        ctl.feedHold()
        XCTAssertTrue(wait { ctl.state == .hold || ctl.state == .autoHold })
        let frozen = ctl.machinePosition.x
        wait(0.5) { false }
        XCTAssertEqual(ctl.machinePosition.x, frozen, accuracy: 1.5, "no movement while held")
        ctl.resume()
        XCTAssertTrue(wait { ctl.machinePosition.x > frozen + 5 })
        ctl.abortJob()
    }

    func testJogAndOverridesAndStatusBuffer() throws {
        try connect()
        ctl.jog(.e, step: 20, feed: 6000)
        XCTAssertTrue(wait { abs(ctl.machinePosition.x - 20) < 0.2 })
        ctl.setOverrides(feed: 130, spindle: 70)
        XCTAssertTrue(wait { ctl.overrideFeed == 130 && ctl.overrideSpindle == 70 })
        XCTAssertNotNil(ctl.buffer)
    }

    func testHomeAnswersLikeAMachineWithoutSwitches() throws {
        try connect()
        ctl.home()
        XCTAssertTrue(wait { ctl.console.contains { $0.kind == .error && $0.text.contains("error:5") } })
    }

    func testPlannerBackpressureKeepsTheBufferWithinLimits() throws {
        try connect()
        sim.speedFactor = 3
        var text = ""
        for i in 0..<120 { text += "G1 X\(i % 50) Y\(i % 30) F3000\n" }
        ctl.load(GCodeProgram(text: text))
        ctl.startJob()
        XCTAssertTrue(wait(30) { ctl.jobExecuted > 20 })
        XCTAssertLessThanOrEqual(ctl.usedBufferBytes, 127)
        ctl.abortJob()
    }
}

final class JobCheckTests: XCTestCase {
    let machine: [Int: String] = [30: "1000", 32: "1", 110: "3000", 111: "3000", 130: "400", 131: "300", 20: "0"]

    func program(_ text: String) -> GCodeProgram { GCodeProgram(text: text) }

    func testJobThatFitsHasNoWarnings() {
        let p = program("G90\nM4\nG0 X10 Y10\nG1 X100 Y50 F1500 S800")
        XCTAssertEqual(JobCheck.run(program: p, settings: machine, workOffset: Point3()), [])
    }

    func testTooBigForTheMachine() {
        let w = JobCheck.run(program: program("G0 X0 Y0\nM4\nG1 X450 Y10 F1000 S10\nG1 X450 Y350"), settings: machine, workOffset: nil)
        XCTAssertEqual(w.filter { $0.kind == .boundary }.count, 2)
        XCTAssertTrue(w.contains { $0.text.range(of: #"50[.,]0 mm wider"#, options: .regularExpression) != nil }, "\(w)")
        XCTAssertTrue(w.contains { $0.text.range(of: #"50[.,]0 mm taller"#, options: .regularExpression) != nil }, "\(w)")
        XCTAssertTrue(JobCheck.exceedsMachine(program: program("G0 X0\nG1 X450 F100"), settings: machine))
    }

    func testPositionIsOnlyCheckedWithSoftLimits() {
        var s = machine
        let p = program("G0 X-5 Y0\nM4\nG1 X100 Y50 F1000 S100")
        // origin at the machine's far corner: the work area is [-400, 0] x [-300, 0] in work coordinates
        XCTAssertEqual(JobCheck.run(program: p, settings: s, workOffset: Point3(0, 0, 0)), [], "without soft limits nothing is claimed")
        s[20] = "1"
        let w = JobCheck.run(program: p, settings: s, workOffset: Point3(0, 0, 0))
        XCTAssertTrue(w.contains { $0.text.contains("beyond the right edge") }, "\(w)")
        XCTAssertTrue(w.contains { $0.text.contains("beyond the top edge") }, "\(w)")
        // with the work origin 150 mm from the corner nothing sticks out
        XCTAssertEqual(JobCheck.run(program: program("G0 X-100 Y-100\nM4\nG1 X-10 Y-20 F100 S10"), settings: s, workOffset: Point3(0, 0, 0)), [])
    }

    func testLaserModeOffPowerAndSpeed() {
        var s = machine; s[32] = "0"; s[30] = "255"; s[110] = "1000"
        let p = program("M4\nG1 X10 Y10 F6000 S800")
        let w = JobCheck.run(program: p, settings: s, workOffset: nil)
        XCTAssertEqual(Set(w.map { "\($0.kind)" }), ["laserMode", "power", "speed"], "\(w)")
    }

    func testUnknownMachineClaimsNothing() {
        XCTAssertEqual(JobCheck.run(program: program("M4\nG1 X9999 F99999 S9999"), settings: [:], workOffset: nil), [])
    }
}

@MainActor
final class DiagnosticsTests: XCTestCase {
    func testReportAndConsoleText() {
        let c = GrblController()
        c.load(GCodeProgram(text: "G1 X5 F100 S10", name: "t.nc"))
        let report = Diagnostics.report(appVersion: "1.0.0", system: "macOS 27", port: "/dev/cu.test", baud: 115200, controller: c)
        XCTAssertTrue(report.contains("App version:   1.0.0"))
        XCTAssertTrue(report.contains("/dev/cu.test / 115200"))
        XCTAssertTrue(report.contains("Job:           1 lines"))
        XCTAssertTrue(report.contains("Grbl settings ($$):"))
        let lines = [ConsoleLine(id: 1, text: "G0 X1", kind: .sent, date: Date(timeIntervalSince1970: 0)),
                     ConsoleLine(id: 2, text: "error:20", kind: .error, date: Date(timeIntervalSince1970: 1))]
        let text = Diagnostics.consoleText(lines)
        XCTAssertTrue(text.contains("> G0 X1"))
        XCTAssertTrue(text.contains("! error:20"))
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }
}
