import XCTest
import SwiftUI
import AppKit
@testable import LaserGRBLMac
import LaserGRBLCore

/// Screenshots of the Release 3 windows for MANUAL.md. Run with:
///   LG_SCREENSHOT_DIR=docs/images swift test --filter ScreenshotsRelease3Tests
@MainActor
final class ScreenshotsRelease3Tests: XCTestCase {
    var out: URL!
    var grbl: FakeGrbl!
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["LG_SCREENSHOT_DIR"] else { throw XCTSkip("set LG_SCREENSHOT_DIR") }
        out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() { grbl?.shutdown(); grbl = nil }

    func wait(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func shoot<V: View>(_ view: V, size: CGSize, name: String, title: String, settle: TimeInterval = 1.2) throws {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.setContentSize(size)
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        wait(settle)
        hosting.layoutSubtreeIfNeeded()
        wait(0.3)
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name))
        window.orderOut(nil)
    }

    func connectedModel() throws -> AppModel {
        UserDefaults.standard.set(nil, forKey: "customButtons")
        let model = AppModel()
        model.ports = ["/dev/cu.usbserial-1410"]; model.selectedPort = "/dev/cu.usbserial-1410"
        grbl = FakeGrbl(); grbl.lineDelay = 1500; grbl.start()
        model.controller.connect(path: grbl.slavePath, baud: 115200)
        let end = Date().addingTimeInterval(5)
        while Date() < end, !(model.controller.state == .idle && model.controller.settings[130] != nil) { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return model
    }

    /// A black-on-white logo: thick letters and a ring.
    static func makeLogo(at url: URL) throws {
        let w = 700, h = 420
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSColor.black.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 40, y: 60, width: 300, height: 300)); ring.lineWidth = 26; ring.stroke()
        let font = NSFont.systemFont(ofSize: 150, weight: .black)
        ("LC" as NSString).draw(at: NSPoint(x: 100, y: 120), withAttributes: [.font: font, .foregroundColor: NSColor.black])
        ("Laser" as NSString).draw(at: NSPoint(x: 380, y: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 90, weight: .heavy), .foregroundColor: NSColor.black])
        ("Craft" as NSString).draw(at: NSPoint(x: 380, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 90, weight: .heavy), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    func testImageImportFillsTheWindow() throws {
        let model = AppModel()
        try shoot(ImageImportView(url: root.appendingPathComponent("examples/sample-picture.png")).environmentObject(model),
                  size: CGSize(width: 1500, height: 900), name: "image-import-large.png", title: "Import Image")
    }

    func testLayoutEditor() throws {
        let model = try connectedModel()
        model.setProgram(GCodeProgram(text: "G21"))
        let shapes = try SVGParser.parse(contentsOf: root.appendingPathComponent("examples/sample-badge.svg"))
        let l = model.layout
        l.addVectors(shapes, name: "badge", layer: 1, at: Pt(30, 40))
        var spec = TextSpec(); spec.text = "LaserCraft\n{n:3}"; spec.size = 7
        l.addText(spec, layer: 0, at: Pt(105, 50))
        if let data = try? Data(contentsOf: root.appendingPathComponent("examples/sample-picture.png")) {
            var o = RasterOptions(); o.widthMM = 70
            l.addImage(data: data, name: "sample-picture", options: o, layer: 0, at: Pt(30, 95))
        }
        l.mutate { d in if d.objects.count > 2 { d.objects[1].rotation = 20; d.objects[2].rotation = -12 } }
        l.selection = l.doc.objects.dropFirst().first?.id
        l.extraSelection = Set(l.doc.objects.suffix(1).map { $0.id })
        model.mainMode = .layout
        try shoot(ContentView(controller: model.controller).environmentObject(model), size: CGSize(width: 1280, height: 780), name: "layout-editor.png", title: "Layout")
    }

    func testVectorSheets() throws {
        let model = AppModel()
        try shoot(VectorSheet(source: .svg(root.appendingPathComponent("examples/sample-badge.svg"))).environmentObject(model),
                  size: CGSize(width: 840, height: 700), name: "svg-import.png", title: "Import SVG")
        try shoot(VectorSheet(source: .text).environmentObject(model), size: CGSize(width: 840, height: 700), name: "text-import.png", title: "Add Text")
        let logo = FileManager.default.temporaryDirectory.appendingPathComponent("trace-logo.png")
        try Self.makeLogo(at: logo)
        try shoot(VectorSheet(source: .trace(logo)).environmentObject(model),
                  size: CGSize(width: 840, height: 700), name: "trace-image.png", title: "Trace Image", settle: 2.5)
    }

    func testToolSheets() throws {
        let model = try connectedModel()
        var p = MachineProfile(name: "Ortur Laser Master 3"); p.connection = "/dev/cu.usbserial-1410"; p.laserWatts = 10; p.ratedHours = 10000
        model.profiles.upsert(p); model.activeProfileID = p.id
        for i in 0..<4 {
            model.profiles.record(UsageEntry(profileID: p.id, date: Date().addingTimeInterval(Double(-i) * 90_000),
                                             job: ["badge.nc", "demo-shapes.nc", "coaster.nc", "test.nc"][i], seconds: 1800 + Double(i) * 600,
                                             laserSeconds: 1500, fullPowerSeconds: 900, lines: 4000, outcome: i == 2 ? .stopped : .finished))
        }
        try shoot(TestPatternsSheet().environmentObject(model), size: CGSize(width: 600, height: 560), name: "test-patterns.png", title: "Test Patterns")
        try shoot(MaterialsSheet().environmentObject(model), size: CGSize(width: 760, height: 520), name: "materials.png", title: "Materials")
        try shoot(ProfilesSheet().environmentObject(model), size: CGSize(width: 640, height: 520), name: "machine-profiles.png", title: "Machine Profiles")
        try shoot(StatisticsSheet().environmentObject(model), size: CGSize(width: 600, height: 560), name: "laser-statistics.png", title: "Laser Statistics")
        try shoot(NetworkSheet().environmentObject(model), size: CGSize(width: 520, height: 420), name: "network-machines.png", title: "Network Machines")
        try shoot(CameraWindow().frame(width: 640, height: 480), size: CGSize(width: 640, height: 480), name: "camera.png", title: "Camera")
        model.profiles.clearUsage(profileID: p.id)
        model.profiles.delete(id: p.id)
    }
}
