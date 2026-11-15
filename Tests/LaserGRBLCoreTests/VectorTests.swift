import XCTest
@testable import LaserGRBLCore

final class VectorTests: XCTestCase {
    func svg(_ body: String, attrs: String = "width=\"100mm\" height=\"50mm\" viewBox=\"0 0 100 50\"") -> Data {
        Data("<svg xmlns=\"http://www.w3.org/2000/svg\" \(attrs)>\(body)</svg>".utf8)
    }

    func testRectangleBecomesClosedShapeInMillimetresWithYUp() throws {
        let lines = try SVGParser.parse(svg("<rect x=\"10\" y=\"5\" width=\"20\" height=\"10\"/>"))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].closed)
        let b = VectorMath.bounds(lines)
        XCTAssertEqual(b.minX, 10, accuracy: 1e-6); XCTAssertEqual(b.width, 20, accuracy: 1e-6)
        XCTAssertEqual(b.height, 10, accuracy: 1e-6)
        // SVG y=5..15 on a 50 mm high page -> machine y = 35..45
        XCTAssertEqual(b.minY, 35, accuracy: 1e-6)
    }

    func testViewBoxScalesToThePhysicalSize() throws {
        let lines = try SVGParser.parse(svg("<rect x=\"0\" y=\"0\" width=\"50\" height=\"25\"/>", attrs: "width=\"50mm\" height=\"25mm\" viewBox=\"0 0 100 50\""))
        XCTAssertEqual(VectorMath.bounds(lines).width, 25, accuracy: 1e-6)
    }

    func testUnitlessSvgUsesNinetySixDpi() throws {
        let lines = try SVGParser.parse(svg("<rect width=\"96\" height=\"96\"/>", attrs: "width=\"200\" height=\"200\""))
        XCTAssertEqual(VectorMath.bounds(lines).width, 25.4, accuracy: 1e-6)
        var o = SVGOptions(); o.dpi = 72
        let l2 = try SVGParser.parse(svg("<rect width=\"72\" height=\"72\"/>", attrs: "width=\"200\" height=\"200\""), options: o)
        XCTAssertEqual(VectorMath.bounds(l2).width, 25.4, accuracy: 1e-6)
    }

    func testCircleHasTheRightAreaAndTransformsApply() throws {
        let lines = try SVGParser.parse(svg("<g transform=\"translate(50 25) scale(2)\"><circle r=\"5\"/></g>"))
        XCTAssertEqual(lines.count, 1)
        let area = abs(lines[0].signedArea)
        XCTAssertEqual(area, Double.pi * 100, accuracy: 1.5)           // r = 10 mm after scale(2)
        let b = VectorMath.bounds(lines)
        XCTAssertEqual((b.minX + b.maxX) / 2, 50, accuracy: 0.05)
    }

    func testPathCommandsAndArcFlags() throws {
        // closed triangle with relative commands, a cubic and a compact arc ("00" flags without separators)
        let tri = try SVGParser.parse(svg("<path d=\"M10 10 l20 0 l-10 20 z\"/>"))
        XCTAssertEqual(tri[0].points.count, 3); XCTAssertTrue(tri[0].closed)
        XCTAssertEqual(abs(tri[0].signedArea), 200, accuracy: 1e-6)
        let cub = try SVGParser.parse(svg("<path d=\"M0 0 C 0 10, 10 10, 10 0\"/>"))
        XCTAssertGreaterThan(cub[0].points.count, 5)
        XCTAssertEqual(cub[0].points.last!.x, 10, accuracy: 1e-6)
        let arc = try SVGParser.parse(svg("<path d=\"M10 25 a15 15 0 1 1 30 0\"/>"))
        let b = VectorMath.bounds(arc)
        XCTAssertEqual(b.width, 30, accuracy: 0.05); XCTAssertEqual(b.height, 15, accuracy: 0.05)
        let compact = try SVGParser.parse(svg("<path d=\"M10 25 a15 15 0 1130 0\"/>"))
        XCTAssertEqual(VectorMath.bounds(compact).width, 30, accuracy: 0.05)
    }

    func testRoundedRectAndPolygonAndColourTag() throws {
        let l = try SVGParser.parse(svg("<rect width=\"20\" height=\"10\" rx=\"3\" stroke=\"#FF0000\"/><polygon points=\"0,0 10,0 5,8\" fill=\"blue\"/>"))
        XCTAssertEqual(l.count, 2)
        XCTAssertEqual(l[0].tag, "#ff0000"); XCTAssertEqual(l[1].tag, "blue")
        XCTAssertLessThan(abs(l[0].signedArea), 200)                   // corners are cut off
    }

    func testDefsAreIgnoredAndErrorsAreReported() throws {
        let l = try SVGParser.parse(svg("<defs><rect width=\"5\" height=\"5\"/></defs><rect width=\"10\" height=\"10\"/>"))
        XCTAssertEqual(l.count, 1)
        XCTAssertThrowsError(try SVGParser.parse(Data("hello".utf8)))
        XCTAssertThrowsError(try SVGParser.parse(svg("")))
    }

    func testOptimizerShortensTravelAndKeepsEveryShape() {
        var shapes: [Polyline] = []
        for i in 0..<40 {   // a zig-zag of small segments, deliberately in a bad order
            let x = Double((i * 7) % 40) * 5
            shapes.append(Polyline([Pt(x, 0), Pt(x + 2, 0)]))
        }
        let before = PathOptimizer.travelLength(shapes)
        let out = PathOptimizer.optimize(shapes)
        XCTAssertEqual(out.count, shapes.count)
        XCTAssertLessThan(PathOptimizer.travelLength(out), before / 3)
        XCTAssertEqual(out.map { $0.length }.reduce(0, +), shapes.map { $0.length }.reduce(0, +), accuracy: 1e-9)
    }

    func testInsideShapesAreRunBeforeOutsideOnes() {
        let outer = Polyline([Pt(0, 0), Pt(100, 0), Pt(100, 100), Pt(0, 100)], closed: true)
        let inner = Polyline([Pt(40, 40), Pt(60, 40), Pt(60, 60), Pt(40, 60)], closed: true)
        let out = PathOptimizer.optimize([outer, inner])
        XCTAssertEqual(out.first?.points.count, 4)
        XCTAssertEqual(VectorMath.bounds([out[0]]).width, 20, accuracy: 1e-9)
        XCTAssertEqual(VectorMath.bounds([out[1]]).width, 100, accuracy: 1e-9)
        var o = PathOptimizeOptions(); o.insideFirst = false; o.reorder = false
        XCTAssertEqual(VectorMath.bounds([PathOptimizer.optimize([outer, inner], options: o)[0]]).width, 100, accuracy: 1e-9)
    }

    func testHatchFillsASquareWithoutLeavingIt() {
        let sq = Polyline([Pt(0, 0), Pt(10, 0), Pt(10, 10), Pt(0, 10)], closed: true)
        let h = VectorJob.hatch([sq], spacing: 1, angle: 0, serpentine: true)
        XCTAssertEqual(h.count, 10)
        for l in h { XCTAssertEqual(l.length, 10, accuracy: 1e-6) }
        XCTAssertEqual(h[0].points[0].x, 0, accuracy: 1e-6); XCTAssertEqual(h[1].points[0].x, 10, accuracy: 1e-6)   // serpentine
        // a hole is left out (even-odd)
        let hole = Polyline([Pt(4, 4), Pt(6, 4), Pt(6, 6), Pt(4, 6)], closed: true)
        let total = VectorJob.hatch([sq, hole], spacing: 0.5, angle: 0, serpentine: false).map { $0.length }.reduce(0, +)
        XCTAssertEqual(total, (100 - 4) / 0.5, accuracy: 1.0)   // area / spacing
        // rotated hatch stays inside
        let rot = VectorJob.hatch([sq], spacing: 1, angle: 45, serpentine: true)
        let b = VectorMath.bounds(rot)
        XCTAssertGreaterThanOrEqual(b.minX, -1e-6); XCTAssertLessThanOrEqual(b.maxX, 10 + 1e-6)
    }

    func testGCodeIsValidAndParsesBackToTheSameShape() {
        let sq = Polyline([Pt(5, 5), Pt(25, 5), Pt(25, 15), Pt(5, 15)], closed: true)
        var s = VectorSettings(); s.speed = 800; s.powerPercent = 50; s.passes = 2
        let lines = VectorJob.gcode([sq], s, maxS: 1000)
        XCTAssertTrue(lines.contains("M4 S500"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("G1") && $0.contains("F800") })
        XCTAssertEqual(lines.filter { $0 == "M4 S500" }.count, 2)             // one per pass
        let p = GCodeProgram(text: lines.joined(separator: "\n"))
        XCTAssertEqual(p.burnBounds.width, 20, accuracy: 1e-6)
        XCTAssertEqual(p.burnBounds.height, 10, accuracy: 1e-6)
        XCTAssertEqual(p.burnLength, 60 * 2, accuracy: 1e-6)
        s.dynamicPower = false
        XCTAssertTrue(VectorJob.gcode([sq], s).contains("M3 S1000") == false)
        XCTAssertTrue(VectorJob.gcode([sq], s).contains("M3 S500"))
    }

    func testFillModeBurnsMoreThanTheOutline() {
        let sq = Polyline([Pt(0, 0), Pt(10, 0), Pt(10, 10), Pt(0, 10)], closed: true)
        var s = VectorSettings(); s.mode = .fill; s.fillSpacing = 0.5
        let p = GCodeProgram(text: VectorJob.gcode([sq], s).joined(separator: "\n"))
        XCTAssertGreaterThan(p.burnLength, 150)
    }

    func testHersheyTextHasTheRequestedCapHeightAndPlaceholders() {
        var spec = TextSpec(); spec.text = "HELLO"; spec.size = 10
        let l = TextLayout.polylines(spec)
        let b = VectorMath.bounds(l)
        XCTAssertEqual(b.minX, 0, accuracy: 1e-9); XCTAssertEqual(b.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(b.height, 10, accuracy: 0.3)
        XCTAssertGreaterThan(b.width, 30)
        spec.text = "HELLO\nWORLD"
        let two = VectorMath.bounds(TextLayout.polylines(spec))
        XCTAssertEqual(two.height, 10 + 14, accuracy: 0.5)
        XCTAssertEqual(TextTemplate.expand("No {n:4} {date}", serial: 7, date: Date(timeIntervalSince1970: 0)).hasPrefix("No 0007 19"), true)
        XCTAssertEqual(TextTemplate.expand("{n}", serial: 12), "12")
        spec.fontName = "Helvetica"; spec.text = "Hi"; spec.size = 10
        let o = TextLayout.polylines(spec)
        XCTAssertFalse(o.isEmpty)
        XCTAssertEqual(VectorMath.bounds(o).height, 10, accuracy: 1.0)
        XCTAssertTrue(TextLayout.availableFonts().first == "Hershey")
    }

    func testEveryPrintableCharacterHasAGlyph() {
        XCTAssertEqual(HersheyData.glyphs.count, 95)
        var spec = TextSpec()
        spec.text = String((33...126).map { Character(UnicodeScalar($0)!) })
        XCTAssertGreaterThan(TextLayout.polylines(spec).count, 90)
    }
}
