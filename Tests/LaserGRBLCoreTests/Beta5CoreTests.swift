import XCTest
import CoreGraphics
@testable import LaserGRBLCore

final class LayoutGeometryTests: XCTestCase {
    func box(_ name: String, x: Double, y: Double, w: Double, h: Double, rotation: Double = 0) -> LayoutObject {
        var o = LayoutObject(name: name, kind: .vectors([Polyline([Pt(0, 0), Pt(10, 0), Pt(10, 10), Pt(0, 10)], closed: true)]), layer: 0)
        o.x = x; o.y = y; o.width = w; o.height = h; o.rotation = rotation
        return o
    }

    func testTurnedObjectsHaveTurnedBoxesAndHitTests() {
        var o = box("a", x: 10, y: 20, w: 40, h: 10, rotation: 90)
        let c = o.orientedCorners()
        XCTAssertEqual(c.count, 4)
        // centre stays at (30, 25); turned by 90° the box is 10 wide and 40 high
        let b = VectorMath.bounds([Polyline(c, closed: true)])
        XCTAssertEqual(b.width, 10, accuracy: 1e-9); XCTAssertEqual(b.height, 40, accuracy: 1e-9)
        XCTAssertEqual((b.minX + b.maxX) / 2, 30, accuracy: 1e-9)
        XCTAssertTrue(o.contains(Pt(30, 44)), "up in the turned box")
        XCTAssertFalse(o.contains(Pt(45, 25)), "that was inside before the turn")
        o.rotation = 0
        XCTAssertTrue(o.contains(Pt(45, 25)))
        XCTAssertEqual(o.localPoint(Pt(10, 20)).x, 0, accuracy: 1e-9)
        o.rotation = 45
        let b45 = o.boundsInWorld()
        XCTAssertEqual(b45.width, (40 + 10) / 2.0.squareRoot(), accuracy: 1e-6)
    }

    func testPicturesTurnByAnyAngleWhenTheJobIsMade() {
        let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let img = ctx.makeImage()!
        var doc = LayoutDocument()
        var o = LayoutObject(name: "pic", kind: .image(imageID: "a", options: RasterOptions()), layer: 0)
        o.x = 50; o.y = 50; o.width = 20; o.height = 20
        doc.objects = [o]
        let flat = GCodeProgram(text: doc.generate { _ in img }.joined(separator: "\n"))
        XCTAssertEqual(flat.burnBounds.width, 20, accuracy: 0.7)
        doc.objects[0].rotation = 45
        let turned = GCodeProgram(text: doc.generate { _ in img }.joined(separator: "\n"))
        let diag = 20 * 2.0.squareRoot()
        XCTAssertEqual(turned.burnBounds.width, diag, accuracy: 1.5, "a square turned by 45° is as wide as its diagonal")
        XCTAssertEqual((turned.burnBounds.minX + turned.burnBounds.maxX) / 2, 60, accuracy: 0.7, "turns around its centre")
        XCTAssertLessThan(turned.burnLength, flat.burnLength * 1.5, "the white corners of the new sheet are not engraved")
        doc.objects[0].rotation = 90
        let right = GCodeProgram(text: doc.generate { _ in img }.joined(separator: "\n"))
        XCTAssertEqual(right.burnBounds.width, 20, accuracy: 0.7)
    }

    func testArrayOfObjects() {
        var doc = LayoutDocument()
        var spec = TextSpec(); spec.text = "No {n:3}"; spec.size = 5
        var t = LayoutObject(name: "label", kind: .text(spec), layer: 0)
        let (w, h) = t.nativeSize(); t.width = w; t.height = h; t.x = 10; t.y = 10
        doc.objects = [t]
        let all = doc.arrayObjects(of: t.id, rows: 2, columns: 3, gapX: 5, gapY: 2, numberFrom: 7)
        XCTAssertEqual(all.count, 6)
        XCTAssertEqual(all[0].id, t.id, "the first one is the object itself")
        XCTAssertEqual(Set(all.map { $0.id }).count, 6)
        XCTAssertEqual(all[1].x, 10 + w + 5, accuracy: 1e-9); XCTAssertEqual(all[1].y, 10, accuracy: 1e-9)
        XCTAssertEqual(all[3].x, 10, accuracy: 1e-9); XCTAssertEqual(all[3].y, 10 + h + 2, accuracy: 1e-9)
        let texts = all.compactMap { o -> String? in if case .text(let s) = o.kind { return s.text }; return nil }
        XCTAssertEqual(texts, ["No 007", "No 008", "No 009", "No 010", "No 011", "No 012"])
        XCTAssertEqual(doc.arrayObjects(of: t.id, rows: 1, columns: 2, gapX: 0, gapY: 0).count, 2)
        if case .text(let s) = doc.arrayObjects(of: t.id, rows: 1, columns: 2, gapX: 0, gapY: 0)[1].kind { XCTAssertEqual(s.text, "No {n:3}", "no numbering unless asked") }
        XCTAssertTrue(doc.arrayObjects(of: "missing", rows: 2, columns: 2, gapX: 1, gapY: 1).isEmpty)
        XCTAssertTrue(doc.arrayObjects(of: t.id, rows: 0, columns: 2, gapX: 1, gapY: 1).isEmpty)
    }

