import XCTest
import AppKit
@testable import LaserGRBLMac
import LaserGRBLCore

@MainActor
final class LayoutModelTests: XCTestCase {
    func square(_ s: Double) -> [Polyline] { [Polyline([Pt(3, 4), Pt(3 + s, 4), Pt(3 + s, 4 + s), Pt(3, 4 + s)], closed: true)] }

    func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testAddingMovingAndUndoRedo() {
        let m = LayoutModel()
        let o = m.addVectors(square(10), name: "sq", layer: 1, at: Pt(20, 30))!
        XCTAssertEqual(m.doc.objects.count, 1)
        XCTAssertEqual(m.selection, o.id)
        XCTAssertEqual(m.selected?.x, 20)
        XCTAssertEqual(VectorMath.bounds(m.doc.objects[0].nativeShapes()).minX, 0, "native shapes start at the origin")
        // an interactive drag is one undo step
        m.updateSelected({ $0.x = 25 }, interactive: true)
        m.updateSelected({ $0.x = 28 }, interactive: true)
        m.updateSelected({ $0.x = 31 }, interactive: true)
        m.endInteraction()
        XCTAssertEqual(m.selected?.x, 31)
        m.undo()
        XCTAssertEqual(m.selected?.x, 20, "the whole drag is undone at once")
        m.redo()
        XCTAssertEqual(m.selected?.x, 31)
        m.undo(); m.undo()
        XCTAssertTrue(m.doc.isEmpty); XCTAssertNil(m.selected)
        XCTAssertFalse(m.canUndo); XCTAssertTrue(m.canRedo)
        m.redo()
        XCTAssertEqual(m.doc.objects.count, 1)
    }

    func testRevisionTracksWhetherTheJobIsOutOfDate() {
        let m = LayoutModel()
        XCTAssertFalse(m.needsGenerate, "an empty layout needs nothing")
        m.addVectors(square(5), name: "a")
        XCTAssertTrue(m.needsGenerate)
        _ = m.generate(maxS: 1000, dynamicPower: true)
        m.markGenerated()
        XCTAssertFalse(m.needsGenerate)
        m.updateSelected { $0.y = 9 }
        XCTAssertTrue(m.needsGenerate)
    }

    func testLockedObjectsDoNotMoveAndLayersCanBeManaged() {
        let m = LayoutModel()
        m.addVectors(square(5), name: "a", layer: 1)
        let id = m.selection!
        m.mutate { d in d.objects[0].locked = true }
        m.updateSelected { $0.x = 99 }
        XCTAssertEqual(m.doc.objects[0].x, 0)
        XCTAssertEqual(m.selection, id)
        m.addLayer()
        XCTAssertEqual(m.doc.layers.count, 3)
        m.moveLayer(2, by: -1)
        XCTAssertEqual(m.doc.layers.map { $0.id }, [0, 2, 1])
        m.deleteLayer(1)                                           // the object is moved to another layer
        XCTAssertEqual(m.doc.layers.count, 2)
        XCTAssertEqual(m.doc.objects[0].layer, 0)
    }

    func testObjectsWithOwnSettingsAndTextAndImages() {
        let m = LayoutModel()
        var s = VectorSettings(); s.speed = 700; s.powerPercent = 35
        let o = m.addVectors(square(5), name: "a", layer: 0, settings: s)!
        XCTAssertEqual(o.speed, 700, "differs from the layer, so it is kept on the object")
        XCTAssertEqual(o.passes, nil, "same as the layer, nothing stored")
        let t = m.addText(TextSpec(), layer: 0, at: Pt(5, 5))
        XCTAssertGreaterThan(t.width, 20)
        guard case .text = m.selected!.kind else { return XCTFail() }
        let img = m.addImage(data: pngData(), name: "pic", options: { var o = RasterOptions(); o.widthMM = 40; return o }())
        XCTAssertEqual(img?.width, 40); XCTAssertEqual(img?.height, 40)
        XCTAssertNotNil(m.cgImage((img!.kind.imageID)!))
        // pictures turn like every other object: by any angle, around their centre
        m.updateSelected { $0.height = 20 }
        m.rotateSelected(by: 90)
        XCTAssertEqual(m.selected?.width, 40); XCTAssertEqual(m.selected?.height, 20)
        XCTAssertEqual(m.selected?.rotation, 90)
        m.rotateSelected(by: -135)
        XCTAssertEqual(m.selected?.rotation, 315)
        XCTAssertNil(m.addImage(data: Data([1, 2, 3]), name: "bad"))
        // copies of a picture get their own image entry
        m.duplicateSelection()
        XCTAssertEqual(m.doc.objects.count, 4)
        XCTAssertNotEqual(m.doc.objects[3].kind.imageID, m.doc.objects[2].kind.imageID)
    }

    func testProjectSaveAndOpenKeepsEverythingIncludingPictures() throws {
        let m = LayoutModel()
        m.addVectors(square(12), name: "frame", layer: 1, at: Pt(10, 10))
        m.addText(TextSpec(), layer: 0)
        m.addImage(data: pngData(), name: "pic")
        m.header = "G21"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lc-proj-\(UUID().uuidString)/Test.lasercraft")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try m.save(to: url, profileID: "p1")
        XCTAssertFalse(m.dirty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path))
        let other = LayoutModel()
        let project = try other.open(url)
        XCTAssertEqual(project.machineProfileID, "p1")
        XCTAssertEqual(other.doc, m.doc)
        XCTAssertEqual(other.header, "G21")
        let imageObject = other.doc.objects.first { $0.isImage }!
        XCTAssertNotNil(other.cgImage(imageObject.kind.imageID!))
        XCTAssertEqual(other.fileURL, url)
        other.newDocument()
        XCTAssertTrue(other.doc.isEmpty); XCTAssertNil(other.fileURL)
    }
}

