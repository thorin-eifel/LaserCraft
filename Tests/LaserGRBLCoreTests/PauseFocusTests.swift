import XCTest
@testable import LaserGRBLCore

final class PauseAndFocusTests: XCTestCase {
    func square(_ doc: inout LayoutDocument, layer: Int, x: Double) {
        var o = LayoutObject(name: "sq", kind: .vectors([Polyline([Pt(0, 0), Pt(10, 0), Pt(10, 10), Pt(0, 10)], closed: true)]), layer: layer)
        o.x = x; o.width = 10; o.height = 10
        doc.objects.append(o)
    }

    func testAPauseGoesBeforeItsLayerWithTheLaserOffAndACleanMessage() {
        var doc = LayoutDocument()
        doc.layers = [LayoutLayer(id: 0, name: "Engrave"), LayoutLayer(id: 1, name: "Cut")]
        doc.layers[1].pauseBefore = true
        doc.layers[1].pauseNote = "Flip (the) material; then go"
        square(&doc, layer: 0, x: 0); square(&doc, layer: 1, x: 30)
        let g = doc.generate()
        let m0 = try! XCTUnwrap(g.firstIndex(of: "M0"))
        XCTAssertEqual(g.filter { $0 == "M0" }.count, 1, "only the layer that asks for it")
        XCTAssertEqual(g[m0 - 1], "(MSG,Flip the material then go)", "no brackets or semicolons that would end the comment")
        XCTAssertEqual(g[(m0 - 3)...(m0 - 2)].map { $0 }, ["M5", "S0"])
        XCTAssertEqual(g[m0 - 4], "; layer Cut")
        XCTAssertEqual(LayoutDocument.pauseLines("")[2], "(MSG,Pause)")
        XCTAssertEqual(LayoutDocument.pauseLines("Prüfen ä")[2], "(MSG,Prfen )", "only plain ASCII goes into the message")
    }

    func testNoPauseForAnEmptyLayer() {
        var doc = LayoutDocument()
        doc.layers = [LayoutLayer(id: 0, name: "A"), LayoutLayer(id: 1, name: "B")]
        doc.layers[1].pauseBefore = true
        square(&doc, layer: 0, x: 0)
        XCTAssertFalse(doc.generate().contains("M0"))
    }

    func testFocusStepLowersZWithEveryPassAndReturns() {
        var doc = LayoutDocument()
        doc.layers = [LayoutLayer(id: 0, name: "Cut")]
        doc.layers[0].passes = 3; doc.layers[0].focusStep = 0.5
        square(&doc, layer: 0, x: 0)
        let g = doc.generate()
        let z = g.filter { $0.hasPrefix("G0 Z") }
        XCTAssertEqual(z, ["G0 Z0", "G0 Z-0.5", "G0 Z-1", "G0 Z0"], "each pass is lower; the last line goes back to the starting focus")
        XCTAssertEqual(g.filter { $0 == "; pass 1 of 3" || $0 == "; pass 3 of 3" }.count, 2)
        XCTAssertEqual(g.filter { $0.hasPrefix("G1 ") }.count, 3 * 4, "three passes of four sides")
    }

    func testWithoutFocusStepThereIsNoZMoveAndOldProjectsStillLoad() throws {
        var doc = LayoutDocument()
        doc.layers = [LayoutLayer(id: 0, name: "Cut")]
        doc.layers[0].passes = 2
        square(&doc, layer: 0, x: 0)
        XCTAssertFalse(doc.generate().contains { $0.contains(" Z") })
        // a layer written before pauses and focus steps existed
        let old = ##"{"id":3,"name":"Old","mode":"line","speed":800,"powerPercent":60,"passes":2,"fillSpacing":0.1,"visible":true,"output":true,"colorHex":"#FF0000"}"##
        let l = try JSONDecoder().decode(LayoutLayer.self, from: Data(old.utf8))
        XCTAssertEqual(l.speed, 800); XCTAssertFalse(l.pauseBefore); XCTAssertEqual(l.focusStep, 0)
        let back = try JSONDecoder().decode(LayoutLayer.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l)
    }

}

final class ProgramPauseTests: XCTestCase {
    var sim: GrblSimulator!
    var ctl: GrblController!

    override func setUp() { sim = GrblSimulator(speedFactor: 20); ctl = GrblController() }
    override func tearDown() { ctl.disconnect(); sim.stop() }

    func wait(_ seconds: TimeInterval = 15, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testTheJobStopsAtM0UntilTheLaserIsResumed() throws {
        ctl.connect(path: try XCTUnwrap(sim.start()), baud: 115200)
        wait { ctl.state == .idle && ctl.settings[130] != nil }
        ctl.jobSettings.header = "G90"; ctl.jobSettings.footer = ""
        ctl.load(GCodeProgram(text: "G90\nG1 X5 F600\n(MSG,Flip)\nM0\nG1 X10 F600\n", name: "pause.nc"))
        ctl.startJob()
        wait { ctl.state == .autoHold }
        XCTAssertEqual(ctl.state, .autoHold, "the machine waits at M0 (a hold the person did not ask for)")
        XCTAssertTrue(ctl.jobRunning, "the job is not over, it is waiting")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(ctl.state, .autoHold, "and keeps waiting")
        ctl.resume()
        wait { !ctl.jobRunning }
        XCTAssertFalse(ctl.jobRunning)
        XCTAssertEqual(ctl.jobErrors, 0)
    }
}