    func testAlignAndDistribute() {
        var doc = LayoutDocument()
        doc.objects = [box("a", x: 0, y: 0, w: 10, h: 10), box("b", x: 30, y: 5, w: 20, h: 10), box("c", x: 100, y: 40, w: 10, h: 20)]
        let ids = doc.objects.map { $0.id }
        var o = doc.alignOffsets(ids: ids, edge: .left)
        XCTAssertEqual(o[ids[1]]?.x ?? 0, -30, accuracy: 1e-9); XCTAssertEqual(o[ids[2]]?.x ?? 0, -100, accuracy: 1e-9); XCTAssertEqual(o[ids[0]]?.x ?? 1, 0, accuracy: 1e-9)
        o = doc.alignOffsets(ids: ids, edge: .right)
        XCTAssertEqual(o[ids[0]]?.x ?? 0, 100, accuracy: 1e-9)       // group right edge is 110
        o = doc.alignOffsets(ids: ids, edge: .centerY)
        let midY = (0.0 + 60) / 2
        XCTAssertEqual((doc.objects[0].y + 5) + (o[ids[0]]?.y ?? 0), midY, accuracy: 1e-9)
        var area = Bounds(); area.add(0, 0); area.add(300, 200)
        o = doc.alignOffsets(ids: [ids[1]], edge: .centerX, within: area)
        XCTAssertEqual(doc.objects[1].x + 10 + (o[ids[1]]?.x ?? 0), 150, accuracy: 1e-9, "a single object is centred on the work area")
        o = doc.alignOffsets(ids: [ids[1]], edge: .bottom, within: area)
        XCTAssertEqual(doc.objects[1].y + (o[ids[1]]?.y ?? 0), 0, accuracy: 1e-9)
        // distribute: gaps become equal, outer objects stay
        let d = doc.distributeOffsets(ids: ids, axis: .horizontal)
        XCTAssertEqual(d[ids[0]]?.x ?? 1, 0, accuracy: 1e-9); XCTAssertEqual(d[ids[2]]?.x ?? 1, 0, accuracy: 1e-9)
        // total 110, sizes 10+20+10 = 40, two gaps of 35 -> b starts at 45
        XCTAssertEqual(doc.objects[1].x + (d[ids[1]]?.x ?? 0), 45, accuracy: 1e-9)
        XCTAssertTrue(doc.distributeOffsets(ids: [ids[0], ids[1]], axis: .vertical).isEmpty, "needs three objects")
    }
}

final class CurveFitTests: XCTestCase {
    func circle(_ r: Double, n: Int = 400) -> [Pt] { (0..<n).map { Pt(100 + r * cos(Double($0) / Double(n) * 2 * .pi), 100 + r * sin(Double($0) / Double(n) * 2 * .pi)) } }

    func testASmoothLoopBecomesFewPointsWithinTolerance() {
        let src = circle(30)
        let out = CurveFit.smooth(src, closed: true, tolerance: 0.5, cornerAngle: 60, flatness: 0.1)
        XCTAssertLessThan(out.count, 80, "fewer points than the 400 samples: \\(out.count)")
        XCTAssertGreaterThan(out.count, 12)
        for p in out { XCTAssertEqual(p.distance(to: Pt(100, 100)), 30, accuracy: 0.6) }
        XCTAssertEqual(abs(Polyline(out, closed: true).signedArea), Double.pi * 900, accuracy: Double.pi * 900 * 0.01)
    }

