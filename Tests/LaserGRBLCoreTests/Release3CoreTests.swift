import XCTest
import Network
import CoreGraphics
@testable import LaserGRBLCore

final class MaterialAndPatternTests: XCTestCase {
    let res = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")

    func testBuiltInMaterialsLoadAndFilter() throws {
        let db = MaterialDB(builtinData: try Data(contentsOf: res.appendingPathComponent("Materials.json")))
        XCTAssertGreaterThan(db.builtin.count, 800)
        XCTAssertGreaterThan(db.machines.count, 20)
        XCTAssertTrue(db.builtin.allSatisfy { $0.builtin })
        let cuts = db.materials(action: .cut, search: "plywood")
        XCTAssertFalse(cuts.isEmpty)
        XCTAssertTrue(cuts.allSatisfy { $0.action == .cut })
        let ortur = db.materials(machine: "Ortur LU7W (1.5W)")
        XCTAssertFalse(ortur.isEmpty); XCTAssertTrue(ortur.allSatisfy { $0.machine == "Ortur LU7W (1.5W)" })
    }

    func testCustomMaterialsPersistAndCanBeSharedButBuiltInsStayFixed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-mat-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("materials.json")
        let db = MaterialDB(builtinData: try Data(contentsOf: res.appendingPathComponent("Materials.json")), userFile: file)
        let m = LaserMaterial(machine: "My laser", name: "Birch ply", thickness: "3", action: .cut, power: 90, speed: 300, passes: 2)
        db.add(m)
        XCTAssertEqual(db.custom.count, 1)
        XCTAssertEqual(db.all.first?.id, m.id, "own entries are listed first")
        let again = MaterialDB(builtinData: nil, userFile: file)
        XCTAssertEqual(again.custom.first?.name, "Birch ply")
        XCTAssertEqual(again.custom.first?.title, "Birch ply 3 mm")
        let shared = try db.exportCustom()
        let other = MaterialDB(builtinData: nil)
        XCTAssertEqual(try other.importMaterials(shared), 1)
        XCTAssertEqual(other.custom.first?.speed, 300)
        db.remove(id: m.id)
        XCTAssertTrue(MaterialDB(builtinData: nil, userFile: file).custom.isEmpty)
    }

    func testPowerVsSpeedGridCoversEveryCombination() {
        var g = TestPatterns.PowerSpeedGrid()
        g.speedSteps = 4; g.powerSteps = 3; g.speedMin = 1000; g.speedMax = 4000; g.powerMin = 20; g.powerMax = 100
        g.cell = 5; g.gap = 1; g.lineSpacing = 0.5
        XCTAssertEqual(g.speed(column: 3), 4000); XCTAssertEqual(g.power(row: 1), 60)
        let lines = TestPatterns.powerVsSpeed(g, maxS: 1000, labels: false)
        for c in 0..<4 { XCTAssertTrue(lines.contains { $0.contains("F\(Int(g.speed(column: c)))") }, "speed column \(c)") }
        for r in 0..<3 { XCTAssertTrue(lines.contains("M4 S\(Int(g.power(row: r) * 10))"), "power row \(r)") }
        let p = GCodeProgram(text: lines.joined(separator: "\n"))
        XCTAssertEqual(p.burnBounds.width, g.width, accuracy: 0.6)
        XCTAssertEqual(p.burnBounds.height, g.height, accuracy: 0.6)
        // labels add small numbers around the matrix
        let withLabels = GCodeProgram(text: TestPatterns.powerVsSpeed(g, labels: true).joined(separator: "\n"))
        XCTAssertLessThan(withLabels.burnBounds.minY, 0); XCTAssertLessThan(withLabels.burnBounds.minX, 0)
    }

    func testCuttingShakeResolutionAndCalibrationPatterns() {
        let cut = TestPatterns.cuttingTest(TestPatterns.CuttingGrid())
        XCTAssertEqual(cut.filter { $0 == "M4 S1000" }.count, 5 * (1 + 2 + 3))     // one per pass of every square
        let shake = TestPatterns.shakeTest(TestPatterns.Shake())
        XCTAssertTrue(shake.contains { $0.contains("F6000") })
        XCTAssertEqual(GCodeProgram(text: shake.joined(separator: "\n")).burnBounds.width, 20, accuracy: 1e-6)
        let res = TestPatterns.resolutionTest()
        XCTAssertEqual(res.filter { $0.hasPrefix("; line distance") }.count, 6)
        let sq = GCodeProgram(text: TestPatterns.calibrationSquare(size: 100).joined(separator: "\n"))
        XCTAssertEqual(sq.burnBounds.width, 100, accuracy: 1e-6); XCTAssertEqual(sq.burnBounds.height, 100, accuracy: 1e-6)
    }

    func testCalibrationMath() {
        XCTAssertEqual(TestPatterns.stepsPerMM(current: 250, asked: 100, measured: 98.5)!, 253.807, accuracy: 0.001)
        XCTAssertNil(TestPatterns.stepsPerMM(current: 250, asked: 100, measured: 0))
        let k = TestPatterns.kerf(nominal: 10, measuredPiece: 9.8)
        XCTAssertEqual(k.kerf, 0.2, accuracy: 1e-9); XCTAssertEqual(k.offset, 0.1, accuracy: 1e-9)
        // 40 mm/s within a 20 mm stroke -> 40²/(2·20) = 40 mm/s², 80 % of it
        XCTAssertEqual(TestPatterns.accelerationEstimate(cleanFeed: 2400, stroke: 20), 32, accuracy: 1e-9)
    }
}

