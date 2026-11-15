import XCTest
import AppKit
@testable import LaserGRBLMac
import LaserGRBLCore

@MainActor
final class Release2Tests: XCTestCase {
    override func tearDown() {
        for k in ["lastStop", "coolingEnabled", "coolRunMinutes", "coolPauseMinutes", "autoReconnect", "imagePresets"] {
            UserDefaults.standard.set(nil, forKey: k)
        }
    }

    func wait(_ seconds: TimeInterval = 10, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: auto reconnect

    func testReconnectWaitsForThePortThenConnects() {
        let r = AutoReconnect(interval: 0.05, maxAttempts: 40)
        var polls = 0
        var connected: [String] = []
        r.isPortAvailable = { _ in polls += 1; return polls >= 4 }
        r.connect = { connected.append($0); r.stop() }
        r.start(port: "/dev/cu.usbserial-1")
        XCTAssertTrue(r.isActive)
        wait(3) { !connected.isEmpty }
        XCTAssertEqual(connected, ["/dev/cu.usbserial-1"])
        XCTAssertGreaterThanOrEqual(polls, 4, "it keeps looking until the port is back")
        XCTAssertFalse(r.isActive)
    }

    func testReconnectGivesUp() {
        let r = AutoReconnect(interval: 0.02, maxAttempts: 5)
        var gaveUp = false
        r.isPortAvailable = { _ in false }
        r.onGiveUp = { gaveUp = true }
        r.start(port: "x")
        wait(3) { gaveUp }
        XCTAssertTrue(gaveUp)
        XCTAssertEqual(r.attempts, 5)
        XCTAssertFalse(r.isActive)
    }

    // MARK: resume a job that was stopped

    func testStoppedJobCanBeContinuedFromWhereItStopped() throws {
        let model = AppModel()
        model.simulator.speedFactor = 6
        model.selectedPort = AppModel.simulatorPort
        model.toggleConnection()
        wait { model.controller.state == .idle && model.controller.settings[130] != nil }
        model.controller.jobSettings.header = ""; model.controller.jobSettings.footer = ""

        var text = "G90\nM4\nF1200\n"
        for i in 1...120 { text += "G1 X\(i) Y\(i % 7) S100\n" }
        let program = GCodeProgram(text: text, name: "long.nc")
        model.setProgram(program)
        model.controller.startJob()
        wait { model.controller.executedProgramCommands > 50 }
        model.controller.abortJob()

        let stop = try XCTUnwrap(model.stopInfo, "the app remembers where the job stopped")
        XCTAssertEqual(stop.name, "long.nc")
        XCTAssertEqual(stop.count, program.commands.count)
        XCTAssertGreaterThan(stop.line, 20)
        XCTAssertLessThan(stop.line, program.commands.count - 20)
        XCTAssertEqual(model.suggestedResumeLine, stop.line)
        XCTAssertEqual(AppModel().stopInfo, stop, "also after a restart of the app")

        // the soft reset that follows the abort brings the controller back; then the job carries on
        wait(15) { model.controller.state == .idle && model.controller.version != nil }
        model.controller.startJob(fromCommand: model.suggestedResumeLine)
        wait(30) { !model.controller.jobRunning }
        XCTAssertFalse(model.controller.jobRunning)
        XCTAssertEqual(model.controller.jobErrors, 0)
        XCTAssertNil(model.stopInfo, "a finished job leaves nothing to resume")
        XCTAssertEqual(model.controller.executedProgramCommands, program.commands.count)
        model.toggleConnection()
        wait { !model.simulator.isRunning }
    }

    func testAnotherFileDoesNotGetTheOldSuggestion() {
        let model = AppModel()
        model.setProgram(GCodeProgram(text: "G1 X1 F10\nG1 X2\nG1 X3", name: "other.nc"))
        UserDefaults.standard.set(try? JSONEncoder().encode(AppModel.StopInfo(name: "long.nc", count: 120, line: 80)), forKey: "lastStop")
        XCTAssertEqual(AppModel().suggestedResumeLine, 0)
        let same = AppModel()
        same.setProgram(GCodeProgram(text: "G1 X1 F10", name: "long.nc"))
        XCTAssertEqual(same.suggestedResumeLine, 0, "a file with a different line count is treated as another job")
    }

    // MARK: cooling preferences reach the controller

    func testCoolingPreferences() {
        UserDefaults.standard.set(true, forKey: "coolingEnabled")
        UserDefaults.standard.set(7, forKey: "coolRunMinutes")
        UserDefaults.standard.set(2, forKey: "coolPauseMinutes")
        let model = AppModel()
        XCTAssertTrue(model.controller.coolingEnabled)
        XCTAssertEqual(model.controller.coolingRunSeconds, 420)
        XCTAssertEqual(model.controller.coolingPauseSeconds, 120)
    }

    // MARK: image presets

    func testSavedPresetsAreKeptForTheNextTime() {
        let store = PresetStore()
        XCTAssertEqual(store.all.count, ImagePreset.builtIns.count)
        var o = RasterOptions(); o.linesPerMM = 7; o.laserOn = "M3"
        store.add(ImagePreset(name: "Birch 3 mm", options: o, minPowerPercent: 5, maxPowerPercent: 55))
        store.add(ImagePreset(name: "Birch 3 mm", options: o, minPowerPercent: 6, maxPowerPercent: 66))   // same name replaces
        XCTAssertEqual(store.user.count, 1)
        let again = PresetStore()
        XCTAssertEqual(again.user.first?.maxPowerPercent, 66)
        again.remove(again.user[0].id)
        XCTAssertTrue(PresetStore().user.isEmpty)
    }
}