    func testCornersStaySharp() {
        // a rectangle walked in unit steps, like a pixel outline
        var pts: [Pt] = []
        for x in 0..<40 { pts.append(Pt(Double(x), 0)) }
        for y in 0..<20 { pts.append(Pt(40, Double(y))) }
        for x in 0..<40 { pts.append(Pt(Double(40 - x), 20)) }
        for y in 0..<20 { pts.append(Pt(0, Double(20 - y))) }
        let out = CurveFit.smooth(pts, closed: true, tolerance: 0.5, cornerAngle: 60)
        XCTAssertLessThan(out.count, 40)
        for corner in [Pt(0, 0), Pt(40, 0), Pt(40, 20), Pt(0, 20)] {
            XCTAssertLessThan(out.map { $0.distance(to: corner) }.min()!, 1.8, "a point near \\(corner)")
        }
        let b = VectorMath.bounds([Polyline(out, closed: true)])
        XCTAssertEqual(b.width, 40, accuracy: 1.5); XCTAssertEqual(b.height, 20, accuracy: 1.5)
    }

    func testOpenLinesKeepTheirEnds() {
        let line = (0...60).map { Pt(Double($0), 5 * sin(Double($0) / 10)) }
        let out = CurveFit.smooth(line, closed: false, tolerance: 0.4)
        XCTAssertEqual(out.first!.x, 0, accuracy: 1e-6); XCTAssertEqual(out.last!.x, 60, accuracy: 1e-6)
        XCTAssertLessThan(out.count, line.count)
    }

    func testTracerGivesSmoothCircleOutlinesWithFewerPoints() {
        let w = 120, h = 120
        var g = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h { for x in 0..<w { let dx = Double(x - 60), dy = Double(y - 60); if dx * dx + dy * dy < 45 * 45 { g[y * w + x] = 0 } } }
        var stairs = TraceOptions(); stairs.curves = false; stairs.smoothing = 0; stairs.tolerance = 0.3
        var curved = TraceOptions(); curved.curves = true
        let a = Tracer.trace(gray: g, width: w, height: h, options: stairs)
        let b = Tracer.trace(gray: g, width: w, height: h, options: curved)
        XCTAssertEqual(a.count, 1); XCTAssertEqual(b.count, 1)
        XCTAssertLessThan(b[0].points.count, a[0].points.count, "curves: \\(b[0].points.count), stairs: \\(a[0].points.count)")
        XCTAssertEqual(abs(b[0].signedArea), Double.pi * 45 * 45, accuracy: Double.pi * 45 * 45 * 0.02)
        // smooth: the distance to the centre barely varies
        let pts = b[0].points
        let c = Pt(60.5, 59.5)                     // pixel centre (60, 60), y pointing up
        let radii = pts.map { $0.distance(to: c) }
        XCTAssertLessThan(radii.max()! - radii.min()!, 1.6, "radii \(radii.min()!)...\(radii.max()!)")
    }
}

final class ScanOffsetTests: XCTestCase {
    func testBackwardLinesAreShiftedForwardLinesAreNot() {
        var o = RasterOptions()
        o.tool = .lineToLine; o.direction = .horizontal; o.linesPerMM = 1; o.widthMM = 10; o.heightMM = 2; o.maxPower = 1000; o.minPower = 0
        let gray = [UInt8](repeating: 0, count: 20)
        let plain = RasterConverter.generate(gray: gray, width: 10, height: 2, options: o)
        o.scanOffsetMM = 0.5
        let shifted = RasterConverter.generate(gray: gray, width: 10, height: 2, options: o)
        XCTAssertNotEqual(plain, shifted)
        let before = GCodeProgram(text: plain), after = GCodeProgram(text: shifted)
        XCTAssertEqual(before.burnBounds.minX, 0, accuracy: 1e-6); XCTAssertEqual(before.burnBounds.maxX, 10, accuracy: 1e-6)
        XCTAssertEqual(after.burnBounds.maxX, 10, accuracy: 1e-6, "the forward line is untouched")
        XCTAssertEqual(after.burnBounds.minX, 0, accuracy: 1e-6)
        XCTAssertTrue(shifted.contains("X0.5"), "the backward line ends 0.5 mm further: \\(shifted)")
        // one-directional engraving needs no correction
        o.unidirectional = true
        XCTAssertEqual(RasterConverter.generate(gray: gray, width: 10, height: 2, options: o), RasterConverter.generate(gray: gray, width: 10, height: 2, options: { var p = o; p.scanOffsetMM = nil; return p }()))
    }

