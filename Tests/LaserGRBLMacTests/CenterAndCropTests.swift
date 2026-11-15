import XCTest
import AppKit
@testable import LaserGRBLMac
import LaserGRBLCore

@MainActor
final class CenterButtonTests: XCTestCase {
    var grbl: FakeGrbl!
    override func tearDown() { grbl?.shutdown(); grbl = nil }

    func wait(_ seconds: TimeInterval = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testGoToCenterIsAmongTheDefaultButtonsAndAddedOnceToSavedOnes() {
        let defaults = AppModel.defaultButtons()
        let i = defaults.firstIndex { $0.titleKey == "Go to Zero" }!
        XCTAssertEqual(defaults[i + 1].titleKey, "Go to Center")
        XCTAssertTrue(defaults[i + 1].gcode.contains("{centerX}"))
        let suite = UserDefaults(suiteName: "lc-test-\(UUID().uuidString)")!
        let old = defaults.filter { $0.titleKey != "Go to Center" }
        let added = AppModel.addingCenterButton(old, defaults: suite)
        XCTAssertEqual(added.count, old.count + 1)
        XCTAssertEqual(added[added.firstIndex { $0.titleKey == "Go to Zero" }! + 1].titleKey, "Go to Center", "right after Go to Zero")
        // the person may delete it; it does not come back
        XCTAssertEqual(AppModel.addingCenterButton(old, defaults: suite).count, old.count)
    }

    func testGoToCenterMovesToTheMiddleOfTheWorkArea() {
        UserDefaults.standard.set(nil, forKey: "customButtons")
        let app = AppModel()
        grbl = FakeGrbl(); grbl.start()
        app.controller.connect(path: grbl.slavePath, baud: 115200)
        wait { app.controller.state == .idle && app.controller.settings[131] != nil }
        let button = AppModel.defaultButtons().first { $0.titleKey == "Go to Center" }!
        app.runCustomButton(button)
        wait { self.grbl.receivedLines.contains { $0.contains("G0X200Y200") } }
        XCTAssertTrue(grbl.receivedLines.contains { $0.contains("G0X200Y200") }, "$130/$131 are 400 mm: \(grbl.receivedLines)")
        XCTAssertEqual(AppModel.coordinate(150.25), "150.25"); XCTAssertEqual(AppModel.coordinate(200), "200")
    }

    func testGoToCenterNeedsTheSizeOfTheWorkArea() {
        let app = AppModel()
        app.runCustomButton(AppModel.defaultButtons().first { $0.titleKey == "Go to Center" }!)
        XCTAssertNotNil(app.alertMessage, "not connected, so the size is unknown and nothing is sent")
    }
}
