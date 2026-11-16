import XCTest
import CoreGraphics
@testable import LaserGRBLCore

final class DXFTests: XCTestCase {
    func dxf(_ units: Int?, _ entities: String, blocks: String = "") -> Data {
        var s = "0\nSECTION\n2\nHEADER\n"
        if let u = units { s += "9\n$INSUNITS\n70\n\(u)\n" }
        s += "0\nENDSEC\n0\nSECTION\n2\nBLOCKS\n\(blocks)0\nENDSEC\n0\nSECTION\n2\nENTITIES\n\(entities)0\nENDSEC\n0\nEOF\n"
        return Data(s.utf8)
    }

    func testLinesCirclesAndLayers() throws {
        let d = dxf(4, "0\nLINE\n8\ncut\n10\n0\n20\n0\n11\n30\n21\n40\n0\nCIRCLE\n8\nmark\n10\n50\n20\n50\n40\n10\n")
        let r = try DXFParser.parse(d)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].tag, "cut"); XCTAssertEqual(r[0].points, [Pt(0, 0), Pt(30, 40)])
        XCTAssertTrue(r[1].closed); XCTAssertEqual(r[1].tag, "mark")
        let b = VectorMath.bounds([r[1]])
        XCTAssertEqual(b.width, 20, accuracy: 0.05); XCTAssertEqual(b.minX, 40, accuracy: 0.05)
        XCTAssertGreaterThan(r[1].points.count, 24)
    }

    func testUnitsAreConvertedToMillimetres() throws {
        let line = "0\nLINE\n8\n0\n10\n0\n20\n0\n11\n2\n21\n0\n"
        XCTAssertEqual(VectorMath.bounds(try DXFParser.parse(dxf(1, line))).width, 50.8, accuracy: 1e-9, "inches")
        XCTAssertEqual(VectorMath.bounds(try DXFParser.parse(dxf(5, line))).width, 20, accuracy: 1e-9, "cm")
        XCTAssertEqual(VectorMath.bounds(try DXFParser.parse(dxf(nil, line))).width, 2, accuracy: 1e-9, "unknown = mm")
    }

    func testArcGoesCounterClockwiseFromStartToEndAngle() throws {
        let r = try DXFParser.parse(dxf(4, "0\nARC\n8\n0\n10\n0\n20\n0\n40\n10\n50\n0\n51\n90\n"))
        XCTAssertEqual(r[0].points.first!.x, 10, accuracy: 1e-9); XCTAssertEqual(r[0].points.first!.y, 0, accuracy: 1e-9)
        XCTAssertEqual(r[0].points.last!.x, 0, accuracy: 1e-9); XCTAssertEqual(r[0].points.last!.y, 10, accuracy: 1e-9)
        XCTAssertFalse(r[0].closed)
        for p in r[0].points { XCTAssertEqual((p.x * p.x + p.y * p.y).squareRoot(), 10, accuracy: 1e-6) }
        // an arc whose end angle is smaller than its start wraps around through 0°
        let w = try DXFParser.parse(dxf(4, "0\nARC\n8\n0\n10\n0\n20\n0\n40\n10\n50\n270\n51\n90\n"))
        XCTAssertGreaterThan(VectorMath.bounds(w).maxX, 9.9); XCTAssertLessThan(VectorMath.bounds(w).minX, 0.1)
    }

    func testLightweightPolylineWithBulgeAndClosing() throws {
        // a rectangle 20 x 10 with a half-circle bulge on its right side
        let e = "0\nLWPOLYLINE\n8\n0\n90\n4\n70\n1\n10\n0\n20\n0\n10\n20\n20\n0\n42\n1\n10\n20\n20\n10\n10\n0\n20\n10\n"
        let r = try DXFParser.parse(dxf(4, e))
        XCTAssertTrue(r[0].closed)
        let b = VectorMath.bounds(r)
        XCTAssertEqual(b.maxX, 25, accuracy: 0.05, "the bulge of a half circle over a 10 mm side reaches 5 mm out")
        XCTAssertEqual(b.minX, 0, accuracy: 1e-9)
    }

    func testClassicPolylineSplineEllipseAndInsert() throws {
        let poly = "0\nPOLYLINE\n8\n0\n70\n0\n0\nVERTEX\n8\n0\n10\n0\n20\n0\n0\nVERTEX\n8\n0\n10\n5\n20\n5\n0\nVERTEX\n8\n0\n10\n10\n20\n0\n0\nSEQEND\n"
        XCTAssertEqual(try DXFParser.parse(dxf(4, poly))[0].points.count, 3)
        // a quadratic B-spline through three control points, clamped: starts and ends at the end control points
        let spl = "0\nSPLINE\n8\n0\n70\n8\n71\n2\n72\n6\n73\n3\n40\n0\n40\n0\n40\n0\n40\n1\n40\n1\n40\n1\n10\n0\n20\n0\n10\n5\n20\n10\n10\n10\n20\n0\n"
        let s = try DXFParser.parse(dxf(4, spl))[0]
        XCTAssertEqual(s.points.first!.x, 0, accuracy: 1e-9); XCTAssertEqual(s.points.last!.x, 10, accuracy: 1e-9)
        XCTAssertEqual(VectorMath.bounds([s]).maxY, 5, accuracy: 0.05, "the curve peaks half way to the middle control point")
        let ell = "0\nELLIPSE\n8\n0\n10\n0\n20\n0\n11\n10\n21\n0\n40\n0.5\n41\n0\n42\n6.283185307179586\n"
        let eb = VectorMath.bounds(try DXFParser.parse(dxf(4, ell)))
        XCTAssertEqual(eb.width, 20, accuracy: 0.05); XCTAssertEqual(eb.height, 10, accuracy: 0.05)
        // a block inserted twice, the second time scaled by 2, turned by 90° and moved
        let block = "0\nBLOCK\n8\n0\n2\nB\n10\n0\n20\n0\n0\nLINE\n8\n0\n10\n0\n20\n0\n11\n10\n21\n0\n0\nENDBLK\n"
        let ins = "0\nINSERT\n8\n0\n2\nB\n10\n100\n20\n0\n0\nINSERT\n8\n0\n2\nB\n10\n0\n20\n50\n41\n2\n42\n2\n50\n90\n"
        let r = try DXFParser.parse(dxf(4, ins, blocks: block))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].points, [Pt(100, 0), Pt(110, 0)])
        XCTAssertEqual(r[1].points[0].x, 0, accuracy: 1e-9); XCTAssertEqual(r[1].points[0].y, 50, accuracy: 1e-9)
        XCTAssertEqual(r[1].points[1].x, 0, accuracy: 1e-9); XCTAssertEqual(r[1].points[1].y, 70, accuracy: 1e-9, "10 mm x 2, turned to point up")
    }

    func testBadFilesGiveClearErrors() {
        XCTAssertThrowsError(try DXFParser.parse(Data("hello world\nthis is no drawing".utf8))) { XCTAssertEqual($0 as? DXFError, .notDXF) }
        XCTAssertThrowsError(try DXFParser.parse(Data("AutoCAD Binary DXF\r\n\u{1a}\0".utf8))) { XCTAssertEqual($0 as? DXFError, .binary) }
        XCTAssertThrowsError(try DXFParser.parse(dxf(4, "0\nTEXT\n8\n0\n1\nhi\n"))) { XCTAssertEqual($0 as? DXFError, .empty) }
    }
}