    func testOldPresetsWithoutTheNewFieldStillLoad() throws {
        let data = try JSONEncoder().encode(RasterOptions())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "scanOffsetMM")
        let old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try JSONDecoder().decode(RasterOptions.self, from: old).scanOffsetMM, nil)
        var o = RasterOptions(); o.scanOffsetMM = 0.15
        XCTAssertEqual(try JSONDecoder().decode(RasterOptions.self, from: try JSONEncoder().encode(o)).scanOffsetMM, 0.15)
    }

    func testTheTestPatternHasOneBlockPerOffsetAndLabels() {
        let lines = TestPatterns.scanOffsetTest(offsets: [-0.2, 0, 0.2])
        XCTAssertEqual(lines.filter { $0.hasPrefix("; scan offset") }.count, 3)
        XCTAssertTrue(lines.contains("; scan offset -0.2 mm"))
        let p = GCodeProgram(text: lines.joined(separator: "\n"))
        XCTAssertGreaterThan(p.burnBounds.width, 30)
        XCTAssertLessThan(p.burnBounds.minY, 0, "numbers below the blocks")
        let l0 = lines.firstIndex(of: "; scan offset 0 mm")!, l1 = lines.firstIndex(of: "; scan offset 0.2 mm")!
        XCTAssertNotEqual(Array(lines[(l0 + 1)..<min(l0 + 12, l1)]).map { $0.replacingOccurrences(of: "X", with: "") }.count, 0)
    }
}

final class OlderGrblTests: XCTestCase {
    func testGrbl09StatusLines() {
        let idle = GrblParser.parseStatus("<Idle,MPos:1.000,2.000,3.000,WPos:0.500,1.500,2.500>")
        XCTAssertEqual(idle?.state, .idle)
        XCTAssertEqual(idle?.mpos?.x, 1); XCTAssertEqual(idle?.mpos?.y, 2)
        XCTAssertEqual(idle?.wpos?.x, 0.5); XCTAssertEqual(idle?.wpos?.z, 2.5)
        XCTAssertEqual(GrblParser.parseStatus("<Run,MPos:10.000,0.000,0.000,WPos:10.000,0.000,0.000>")?.state, .run)
        XCTAssertEqual(GrblParser.parseStatus("<Hold,MPos:0.000,0.000,0.000,WPos:0.000,0.000,0.000>")?.state, .hold)
        XCTAssertEqual(GrblParser.parseStatus("<Alarm,MPos:0.000,0.000,0.000,WPos:0.000,0.000,0.000>")?.state, .alarm)
        XCTAssertNil(GrblParser.parseStatus("<Nonsense,MPos:0,0,0>"))
        XCTAssertNil(GrblParser.parseStatus("Idle"))
    }

    func testTextErrorsAnswerALineLikeNumberedOnes() {
        XCTAssertEqual(GrblParser.classify("error: Bad number format"), .error(2))
        XCTAssertEqual(GrblParser.classify("error: Expected command letter"), .error(1))
        XCTAssertEqual(GrblParser.classify("error: Unsupported command"), .error(20))
        XCTAssertEqual(GrblParser.classify("error:20"), .error(20))
        if case .error(let n) = GrblParser.classify("error: Something nobody ever heard of") { XCTAssertEqual(n, 0, "still an error: the job must not wait for an ok") } else { XCTFail() }
        XCTAssertEqual(GrblParser.classify("ALARM: Hard limit"), .alarm(1))
        XCTAssertEqual(GrblParser.classify("ALARM:2"), .alarm(2))
        XCTAssertEqual(GrblParser.classify("ok"), .ok)
    }

    func testWelcomeLinesOfOtherFirmwares() {
        XCTAssertEqual(GrblParser.classify("Grbl 0.9j ['$' for help]"), .welcome("Grbl 0.9j ['$' for help]"))
        XCTAssertEqual(GrblParser.classify("GrblHAL 1.1f ['$' or '$HELP' for help]"), .welcome("GrblHAL 1.1f ['$' or '$HELP' for help]"))
        XCTAssertEqual(GrblParser.parseWelcome("Grbl 0.9j ['$' for help]")?.description, "0.9j")
    }

    func testOldGrblSettingsAndNoRealtimeJog() {
        // 0.9 has no $J= and no real-time overrides: the controller must fall back to G91 moves
        XCTAssertFalse(GrblVersion(major: 0, minor: 9, build: "j") >= GrblVersion(major: 1, minor: 1))
        XCTAssertEqual(GrblParser.classify("$100=250.000"), .setting(100, "250.000"))
        XCTAssertEqual(GrblParser.classify("$0=10"), .setting(0, "10"))
    }
}
