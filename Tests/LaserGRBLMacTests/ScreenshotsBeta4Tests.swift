import XCTest
import SwiftUI
import AppKit
@testable import LaserGRBLMac
import LaserGRBLCore

/// Screenshots of the Beta 4 features for MANUAL.md. Run with:
///   LG_SCREENSHOT_DIR=docs/images swift test --filter ScreenshotsBeta4Tests
@MainActor
final class ScreenshotsBeta4Tests: XCTestCase {
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

    func shoot<V: View>(_ view: V, size: CGSize, name: String, title: String) throws {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.setContentSize(size)
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        wait(1.2)
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
        let p = try GCodeProgram(contentsOf: root.appendingPathComponent("examples/demo-shapes.nc"))
        model.setProgram(p)
        return model
    }

    func testKeyboardAndRemoteSettings() throws {
        let model = AppModel()
        model.hotkeys = .defaults
        try shoot(KeyboardSettings().environmentObject(model).frame(width: 560, height: 700), size: CGSize(width: 560, height: 700), name: "settings-keyboard.png", title: "Keyboard")
        UserDefaults.standard.set(true, forKey: "remoteEnabled"); UserDefaults.standard.set("ntfy://my-secret-laser", forKey: "remoteURL")
        defer { UserDefaults.standard.set(nil, forKey: "remoteEnabled"); UserDefaults.standard.set(nil, forKey: "remoteURL") }
        try shoot(Form { RemoteNotificationSection() }.formStyle(.grouped).environmentObject(model).frame(width: 560, height: 420),
                  size: CGSize(width: 560, height: 420), name: "settings-remote.png", title: "Remote Notification")
    }

    func testConsoleWithFilter() throws {
        let model = try connectedModel()
        model.controller.send("$$"); model.controller.send("G0 X5 Y5"); model.controller.send("G99")
        wait(1.0)
        model.consoleTimestamps = true
        defer { model.consoleTimestamps = false }
        let view = CommandList(controller: model.controller, showConsole: true).environmentObject(model).frame(width: 420, height: 420).padding(12)
        try shoot(view, size: CGSize(width: 444, height: 444), name: "console-filter.png", title: "Console")
    }

    func testHistorySaveAndMainWindow() throws {
        let model = try connectedModel()
        let progs = ["badge.nc", "coaster.nc", "demo-shapes.nc"]
        var ids: [String] = []
        for (i, n) in progs.enumerated() {
            let p = try GCodeProgram(contentsOf: root.appendingPathComponent("examples/demo-shapes.nc"))
            let r = model.history.add(JobRecord(date: Date().addingTimeInterval(Double(-i) * 7200), name: n, seconds: 1100 + Double(i) * 400,
                                                 outcome: i == 1 ? .stopped : .finished, machine: "Ortur Laser Master 3", lines: p.commands.count, errors: 0),
                                      gcode: p.text, thumbnail: ThumbnailRenderer.png(for: p))
            ids.append(r.id)
        }
        defer { ids.forEach { model.history.delete(id: $0) } }
        try shoot(JobHistorySheet().environmentObject(model), size: CGSize(width: 640, height: 520), name: "job-history.png", title: "Job History")
        try shoot(SaveOptionsView(model: SaveOptionsModel(passes: 1), hasHeader: true, hasFooter: true), size: CGSize(width: 380, height: 190),
                  name: "save-options.png", title: "Save G-code")
        try shoot(ContentView(controller: model.controller).environmentObject(model), size: CGSize(width: 1280, height: 780), name: "main-window.png", title: "demo-shapes.nc")
    }
}
