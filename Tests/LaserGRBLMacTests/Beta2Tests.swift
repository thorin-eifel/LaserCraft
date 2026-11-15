import XCTest
import AppKit
@testable import LaserGRBLMac
import LaserGRBLCore

@MainActor
final class Beta2Tests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.set(nil, forKey: "recentFiles")
        UserDefaults.standard.set(nil, forKey: "showSimulator")
    }

    func wait(_ seconds: TimeInterval = 8, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testSimulatorIsListedAndConnects() {
        let model = AppModel()
        XCTAssertTrue(model.ports.contains(AppModel.simulatorPort))
        XCTAssertEqual(model.portName(AppModel.simulatorPort), "Simulator (demo machine)")
        model.selectedPort = AppModel.simulatorPort
        model.simulator.speedFactor = 30
        model.toggleConnection()
        wait { model.controller.state == .idle && model.controller.settings[130] != nil }
        XCTAssertEqual(model.controller.state, .idle)
        XCTAssertTrue(model.simulator.isRunning)

        // double-click in the preview: the head travels to the point
        model.jogToPoint(x: 25, y: 12)
        wait { abs(model.controller.workPosition.x - 25) < 0.3 && abs(model.controller.workPosition.y - 12) < 0.3 }
        XCTAssertEqual(model.controller.workPosition.x, 25, accuracy: 0.3)
        XCTAssertEqual(model.controller.workPosition.y, 12, accuracy: 0.3)

        // a job that does not fit the simulated 400 x 400 mm machine is reported
        model.setProgram(GCodeProgram(text: "G0 X0 Y0\nM4\nG1 X450 Y10 F9000 S2000", name: "big.nc"))
        let kinds = Set(model.jobWarnings.map { "\($0.kind)" })
        XCTAssertEqual(kinds, ["boundary", "power", "speed"], "\(model.jobWarnings)")

        model.toggleConnection()          // disconnect
        wait { !model.simulator.isRunning }
        XCTAssertEqual(model.controller.state, .disconnected)
        XCTAssertFalse(model.simulator.isRunning, "the simulator stops with the connection")
    }

    func testSimulatorCanBeHidden() {
        UserDefaults.standard.set(false, forKey: "showSimulator")
        let model = AppModel()
        XCTAssertFalse(model.ports.contains(AppModel.simulatorPort))
    }

    func testRecentFilesKeepTheLastTenWithoutDuplicates() {
        let model = AppModel()
        model.clearRecents()
        for i in 0..<12 { model.noteRecent(URL(fileURLWithPath: "/tmp/job\(i).nc")) }
        model.noteRecent(URL(fileURLWithPath: "/tmp/job5.nc"))
        XCTAssertEqual(model.recentFiles.count, 10)
        XCTAssertEqual(model.recentFiles.first?.lastPathComponent, "job5.nc")
        XCTAssertEqual(model.recentFiles.filter { $0.lastPathComponent == "job5.nc" }.count, 1)
        XCTAssertEqual(AppModel().recentFiles, model.recentFiles, "saved for the next launch")
        model.clearRecents()
        XCTAssertTrue(model.recentFiles.isEmpty)
    }

    func testPreviewCommandsFromTheMenu() {
        let preview = PreviewModel()
        let before = preview.commandSerial
        preview.perform(.zoomIn)
        XCTAssertEqual(preview.commandSerial, before + 1)
        XCTAssertEqual(preview.command, .zoomIn)
    }
}