extension DXFError: Equatable {}

final class PDFImportTests: XCTestCase {
    func makePDF(_ draw: (CGContext) -> Void) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lg-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)                    // points
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage(); ctx.closePDF()
        return url
    }

    func testLinesRectanglesAndCurvesBecomePolylinesInMillimetres() throws {
        let url = try makePDF { c in
            c.setFillColor(gray: 1, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: 200, height: 100))       // white background
            c.setStrokeColor(gray: 0, alpha: 1)
            c.stroke(CGRect(x: 10, y: 20, width: 72, height: 36))
            c.move(to: CGPoint(x: 100, y: 10)); c.addLine(to: CGPoint(x: 172, y: 10)); c.strokePath()
            c.addEllipse(in: CGRect(x: 100, y: 30, width: 72, height: 72 * 0.5)); c.strokePath()
        }
        let r = try PDFImport.parse(contentsOf: url)
        XCTAssertEqual(r.count, 3, "the page-sized background is left out")
        let rect = r.first { $0.closed && $0.points.count <= 5 }!
        let rb = VectorMath.bounds([rect])
        XCTAssertEqual(rb.width, 25.4, accuracy: 1e-6, "72 pt = 1 inch"); XCTAssertEqual(rb.height, 12.7, accuracy: 1e-6)
        XCTAssertEqual(rb.minX, 10 * 25.4 / 72, accuracy: 1e-6); XCTAssertEqual(rb.minY, 20 * 25.4 / 72, accuracy: 1e-6, "Y points up from the page's lower edge")
        let line = r.first { !$0.closed }!
        XCTAssertEqual(line.length, 25.4, accuracy: 1e-6)
        let ell = r.first { $0.closed && $0.points.count > 8 }!
        let eb = VectorMath.bounds([ell])
        XCTAssertEqual(eb.width, 25.4, accuracy: 0.05); XCTAssertEqual(eb.height, 12.7, accuracy: 0.05)
        XCTAssertEqual(PDFImport.pageCount(of: url), 1)
    }

    func testPicturesOnlyPageAndMissingPageAreReported() throws {
        let url = try makePDF { _ in }
        XCTAssertThrowsError(try PDFImport.parse(contentsOf: url)) { XCTAssertEqual($0 as? PDFImportError, .empty) }
        XCTAssertThrowsError(try PDFImport.parse(contentsOf: url, page: 2)) { XCTAssertEqual($0 as? PDFImportError, .noSuchPage) }
        XCTAssertThrowsError(try PDFImport.parse(contentsOf: URL(fileURLWithPath: "/nonexistent.pdf"))) { XCTAssertEqual($0 as? PDFImportError, .unreadable) }
    }

    func testTransformsInsideSavedGraphicsStatesAreApplied() throws {
        let url = try makePDF { c in
            c.saveGState(); c.translateBy(x: 50, y: 10); c.scaleBy(x: 2, y: 2)
            c.move(to: .zero); c.addLine(to: CGPoint(x: 36, y: 0)); c.strokePath(); c.restoreGState()
            c.move(to: CGPoint(x: 0, y: 90)); c.addLine(to: CGPoint(x: 72, y: 90)); c.strokePath()
        }
        let r = try PDFImport.parse(contentsOf: url)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].length, 36 * 2 * 25.4 / 72, accuracy: 1e-6)
        XCTAssertEqual(r[1].length, 25.4, accuracy: 1e-6, "the scale does not leak out of q … Q")
    }
}

extension PDFImportError: Equatable {}