final class AutoCropTests: XCTestCase {
    func image(_ w: Int, _ h: Int, transparent: Bool, draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !transparent { ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        draw(ctx)
        return ctx.makeImage()!
    }

    func testCropsToADarkSubjectOnWhite() {
        let img = image(400, 300, transparent: false) { c in c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(x: 100, y: 60, width: 200, height: 120)) }
        let r = RasterConverter.subjectCrop(of: img, margin: 0)!
        XCTAssertEqual(r.left, 0.25, accuracy: 0.01); XCTAssertEqual(r.right, 0.25, accuracy: 0.01)
        XCTAssertEqual(r.top, (300 - 180) / 300.0, accuracy: 0.01); XCTAssertEqual(r.bottom, 60 / 300.0, accuracy: 0.01)
        // applying it leaves roughly the subject
        var o = RasterOptions(); o.cropLeft = r.left; o.cropTop = r.top; o.cropRight = r.right; o.cropBottom = r.bottom
        let t = RasterConverter.transformed(img, o)
        XCTAssertEqual(Double(t.width), 200, accuracy: 6); XCTAssertEqual(Double(t.height), 120, accuracy: 6)
    }

    func testTransparentBackgroundAndMargin() {
        let img = image(200, 200, transparent: true) { c in c.setFillColor(red: 0.2, green: 0.1, blue: 0.1, alpha: 1); c.fillEllipse(in: CGRect(x: 50, y: 50, width: 100, height: 100)) }
        let r = RasterConverter.subjectCrop(of: img, margin: 0.02)!
        XCTAssertEqual(r.left, 0.25 - 0.02, accuracy: 0.015)
        XCTAssertEqual(r.top, 0.25 - 0.02, accuracy: 0.015)
    }

    func testNothingToCropWhenThePictureIsEmptyOrFull() {
        let empty = image(100, 100, transparent: false) { _ in }
        XCTAssertNil(RasterConverter.subjectCrop(of: empty))
        let full = image(100, 100, transparent: false) { c in c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100)) }
        XCTAssertNil(RasterConverter.subjectCrop(of: full), "a flat picture has no subject")
        let tight = image(100, 100, transparent: false) { c in c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(x: 1, y: 1, width: 98, height: 98)) }
        XCTAssertNil(RasterConverter.subjectCrop(of: tight), "already tight")
    }
}

final class TracerTests: XCTestCase {
    func image(_ w: Int, _ h: Int, ink: (Int, Int) -> Bool) -> [UInt8] {
        var g = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h { for x in 0..<w where ink(x, y) { g[y * w + x] = 0 } }
        return g
    }

    func testAFilledSquareBecomesOneClosedOutlineOfTheRightSize() {
        let g = image(40, 40) { x, y in x >= 10 && x < 30 && y >= 8 && y < 28 }
        var o = TraceOptions(); o.smoothing = 0; o.curves = false
        let r = Tracer.trace(gray: g, width: 40, height: 40, options: o)
        XCTAssertEqual(r.count, 1)
        XCTAssertTrue(r[0].closed)
        XCTAssertEqual(r[0].points.count, 4)
        let b = VectorMath.bounds(r)
        XCTAssertEqual(b.width, 20, accuracy: 1e-9); XCTAssertEqual(b.height, 20, accuracy: 1e-9)
        XCTAssertEqual(b.minY, 40 - 28, accuracy: 1e-9)             // y axis points up
    }

