import XCTest
@testable import LaserGRBLCore

/// Files from the internet are not trustworthy: whatever they contain, reading them must finish quickly, must not crash and
/// must either give shapes with finite coordinates or a clear error.
final class HostileInputTests: XCTestCase {
    func finite(_ lines: [Polyline], file: StaticString = #filePath, line: UInt = #line) {
        for l in lines { for p in l.points { XCTAssertTrue(p.x.isFinite && p.y.isFinite, "non-finite point", file: file, line: line) } }
    }

    func timed(_ name: String, limit: TimeInterval = 5, _ body: () throws -> [Polyline]) {
        let t = Date()
        do { finite(try body()) } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(t), limit, "\(name) took too long")
    }

    func svg(_ body: String) -> Data { Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100mm\" height=\"100mm\" viewBox=\"0 0 100 100\">\(body)</svg>".utf8) }

    func testSVGWithAbsurdNumbers() {
        let bodies = [
            "<path d=\"M0 0 A1e300 1e300 0 1 1 100 100\"/>",
            "<path d=\"M0 0 C 1e308 1e308 -1e308 1e308 100 100\"/>",
            "<circle cx=\"50\" cy=\"50\" r=\"1e12\"/>",
            "<circle cx=\"50\" cy=\"50\" r=\"1e-12\"/>",
            "<ellipse cx=\"0\" cy=\"0\" rx=\"1e9\" ry=\"1e-9\"/>",
            "<path d=\"M nan nan L inf inf\"/>",
            "<path d=\"M 0 0 L 1e999 5\"/>",
            "<rect width=\"1e308\" height=\"1e308\" rx=\"1e308\"/>",
            "<g transform=\"scale(1e200)\"><path d=\"M0 0 L1 1\"/></g>",
            "<g transform=\"matrix(0 0 0 0 0 0)\"><circle r=\"5\"/></g>",
            "<path d=\"" + String(repeating: "M0 0 L1 1 ", count: 60_000) + "\"/>",
            "<polyline points=\"" + String(repeating: "1,2 ", count: 100_000) + "\"/>",
            String(repeating: "<g>", count: 20_000) + "<path d=\"M0 0 L5 5\"/>" + String(repeating: "</g>", count: 20_000),
        ]
        for (i, b) in bodies.enumerated() { timed("svg #\(i)") { try SVGParser.parse(svg(b)) } }
    }

    func testSVGThatIsNotWellFormedOrNotSVG() {
        for s in ["", "<svg", "<svg><g></svg>", "</g></g></g>", "<html><body>hi</body></html>", "\u{0}\u{1}\u{2}", "<svg><path d=\"M\"/></svg>", "<svg><path d=\"L 5 5\"/></svg>"] {
            timed("svg junk") { try SVGParser.parse(Data(s.utf8)) }
        }
    }

    func testDXFWithAbsurdValuesAndTruncatedFiles() {
        func dxf(_ e: String) -> Data { Data("0\nSECTION\n2\nENTITIES\n\(e)0\nENDSEC\n0\nEOF\n".utf8) }
        let cases = [
            "0\nCIRCLE\n10\n0\n20\n0\n40\n1e300\n",
            "0\nCIRCLE\n10\n0\n20\n0\n40\n1e-300\n",
            "0\nCIRCLE\n10\n0\n20\n0\n40\n-5\n",
            "0\nARC\n10\n0\n20\n0\n40\n10\n50\n0\n51\n1e308\n",
            "0\nARC\n10\n0\n20\n0\n40\n10\n50\n-1e308\n51\n360\n",
            "0\nELLIPSE\n10\n0\n20\n0\n11\n0\n21\n0\n40\n0\n41\n0\n42\n6.28\n",
            "0\nELLIPSE\n10\n0\n20\n0\n11\n1e300\n21\n1e300\n40\n1e300\n",
            "0\nLWPOLYLINE\n70\n1\n10\n0\n20\n0\n42\n1e308\n10\n5\n20\n0\n42\n-1e308\n10\n5\n20\n5\n",
            "0\nLWPOLYLINE\n70\n1\n10\n0\n20\n0\n42\n1\n10\n0\n20\n0\n",
            "0\nSPLINE\n71\n3\n73\n2\n40\n0\n40\n0\n40\n0\n40\n0\n40\n1\n40\n1\n40\n1\n40\n1\n10\n0\n20\n0\n10\n1\n20\n1\n",
            "0\nSPLINE\n71\n999999\n10\n0\n20\n0\n10\n1\n20\n1\n",
            "0\nSPLINE\n71\n3\n73\n4\n40\n5\n40\n5\n40\n5\n40\n5\n40\n5\n40\n5\n40\n5\n40\n5\n40\n5\n10\n0\n20\n0\n10\n1\n20\n1\n10\n2\n20\n2\n10\n3\n20\n3\n",
            "0\nINSERT\n2\nNOPE\n10\n0\n20\n0\n",
        ]
        for (i, c) in cases.enumerated() { timed("dxf #\(i)") { try DXFParser.parse(dxf(c)) } }
        let good = String(data: dxf("0\nLINE\n10\n0\n20\n0\n11\n5\n21\n5\n"), encoding: .utf8)!
        for cut in stride(from: 0, to: good.count, by: 3) {
            timed("truncated dxf") { try DXFParser.parse(Data(good.prefix(cut).utf8)) }
        }
    }

    func testBlocksThatInsertThemselvesDoNotLoopForever() {
        let d = "0\nSECTION\n2\nBLOCKS\n0\nBLOCK\n2\nA\n0\nINSERT\n2\nA\n10\n1\n20\n1\n41\n2\n42\n2\n0\nLINE\n10\n0\n20\n0\n11\n1\n21\n1\n0\nENDBLK\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nINSERT\n2\nA\n0\nENDSEC\n0\nEOF\n"
        timed("recursive block") { try DXFParser.parse(Data(d.utf8)) }
    }

    func testPDFGarbage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lg-bad-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF".utf8).write(to: url)
        timed("bad pdf") { try PDFImport.parse(contentsOf: url) }
        try Data(repeating: 0x25, count: 5000).write(to: url)
        timed("junk pdf") { try PDFImport.parse(contentsOf: url) }
    }
}
