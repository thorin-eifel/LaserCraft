import XCTest
@testable import LaserGRBLCore

final class ParserTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(GrblParser.classify("ok"), .ok)
        XCTAssertEqual(GrblParser.classify("error:20"), .error(20))
        XCTAssertEqual(GrblParser.classify("ALARM:1"), .alarm(1))
        XCTAssertEqual(GrblParser.classify("$30=1000"), .setting(30, "1000"))
        XCTAssertEqual(GrblParser.classify("Grbl 1.1h ['$' for help]"), .welcome("Grbl 1.1h ['$' for help]"))
        XCTAssertEqual(GrblParser.classify("[MSG:Caution: Unlocked]"), .info("[MSG:Caution: Unlocked]"))
    }

    func testWelcomeVersion() {
        let v = GrblParser.parseWelcome("Grbl 1.1h ['$' for help]")
        XCTAssertEqual(v, GrblVersion(major: 1, minor: 1, build: "h"))
        XCTAssertTrue(v! >= GrblVersion(major: 1, minor: 1))
        XCTAssertTrue(GrblParser.parseWelcome("Grbl 0.9j ['$' for help]")! < GrblVersion(major: 1, minor: 1))
    }

    func testStatusV11() {
        let r = GrblParser.parseStatus("<Hold:0|MPos:10.000,20.500,0.000|Bf:15,120|FS:500,800|WCO:1.0,2.0,0.0|Ov:90,100,110>")!
        XCTAssertEqual(r.state, .hold)
        XCTAssertEqual(r.subState, 0)
        XCTAssertEqual(r.mpos, Point3(10, 20.5, 0))
        XCTAssertEqual(r.wco, Point3(1, 2, 0))
        XCTAssertEqual(r.overrides?.feed, 90)
        XCTAssertEqual(r.overrides?.spindle, 110)
        XCTAssertEqual(r.buffer?.bytes, 120)
        XCTAssertEqual(r.feed, 500)
        XCTAssertEqual(r.spindle, 800)
    }

    func testStatusV09() {
        let r = GrblParser.parseStatus("<Idle,MPos:5.000,6.000,0.000,WPos:1.000,2.000,0.000>")!
        XCTAssertEqual(r.state, .idle)
        XCTAssertEqual(r.mpos, Point3(5, 6, 0))
        XCTAssertEqual(r.wpos, Point3(1, 2, 0))
    }

    func testErrorText() {
        XCTAssertTrue(GrblParser.describeError(20).contains("Unsupported"))
        XCTAssertTrue(GrblParser.describeAlarm(1).contains("Hard limit"))
    }

    func testCleanLine() {
        XCTAssertEqual(GrblParser.cleanLine("G1 X10 (move) Y5 ; comment"), "G1X10Y5")
        XCTAssertEqual(GrblParser.cleanLine("  ; only comment"), "")
    }
}

final class GCodeTests: XCTestCase {
    func testSegmentsAndTime() {
        let p = GCodeProgram(text: """
        G90 (abs)
        G0 X0 Y0
        M3 S0
        G1 X10 Y0 F600 S500
        G1 X10 Y10
        M5
        G0 X0 Y0
        """, rapidRate: 3000)
        XCTAssertEqual(p.commands.count, 7)
        XCTAssertEqual(p.burnBounds.width, 10)
        XCTAssertEqual(p.burnBounds.height, 10)
        XCTAssertEqual(p.segments.filter { $0.power > 0 }.count, 2)
        // 20 mm at 600 mm/min = 2 s, return 14.1 mm at 3000 = 0.28 s
        XCTAssertEqual(p.estimatedSeconds, 2 + 14.142 / 3000 * 60, accuracy: 0.05)
        XCTAssertEqual(p.cumulativeSeconds.count, 7)
    }

    func testRelativeAndInches() {
        let p = GCodeProgram(text: "G20\nG91\nM3\nG1 X1 F10 S100\nG1 Y1")
        XCTAssertEqual(p.burnBounds.width, 25.4, accuracy: 0.001)
        XCTAssertEqual(p.burnBounds.height, 25.4, accuracy: 0.001)
    }

    func testArc() {
        let p = GCodeProgram(text: "G90\nM3\nG0 X10 Y0\nG3 X0 Y10 I-10 J0 F1000 S255")
        let burn = p.segments.filter { $0.power > 0 }
        XCTAssertGreaterThan(burn.count, 10)
        let len = burn.reduce(0.0) { $0 + hypot(Double($1.x1 - $1.x0), Double($1.y1 - $1.y0)) }
        XCTAssertEqual(len, 2 * .pi * 10 / 4, accuracy: 0.05)
    }
}

final class RasterTests: XCTestCase {
    private func image(_ rows: [[UInt8]]) -> RasterImage {
        var rgba: [UInt8] = []
        for row in rows { for g in row { rgba += [g, g, g, 255] } }
        return RasterImage(width: rows[0].count, height: rows.count, rgba: rgba)
    }