    func testRingHasAnOuterAndAnInnerOutlineAndNoiseIsDropped() {
        var g = image(60, 60) { x, y in
            let dx = Double(x - 30), dy = Double(y - 30), d = (dx * dx + dy * dy).squareRoot()
            return d < 22 && d > 12
        }
        g[2 * 60 + 2] = 0                                            // one stray pixel
        let r = Tracer.trace(gray: g, width: 60, height: 60)
        XCTAssertEqual(r.count, 2, "outer and inner circle, no dust")
        let areas = r.map { abs($0.signedArea) }.sorted()
        XCTAssertEqual(areas[1], Double.pi * 22 * 22, accuracy: 60)
        XCTAssertEqual(areas[0], Double.pi * 12 * 12, accuracy: 40)
        XCTAssertGreaterThan(r.map { $0.points.count }.max()!, 12, "round shapes keep their points")
    }

    func testInvertAndThreshold() {
        let g = image(30, 30) { x, y in x < 15 }                     // left half black
        var o = TraceOptions(); o.invert = true; o.smoothing = 0; o.curves = false
        let r = Tracer.trace(gray: g, width: 30, height: 30, options: o)
        XCTAssertEqual(VectorMath.bounds(r).minX, 15, accuracy: 1e-9)
        o.invert = false; o.threshold = 0                            // nothing is darker than 0
        XCTAssertTrue(Tracer.trace(gray: g, width: 30, height: 30, options: o).isEmpty)
    }

    func testALargeBusyPictureIsTracedQuickly() {
        let w = 1200, h = 800
        var g = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let v = sin(Double(x) / 9) * cos(Double(y) / 7) + sin(Double(x * y % 997) / 40)
            if v > 0.55 { g[y * w + x] = 0 }
        } }
        let t = Date()
        let r = Tracer.trace(gray: g, width: w, height: h)
        XCTAssertGreaterThan(r.count, 100)
        XCTAssertLessThan(Date().timeIntervalSince(t), 20, "tracing took \(Date().timeIntervalSince(t)) s")
        print("trace time", Date().timeIntervalSince(t), "shapes", r.count)
    }

    func testCenterlineOfAThickLineIsASingleStrokeThroughTheMiddle() {
        let g = image(60, 30) { x, y in x >= 5 && x < 55 && y >= 12 && y < 17 }   // 50 x 5 bar
        var o = TraceOptions(); o.centerline = true
        let r = Tracer.trace(gray: g, width: 60, height: 30, options: o)
        XCTAssertEqual(r.count, 1)
        XCTAssertFalse(r[0].closed)
        XCTAssertGreaterThan(r[0].length, 42)
        XCTAssertLessThan(VectorMath.bounds(r).height, 3)
    }
}

