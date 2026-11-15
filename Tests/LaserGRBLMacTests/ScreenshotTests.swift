import XCTest
import SwiftUI
import AppKit
@testable import LaserGRBLMac
import LaserGRBLCore

/// Writes the screenshots used by README.md and MANUAL.md.
/// Run with:  LG_SCREENSHOT_DIR=docs/images swift test --filter ScreenshotTests
/// (skipped in normal test runs). The views are put into real, off-screen windows so that every control is drawn.
@MainActor
final class ScreenshotTests: XCTestCase {
    var out: URL!
    var grbl: FakeGrbl!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["LG_SCREENSHOT_DIR"] else {
            throw XCTSkip("set LG_SCREENSHOT_DIR to write the documentation screenshots")
        }
        out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() { grbl?.shutdown(); grbl = nil }

    // MARK: helpers

    func wait(_ seconds: TimeInterval, _ cond: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Puts `view` in a window of `size`, lets SwiftUI lay it out and writes a PNG of the whole window.
    func shoot<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = false, title: String = "LaserCraft", chrome: Bool = false) throws {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setContentSize(size)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        wait(1.0)
        hosting.layoutSubtreeIfNeeded()
        wait(0.3)
        // the window frame (title bar, toolbar) is drawn dimmed when the window is not the active one, so the
        // content view is what gets photographed; the title bar is added back as a flat strip by the caller if wanted
        let frame: NSView = chrome ? window.contentView!.superview! : hosting
        let rep = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name))
        window.orderOut(nil)
    }

    /// A model that looks connected to a laser: ports filled in, fake Grbl on the other end.
    func connectedModel(program: String = "examples/demo-shapes.nc", lineDelay: useconds_t = 1500) throws -> AppModel {
        UserDefaults.standard.set(nil, forKey: "customButtons")   // show the built-in buttons, not leftovers of earlier runs
        let model = AppModel()
        model.ports = ["/dev/cu.usbserial-1410"]
        model.selectedPort = "/dev/cu.usbserial-1410"
        grbl = FakeGrbl(); grbl.lineDelay = lineDelay; grbl.start()
        model.controller.connect(path: grbl.slavePath, baud: 115200)
        wait(5) { model.controller.state == .idle && model.controller.settings[130] != nil }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let p = try GCodeProgram(contentsOf: root.appendingPathComponent(program))
        model.setProgram(p)
        return model
    }

    // MARK: scenes

    func testMainWindow() throws {
        let model = try connectedModel()
        let view = ContentView(controller: model.controller).environmentObject(model)
        try shoot(view, size: CGSize(width: 1180, height: 760), name: "main-window.png", title: "demo-shapes.nc")
    }

    func testJobRunning() throws {
        let model = try connectedModel(lineDelay: 25_000)
        model.controller.startJob()
        wait(30) { model.controller.jobExecuted > model.controller.jobTarget * 4 / 10 }
        let view = ContentView(controller: model.controller).environmentObject(model)
        try shoot(view, size: CGSize(width: 1180, height: 760), name: "job-running.png", title: "demo-shapes.nc")
        model.controller.abortJob()
    }

    func testSafetyWarning() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let img = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns")) { NSApp.applicationIconImage = img }
        let (alert, state) = LaserSafety.makeAlert(title: L("Start “%@”?", "demo-shapes.nc"), confirmButton: L("Start"),
                                                   extra: L("Estimated time: %@", "0:01:02"))
        state.remaining = 3; state.boxTicked = true; state.checkBox?.state = .on; state.refresh()
        alert.layout()
        let window = alert.window
        window.appearance = NSAppearance(named: .aqua)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        wait(0.8)
        let frame = window.contentView!.superview!
        let rep = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("safety-warning.png"))
        window.orderOut(nil)
    }

    func testImageImport() throws {
        let model = AppModel()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = ImageImportView(url: root.appendingPathComponent("examples/sample-picture.png")).environmentObject(model)
        try shoot(view, size: CGSize(width: 840, height: 1010), name: "image-import.png", title: "Import Image")
    }

    func testSettings() throws {
        let model = try connectedModel()
        try shoot(SettingsView().environmentObject(model), size: CGSize(width: 560, height: 560), name: "settings-general.png", title: "General")
        try shoot(ConnectionSettings().environmentObject(model).frame(width: 560, height: 430), size: CGSize(width: 560, height: 430), name: "settings-connection.png", title: "Connection")
        try shoot(JobSettingsTab(controller: model.controller).environmentObject(model).frame(width: 560, height: 430), size: CGSize(width: 560, height: 430), name: "settings-job.png", title: "Job")
        try shoot(PreviewSettings().frame(width: 560, height: 430), size: CGSize(width: 560, height: 430), name: "settings-preview.png", title: "Preview")
        try shoot(ButtonSettings().environmentObject(model).frame(width: 560, height: 430), size: CGSize(width: 560, height: 430), name: "settings-buttons.png", title: "Buttons")
    }

    func testGrblConfiguration() throws {
        let model = try connectedModel()
        try shoot(GrblConfigView(controller: model.controller).environmentObject(model), size: CGSize(width: 880, height: 540),
                  name: "grbl-configuration.png", title: "Grbl configuration")
    }
}