    func testLineToLineHorizontal() {
        var o = RasterOptions()
        o.linesPerMM = 1; o.markSpeed = 800; o.minPower = 0; o.maxPower = 1000
        o.formula = .simpleAverage; o.whiteClip = 0
        // top row white, bottom row: black white black white
        let img = image([[255, 255, 255, 255], [0, 255, 0, 255]])
        let text = RasterConverter.generate(bitmap: img, options: o)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "G0 X0 Y0 F800")
        XCTAssertEqual(lines[1], "M3 S0")
        XCTAssertEqual(lines.last, "M5")
        // bottom image row is engraved first (Y = 0): black pixel -> S1000
        XCTAssertTrue(lines.contains { $0.contains("G1 X1 S1000") }, text)
        let p = GCodeProgram(text: text)
        XCTAssertEqual(p.burnBounds.minY, 0)
        XCTAssertEqual(p.burnBounds.minX, 0)
        XCTAssertEqual(p.segments.filter { $0.power > 0 }.count, 2)
        XCTAssertEqual(p.burnLength, 2, accuracy: 0.001)
    }

    func testPowerRangeAndGray() {
        var o = RasterOptions()
        o.linesPerMM = 1; o.minPower = 100; o.maxPower = 500; o.whiteClip = 0; o.formula = .simpleAverage
        let img = image([[0, 0]])
        let text = RasterConverter.generate(bitmap: img, options: o)
        XCTAssertTrue(text.contains("S500"), text)
    }

    func testAllWhiteProducesNoBurn() {
        var o = RasterOptions(); o.linesPerMM = 2
        let img = image([[255, 255, 255], [255, 255, 255]])
        let p = GCodeProgram(text: RasterConverter.generate(bitmap: img, options: o))
        XCTAssertEqual(p.segments.filter { $0.power > 0 }.count, 0)
    }

    func testVerticalAndDiagonalCoverBlackPixels() {
        let img = image([[0, 255, 0], [255, 0, 255], [0, 255, 0]]) // 5 black pixels
        for dir in FillDirection.allCases {
            var o = RasterOptions(); o.linesPerMM = 1; o.direction = dir; o.formula = .simpleAverage; o.whiteClip = 0
            let p = GCodeProgram(text: RasterConverter.generate(bitmap: img, options: o))
            XCTAssertEqual(p.burnLength, dir == .diagonal ? 5 * 2.0.squareRoot() : 5, accuracy: 0.001, "\(dir)")
        }
    }

    func testDitheringIsBinary() {
        let gray = [UInt8](repeating: 128, count: 16 * 16)
        for m in DitherMode.allCases {
            let d = RasterConverter.dither(gray, width: 16, height: 16, mode: m)
            XCTAssertTrue(d.allSatisfy { $0 == 0 || $0 == 255 })
            let black = d.filter { $0 == 0 }.count
            XCTAssertTrue(black > 40 && black < 220, "\(m) \(black)")
        }
    }
}

final class EndToEndRasterTests: XCTestCase {
    func testCGImageToProgram() throws {
        // 40x30 horizontal gradient, converted at 1 line/mm to a 20x15 mm engraving
        var rgba: [UInt8] = []
        for _ in 0..<30 { for x in 0..<40 { let g = UInt8(x * 255 / 39); rgba += [g, g, g, 255] } }
        let cg = try XCTUnwrap(RasterImage(width: 40, height: 30, rgba: rgba).makeCGImage())
        var o = RasterOptions()
        o.widthMM = 20; o.heightMM = 15; o.linesPerMM = 1; o.maxPower = 255
        let text = try XCTUnwrap(RasterConverter.generate(image: cg, options: o))
        let p = GCodeProgram(text: text)
        XCTAssertEqual(p.burnBounds.maxX, 20, accuracy: 1.01)
        XCTAssertEqual(p.burnBounds.maxY, 14, accuracy: 1.01)
        XCTAssertGreaterThan(p.maxPower, 200)           // dark left edge burns at full power
        XCTAssertLessThanOrEqual(p.maxPower, 255)
        // white clip: the lightest edge must not burn
        XCTAssertEqual(p.commands.first, "G0X0Y0F1000")
    }

    func testOffsetAndCustomHeader() {
        var o = RasterOptions()
        o.linesPerMM = 1; o.offsetX = 5; o.offsetY = 7.5
        let img = RasterImage(width: 2, height: 1, rgba: [0, 0, 0, 255, 0, 0, 0, 255])
        let text = RasterConverter.generate(bitmap: img, options: o)
        XCTAssertTrue(text.hasPrefix("G0 X5 Y7.5 F1000"), text)
        let p = GCodeProgram(text: text)
        XCTAssertEqual(p.burnBounds.minX, 5)
        XCTAssertEqual(p.burnBounds.minY, 7.5)
    }
}