final class ProfileAndLayoutTests: XCTestCase {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("lc-\(UUID().uuidString)") }

    func testProfilesAreFoundByConnectionAndSurviveARestart() {
        let dir = tmp()
        let store = ProfileStore(directory: dir)
        var p = MachineProfile(name: "Ortur")
        p.connection = "/dev/cu.usbserial-110"; p.baud = 250000; p.header = "G21"; p.ratedHours = 5000
        store.upsert(p)
        XCTAssertEqual(store.profile(forConnection: "/dev/cu.usbserial-110")?.baud, 250000)
        XCTAssertNil(store.profile(forConnection: "/dev/cu.other"))
        XCTAssertEqual(ProfileStore(directory: dir).profiles.first?.header, "G21")
        store.delete(id: p.id)
        XCTAssertTrue(ProfileStore(directory: dir).profiles.isEmpty)
    }

    func testUsageStatisticsWeighPowerAndResetWhenTheLaserIsReplaced() {
        let store = ProfileStore(directory: tmp())
        var p = MachineProfile(name: "Diode"); p.ratedHours = 10
        store.upsert(p)
        // a job that burns 60 s at half power
        let prog = GCodeProgram(text: "G21\nG90\nM4 S500\nG1 X100 F6000\nG1 X0\nM5", rapidRate: 6000)
        XCTAssertEqual(prog.burnSeconds, 2, accuracy: 0.01)                      // 200 mm at 6000 mm/min
        XCTAssertEqual(prog.burnPowerSeconds, 1000, accuracy: 1)                 // 2 s x S500
        let e = ProfileStore.entry(profileID: p.id, program: prog, executedCommands: prog.commands.count, seconds: 5, aborted: false,
                                   errors: 0, maxS: 1000, name: "job")
        XCTAssertEqual(e.laserSeconds, 2, accuracy: 0.01); XCTAssertEqual(e.fullPowerSeconds, 1, accuracy: 0.01)
        store.record(e)
        store.record(ProfileStore.entry(profileID: p.id, program: prog, executedCommands: 4, seconds: 2, aborted: true, errors: 0, maxS: 1000, name: "stopped"))
        let s = store.summary(for: p)
        XCTAssertEqual(s.jobs, 2); XCTAssertEqual(s.finished, 1)
        XCTAssertGreaterThan(s.fullPowerHours, 0)
        XCTAssertEqual(store.history(profileID: p.id).count, 2)
        XCTAssertEqual(store.history().first?.job, "stopped")
        store.laserReplaced(id: p.id, at: Date().addingTimeInterval(60))
        XCTAssertEqual(store.summary(for: store.profile(id: p.id)!).jobs, 0, "counters start again")
    }

    func square(_ s: Double) -> [Polyline] { [Polyline([Pt(0, 0), Pt(s, 0), Pt(s, s), Pt(0, s)], closed: true)] }

    func testLayoutObjectsAreScaledTurnedAndMoved() {
        var o = LayoutObject(name: "sq", kind: .vectors(square(10)))
        o.x = 20; o.y = 30; o.width = 40; o.height = 10
        var b = VectorMath.bounds(o.worldShapes())
        XCTAssertEqual(b.minX, 20, accuracy: 1e-9); XCTAssertEqual(b.width, 40, accuracy: 1e-9); XCTAssertEqual(b.height, 10, accuracy: 1e-9)
        o.rotation = 90
        b = VectorMath.bounds(o.worldShapes())
        XCTAssertEqual(b.width, 10, accuracy: 1e-9); XCTAssertEqual(b.height, 40, accuracy: 1e-9)
        XCTAssertEqual((b.minX + b.maxX) / 2, 40, accuracy: 1e-9)               // turns around its centre
    }

    func testLayersRunInOrderAndObjectsKeepTheirOwnSettings() {
        var doc = LayoutDocument()
        doc.layers[0].speed = 3000; doc.layers[0].powerPercent = 20            // engrave
        doc.layers[1].speed = 200; doc.layers[1].powerPercent = 100; doc.layers[1].passes = 1   // cut
        var text = LayoutObject(name: "t", kind: .text(TextSpec()), layer: 0)
        let (w, h) = text.nativeSize(); text.width = w; text.height = h; text.x = 5; text.y = 5
        var cut = LayoutObject(name: "outline", kind: .vectors(square(50)), layer: 1); cut.x = 0; cut.y = 0; cut.width = 50; cut.height = 50
        var special = LayoutObject(name: "special", kind: .vectors(square(5)), layer: 1); special.powerPercent = 50; special.speed = 500
        special.x = 60
        doc.objects = [cut, text, special]                                      // inserted "wrong" order on purpose
        let g = doc.generate(maxS: 1000)
        let engrave = g.firstIndex(of: "; layer Engrave")!, cutIdx = g.firstIndex(of: "; layer Cut")!
        XCTAssertLessThan(engrave, cutIdx, "engraving runs before cutting")
        XCTAssertTrue(g.contains { $0.contains("F200") }); XCTAssertTrue(g.contains { $0.contains("F500") })
        XCTAssertTrue(g.contains("M4 S1000") && g.contains("M4 S500") && g.contains("M4 S200"))
        let p = GCodeProgram(text: g.joined(separator: "\n"))
        XCTAssertEqual(p.burnBounds.maxX, max(5 + w, 70), accuracy: 0.01)
        doc.layers[1].output = false
        XCTAssertFalse(doc.generate().contains("; layer Cut"))
    }

    func testImageObjectsGenerateRasterCodeAtTheirPosition() {
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 20, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let img = ctx.makeImage()!
        var doc = LayoutDocument()
        var o = LayoutObject(name: "pic", kind: .image(imageID: "a", options: RasterOptions()), layer: 0)
        o.x = 30; o.y = 40; o.width = 10; o.height = 10
        doc.objects = [o]
        doc.layers[0].speed = 1200; doc.layers[0].powerPercent = 40
        let g = doc.generate(maxS: 1000) { $0 == "a" ? img : nil }
        XCTAssertTrue(g.contains { $0.contains("F1200") })
        let p = GCodeProgram(text: g.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(p.burnBounds.minX, 29.5); XCTAssertLessThanOrEqual(p.burnBounds.maxX, 40.5)
        XCTAssertGreaterThanOrEqual(p.burnBounds.minY, 39.5)
        XCTAssertGreaterThan(p.maxPower, 0); XCTAssertLessThanOrEqual(p.maxPower, 400)
    }

    func testProjectFileRoundTrip() throws {
        var doc = LayoutDocument()
        doc.objects = [LayoutObject(name: "sq", kind: .vectors(square(10))), LayoutObject(name: "t", kind: .text(TextSpec())),
                       LayoutObject(name: "pic", kind: .image(imageID: "img1", options: RasterOptions()))]
        var project = ProjectFile(document: doc); project.header = "G21"; project.footer = "M5"
        let url = tmp().appendingPathComponent("Test.\(ProjectIO.fileExtension)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProjectIO.write(project, images: ["img1": Data([1, 2, 3])], to: url)
        try ProjectIO.write(project, images: ["img1": Data([1, 2, 3, 4])], to: url)      // overwrite works
        let (back, images) = try ProjectIO.read(from: url)
        XCTAssertEqual(back, project)
        XCTAssertEqual(images["img1"], Data([1, 2, 3, 4]))
    }
}

// MARK: - network

final class AddressAndFirmwareTests: XCTestCase {
    func testAddressParsing() {
        XCTAssertEqual(NetworkAddress.parse("telnet://192.168.1.5"), NetworkAddress(kind: .telnet, host: "192.168.1.5", port: 23))
        XCTAssertEqual(NetworkAddress.parse("ws://laser.local:81/")?.port, 81)
        XCTAssertEqual(NetworkAddress.parse("tcp://h:8080")?.url, "tcp://h:8080")
        XCTAssertNil(NetworkAddress.parse("/dev/cu.usbserial")); XCTAssertNil(NetworkAddress.parse("http://x")); XCTAssertNil(NetworkAddress.parse("tcp://h:99999"))
        XCTAssertTrue(NetworkAddress.isNetwork("ws://x"))
    }

    func testFirmwareDetectionPicksTheRightTables() {
        defer { CodeTables.firmware = FirmwareInfo() }
        XCTAssertEqual(FirmwareInfo.detect(welcome: "Grbl 1.1f ['$' for help]").family, .grbl)
        XCTAssertEqual(FirmwareInfo.detect(welcome: "GrblHAL 1.1f ['$' or '$HELP' for help]").family, .grblHAL)
        XCTAssertEqual(FirmwareInfo.detect(welcome: "Grbl 3.7 [FluidNC v3.7.2 (wifi) '$' for help]").family, .fluidNC)
        let ortur = FirmwareInfo.detect(welcome: "Grbl 1.1f ['$' for help]", ver: "[VER:1.1f.20210310:Ortur Laser Master 3 V1.7.2]")
        XCTAssertEqual(ortur.family, .ortur); XCTAssertEqual(ortur.orturFirmware, 170); XCTAssertEqual(ortur.vendor, "Ortur Laser Master 3 V1.7.2")
        XCTAssertEqual(FirmwareInfo.detect(welcome: nil, ver: "[VER:1.1f.2020:Longer Nano]").family, .longer)
        XCTAssertNotNil(GrblParser.parseWelcome("GrblHAL 1.1f ['$' for help]"))

        // the same number means different things in different firmwares
        CodeTables.firmware = FirmwareInfo()
        let standard = GrblParser.describeError(3)
        CodeTables.firmware = FirmwareInfo.detect(welcome: "GrblHAL 1.1f")
        let hal = GrblParser.describeError(3)
        XCTAssertNotEqual(standard, hal)
        XCTAssertTrue(GrblParser.describeError(60).hasPrefix("error:60 "), "extended grblHAL error is known: \(GrblParser.describeError(60))")
        CodeTables.firmware = FirmwareInfo()
        XCTAssertEqual(GrblParser.describeError(60), "error:60")
        CodeTables.firmware = ortur
        XCTAssertNotNil(GrblParser.describeSetting(30))
    }
}

/// A tiny controller behind a TCP socket.
final class TCPFakeGrbl {
    let listener: NWListener
    var connections: [NWConnection] = []
    var received = ""
    var verLine = "[VER:1.1f.20210310:Ortur Laser Master 3 V1.5.0]"
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] s in
            if case .ready = s { self?.port = self?.listener.port?.rawValue ?? 0; ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] c in
            guard let self = self else { return }
            self.connections.append(c)
            c.start(queue: .main)
            self.read(c)
        }
        listener.start(queue: .main)
        let end = Date().addingTimeInterval(5)
        while port == 0, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func send(_ c: NWConnection, _ s: String) { c.send(content: Data(s.utf8), completion: .contentProcessed { _ in }) }

    func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, err in
            guard let self = self, let d = data else { return }
            var line = ""
            for b in d {
                switch b {
                case 0x18: self.send(c, "\r\nGrbl 1.1f ['$' for help]\r\n")
                case 0x3F: self.send(c, "<Idle|MPos:0.000,0.000,0.000|Bf:15,127|FS:0,0>\r\n")
                case 0x0A:
                    self.received += line + "\n"
                    if line == "$I" { self.send(c, self.verLine + "\r\nok\r\n") }
                    else if line == "$$" { self.send(c, "$30=1000\r\n$130=400.000\r\nok\r\n") }
                    else { self.send(c, "ok\r\n") }
                    line = ""
                default: line.append(Character(UnicodeScalar(b)))
                }
            }
            if err == nil { self.read(c) }
        }
    }

    func shutdown() { connections.forEach { $0.cancel() }; listener.cancel() }
}