extension LayoutKind {
    var imageID: String? { if case .image(let id, _) = self { return id }; return nil }
}

@MainActor
final class AppModelToolsTests: XCTestCase {
    override func tearDown() {
        for k in ["networkMachines", "port", "baud", "rapidRate", "laserSpotSize"] { UserDefaults.standard.set(nil, forKey: k) }
    }

    func testLayoutBecomesAJobAndIsRegeneratedBeforeStart() {
        let app = AppModel()
        let o = app.layout.addVectors([Polyline([Pt(0, 0), Pt(20, 0), Pt(20, 10), Pt(0, 10)], closed: true)], name: "box", layer: 1)
        XCTAssertNotNil(o)
        app.useLayoutAsJob()
        XCTAssertTrue(app.jobFromLayout)
        XCTAssertEqual(app.controller.program?.burnBounds.width ?? 0, 20, accuracy: 1e-6)
        XCTAssertFalse(app.layout.needsGenerate)
        app.layout.updateSelected { $0.width = 40 }
        XCTAssertTrue(app.layout.needsGenerate)
        app.useLayoutAsJob()
        XCTAssertEqual(app.controller.program?.burnBounds.width ?? 0, 40, accuracy: 1e-6)
        // a loaded G-code file is not a layout job any more
        app.setProgram(GCodeProgram(text: "G0 X1"))
        XCTAssertFalse(app.jobFromLayout)
    }

    func testFileTypesGoToTheRightImporter() throws {
        let app = AppModel()
        app.openFile(URL(fileURLWithPath: "/tmp/x.svg"))
        XCTAssertEqual(app.tool, .vector(.svg(URL(fileURLWithPath: "/tmp/x.svg"))))
        app.tool = nil
        app.openFile(URL(fileURLWithPath: "/tmp/x.png"))
        XCTAssertTrue(app.showImageImport)
    }

    func testNetworkMachinesAppearInThePortListAndHaveReadableNames() {
        let app = AppModel()
        app.addNetworkMachine(NetworkAddress(kind: .telnet, host: "fluidnc.local"))
        XCTAssertEqual(app.selectedPort, "telnet://fluidnc.local:23")
        XCTAssertTrue(app.ports.contains("telnet://fluidnc.local:23"))
        XCTAssertEqual(app.portName("telnet://fluidnc.local:23"), "fluidnc.local (Telnet)")
        XCTAssertEqual(app.portName("ws://10.0.0.5:81"), "10.0.0.5 (WebSocket)")
        app.forgetNetworkMachine("telnet://fluidnc.local:23")
        XCTAssertFalse(app.ports.contains("telnet://fluidnc.local:23"))
    }

    func testProfileIsLoadedForItsPortAndUsageIsRecorded() {
        let app = AppModel()
        var p = MachineProfile(name: "Test laser \(UUID().uuidString.prefix(4))")
        p.connection = "/dev/cu.test-\(UUID().uuidString.prefix(6))"; p.baud = 250000; p.header = "G21 ; header"; p.rapidRate = 4321
        app.profiles.upsert(p)
        defer { app.profiles.delete(id: p.id) }
        app.applyProfile(forConnection: p.connection)
        XCTAssertEqual(app.activeProfileID, p.id)
        XCTAssertEqual(app.baud, 250000)
        XCTAssertEqual(app.controller.jobSettings.header, "G21 ; header")
        app.selectedPort = p.connection
        app.setProgram(GCodeProgram(text: "G21\nG90\nM4 S1000\nG1 X60 F6000\nM5"))
        let before = app.profiles.usage.count
        app.recordUsage(aborted: false, errors: 0, seconds: 3, name: "x.nc")
        XCTAssertEqual(app.profiles.usage.count, before + 1)
        XCTAssertEqual(app.profiles.usage.last?.profileID, p.id)
        XCTAssertGreaterThan(app.profiles.usage.last?.fullPowerSeconds ?? 0, 0)
        app.selectedPort = AppModel.simulatorPort
        app.recordUsage(aborted: false, errors: 0, seconds: 3, name: "x.nc")
        XCTAssertEqual(app.profiles.usage.count, before + 1, "the demo machine is not counted")
        app.profiles.clearUsage(profileID: p.id)
    }

    func testAppModelLoadsTheBuiltInMaterials() throws {
        let d = try Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Resources/Materials.json"))
        XCTAssertGreaterThan(MaterialDB(builtinData: d).builtin.count, 800, "direct load")
        XCTAssertGreaterThan(AppModel().materials.builtin.count, 800, "cwd: \(FileManager.default.currentDirectoryPath) exists: \(FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/Resources/Materials.json")) bundle: \(String(describing: Bundle.main.url(forResource: "Materials", withExtension: "json")))")
    }

    func testBuiltInMaterialsAreInstalledWithTheApp() throws {
        // the app bundle ships Materials.json next to the translations; in tests it is read from Resources/
        let res = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Materials.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: res.path))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: res.deletingLastPathComponent().appendingPathComponent("Info.plist")), format: nil) as! [String: Any]
        XCTAssertNotNil(plist["NSCameraUsageDescription"]); XCTAssertNotNil(plist["NSLocalNetworkUsageDescription"])
        XCTAssertNotNil(plist["UTExportedTypeDeclarations"])
    }
}
