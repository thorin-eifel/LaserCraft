import XCTest
import SwiftUI
import AppKit
@testable import LaserGRBLMac
import LaserGRBLCore

/// Screenshots of the Beta 6 features for MANUAL.md. Run with:
///   LG_SCREENSHOT_DIR=docs/images swift test --filter ScreenshotsBeta6Tests
@MainActor
final class ScreenshotsBeta6Tests: XCTestCase {
    var out: URL!
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["LG_SCREENSHOT_DIR"] else { throw XCTSkip("set LG_SCREENSHOT_DIR") }
        out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    func wait(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func shoot<V: View>(_ view: V, size: CGSize, name: String, title: String, settle: TimeInterval = 1.5) throws {
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

    func testDXFImportAndLayerPause() throws {
        let model = AppModel()
        try shoot(VectorSheet(source: .svg(root.appendingPathComponent("examples/sample-bracket.dxf"))).environmentObject(model),
                  size: CGSize(width: 840, height: 700), name: "dxf-import.png", title: "Import Vector File")

        let shapes = try DXFParser.parse(contentsOf: root.appendingPathComponent("examples/sample-bracket.dxf"))
        let l = model.layout
        l.addVectors(shapes.filter { $0.tag == "holes" || $0.tag == "slot" || $0.tag == "outline" }, name: "bracket", layer: 1, at: Pt(40, 40))
        l.addVectors(shapes.filter { $0.tag == "engrave" }, name: "mark", layer: 0, at: Pt(60, 90))
        l.mutate { d in
            if let i = d.layers.firstIndex(where: { $0.id == 1 }) {
                d.layers[i].pauseBefore = true; d.layers[i].pauseNote = "Flip the material"
                d.layers[i].passes = 3; d.layers[i].focusStep = 0.5
            }
        }
        l.selection = l.doc.objects.last?.id
        model.mainMode = .layout
        l.selection = nil
        try shoot(LayoutInspector(layout: l).environmentObject(model), size: CGSize(width: 380, height: 400), name: "layout-pause-focus.png", title: "Layers")
    }
}