final class NetworkControllerTests: XCTestCase {
    func wait(_ seconds: TimeInterval = 8, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return cond()
    }

    func testControllerTalksToAnOrturOverTCPAndRunsAJob() throws {
        let server = try TCPFakeGrbl()
        defer { server.shutdown(); CodeTables.firmware = FirmwareInfo() }
        let ctl = GrblController()
        var finished = false
        ctl.onEvent = { if case .jobFinished = $0 { finished = true } }
        ctl.connect(path: "tcp://127.0.0.1:\(server.port)", baud: 115200)
        XCTAssertEqual(ctl.state, .connecting)
        XCTAssertTrue(wait { ctl.state == .idle }, "state \(ctl.state) console \(ctl.console.map { $0.text })")
        XCTAssertTrue(wait { ctl.settings[30] == "1000" })
        XCTAssertTrue(wait { ctl.firmware.family == .ortur }, "firmware \(ctl.firmware)")
        XCTAssertEqual(ctl.firmware.orturFirmware, 150)
        ctl.load(GCodeProgram(text: "G21\nG90\nG0 X1 Y1\nG1 X5 F500\nM5"))
        XCTAssertTrue(ctl.canStartJob)
        ctl.startJob()
        XCTAssertTrue(wait { finished }, "job over TCP")
        XCTAssertTrue(server.received.contains("G1X5F500"), server.received)
        ctl.disconnect()
        XCTAssertEqual(ctl.state, .disconnected)
        XCTAssertEqual(CodeTables.firmware.family, .grbl, "back to standard tables")
    }

    func testConnectionToNobodyFailsCleanly() {
        let ctl = GrblController()
        var failed: String?
        ctl.onEvent = { if case .connectionFailed(let m) = $0 { failed = m } }
        ctl.connect(path: "tcp://127.0.0.1:1", baud: 115200)           // nothing listens on port 1
        XCTAssertTrue(wait { failed != nil })
        XCTAssertEqual(ctl.state, .disconnected)
    }

    func testTelnetNegotiationBytesAreRemoved() {
        let p = NetworkPort(address: NetworkAddress(kind: .telnet, host: "x"))
        let out = p.stripTelnet(Data([0x6F, 0x6B, 0xFF, 0xFB, 0x01, 0x0D, 0xFF, 0xFF, 0x0A]))
        XCTAssertEqual(Array(out), [0x6F, 0x6B, 0x0D, 0xFF, 0x0A])
    }
}
