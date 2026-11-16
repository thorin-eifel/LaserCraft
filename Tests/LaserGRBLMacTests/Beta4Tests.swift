import XCTest
import AppKit
@testable import LaserGRBLMac
import LaserGRBLCore

final class StubURLProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var r = request
        if r.httpBody == nil, let s = r.httpBodyStream {                    // URLSession moves the body into a stream
            s.open(); var data = Data(); var buf = [UInt8](repeating: 0, count: 1024)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: 1024); if n <= 0 { break }; data.append(buf, count: n) }
            s.close(); r.httpBody = data
        }
        StubURLProtocol.requests.append(r)
        let resp = HTTPURLResponse(url: request.url!, statusCode: StubURLProtocol.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class HotkeyActionTests: XCTestCase {
    var grbl: FakeGrbl!
    override func tearDown() {
        grbl?.shutdown(); grbl = nil
        for k in ["customButtons", "hotkeys", "jogStep", "jogFeed", "continuousJog"] { UserDefaults.standard.set(nil, forKey: k) }
    }

    func wait(_ seconds: TimeInterval = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func connectedApp() -> AppModel {
        UserDefaults.standard.set(nil, forKey: "customButtons")
        let app = AppModel()
        grbl = FakeGrbl(); grbl.start()
        app.controller.connect(path: grbl.slavePath, baud: 115200)
        wait { app.controller.state == .idle && app.controller.settings[131] != nil }
        return app
    }

    func testKeysJogChangeStepAndSpeed() {
        let app = connectedApp()
        app.jogStep = 10; app.jogFeed = 3000
        app.perform(hotkey: .jogRight)
        wait { self.grbl.receivedLines.contains { $0.contains("$J=G91X10.0F3000") } }
        XCTAssertTrue(grbl.receivedLines.contains { $0.contains("$J=G91X10.0F3000") }, "\(grbl.receivedLines)")
        app.perform(hotkey: .bigUp)
        wait { self.grbl.receivedLines.contains { $0.contains("Y100.0") } }
        XCTAssertTrue(grbl.receivedLines.contains { $0.contains("$J=G91Y100.0F3000") }, "a big step is ten small ones")
        app.perform(hotkey: .stepUp);  XCTAssertEqual(app.jogStep, 50)
        app.perform(hotkey: .stepDown); app.perform(hotkey: .stepDown); XCTAssertEqual(app.jogStep, 5)
        app.perform(hotkey: .speedUp); XCTAssertEqual(app.jogFeed, 5000)
        app.perform(hotkey: .speedDown); app.perform(hotkey: .speedDown); XCTAssertEqual(app.jogFeed, 2000)
        app.perform(hotkey: .powerUp)
        XCTAssertEqual(app.controller.targetOverrides.spindle, 110)
        app.perform(hotkey: .powerDown); app.perform(hotkey: .powerDown)
        XCTAssertEqual(app.controller.targetOverrides.spindle, 90)
    }

    func testControlNumberRunsTheCustomButton() {
        let app = connectedApp()
        app.perform(hotkey: .button1)                       // "Home" is the first built-in button
        wait { self.grbl.receivedLines.contains("$H") }
        XCTAssertTrue(grbl.receivedLines.contains("$H"))
        let before = grbl.receivedLines.count
        app.perform(hotkey: .button9)                       // there is no ninth button: nothing happens
        wait(0.3) { false }
        XCTAssertEqual(grbl.receivedLines.count, before)
    }

    func testHotkeysAreSavedAndKeyModifiersTranslate() {
        let app = AppModel()
        app.hotkeys.set(KeyCombo("j", [.control]), for: .jogDownLeft)
        app.saveHotkeys()
        XCTAssertEqual(AppModel.loadHotkeys().combo(for: .jogDownLeft), KeyCombo("j", .control))
        XCTAssertEqual(HotkeyManager.modifiers([.control, .option, .shift]), [.control, .option, .shift])
        XCTAssertEqual(HotkeyManager.modifiers([]), [])
    }
}

@MainActor
final class RemoteAndDockTests: XCTestCase {
    func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.requests = []; StubURLProtocol.status = 200
        return URLSession(configuration: c)
    }

    func testPushMessageIsSentToNtfyAndReportsHttpErrors() {
        let done = expectation(description: "sent")
        let m = RemoteNotification.Message(title: "Job finished", body: "0:20:00", failed: false)
        RemoteSender.send(m, to: "ntfy://lasercraft-test", session: session()) { error in
            XCTAssertNil(error)
            let r = StubURLProtocol.requests.first
            XCTAssertEqual(r?.url?.absoluteString, "https://ntfy.sh/lasercraft-test")
            XCTAssertEqual(r?.value(forHTTPHeaderField: "Title"), "Job finished")
            XCTAssertEqual(String(decoding: r?.httpBody ?? Data(), as: UTF8.self), "0:20:00")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let failed = expectation(description: "failed")
        let s = session(); StubURLProtocol.status = 500
        RemoteSender.send(m, to: "https://hooks.example.com/x", session: s) { error in XCTAssertEqual(error, "HTTP 500"); failed.fulfill() }
        wait(for: [failed], timeout: 5)
        let bad = expectation(description: "bad")
        RemoteSender.send(m, to: "nonsense", session: s) { error in XCTAssertNotNil(error); bad.fulfill() }
        wait(for: [bad], timeout: 5)
    }

    func testMessageFromTheAppHidesTheFileNameByDefault() {
        UserDefaults.standard.set(nil, forKey: "remoteIncludeName")
        let app = AppModel()
        let m = app.remoteMessage(name: "customer-order.nc", seconds: 1500, aborted: false, errors: 0)
        XCTAssertFalse(m.body.contains("customer")); XCTAssertEqual(m.body, "0:25:00")
        UserDefaults.standard.set(true, forKey: "remoteIncludeName")
        XCTAssertTrue(app.remoteMessage(name: "customer-order.nc", seconds: 1500, aborted: false, errors: 0).body.contains("customer-order.nc"))
        UserDefaults.standard.set(nil, forKey: "remoteIncludeName")
    }

    func testDockShowsPercentAndClears() {
        let dock = DockProgress()
        dock.update(progress: 0.42, remaining: 600)
        XCTAssertEqual(dock.label, "42% · 10 min")
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "42% · 10 min")
        dock.update(progress: nil, remaining: nil)
        XCTAssertNil(dock.label); XCTAssertNil(NSApp.dockTile.badgeLabel)
    }
}

@MainActor
final class HistoryAndSaveAppTests: XCTestCase {
    func testAFinishedJobIsRememberedWithPictureAndCanBeOpenedAgain() throws {
        let app = AppModel()
        let name = "history-test-\(UUID().uuidString.prefix(6)).nc"
        let program = GCodeProgram(text: "G21\nG90\nM4 S500\nG1 X30 Y10 F1000\nG1 X30 Y40\nM5", name: name)
        app.setProgram(program)
        let before = app.history.records.count
        app.recordHistory(aborted: false, errors: 0, seconds: 95, name: name)
        let rec = try XCTUnwrap(app.history.records.first)
        XCTAssertEqual(app.history.records.count, min(before + 1, app.history.limit))
        XCTAssertEqual(rec.name, name); XCTAssertEqual(rec.outcome, .finished); XCTAssertTrue(rec.hasGCode); XCTAssertTrue(rec.hasThumbnail)
        XCTAssertNotNil(NSImage(data: try XCTUnwrap(app.history.thumbnail(for: rec.id))), "a real picture")
        app.setProgram(GCodeProgram(text: "G0 X1", name: "other.nc"))
        app.reopen(rec)
        XCTAssertEqual(app.controller.program?.name, name)
        XCTAssertEqual(app.controller.program?.commands.count, program.commands.count)
        app.recordHistory(aborted: true, errors: 0, seconds: 5, name: name)
        XCTAssertEqual(app.history.records.first?.outcome, .stopped)
        app.history.delete(id: app.history.records[0].id); app.history.delete(id: rec.id)
    }

    func testSaveOptionsAreRememberedButPassesFollowTheJob() {
        UserDefaults.standard.set(nil, forKey: "saveOptions")
        let a = SaveOptionsModel(passes: 3)
        XCTAssertEqual(a.options.passes, 3)
        a.options.includeHeader = false; a.options.lineEnding = .crlf; a.options.passes = 9
        let b = SaveOptionsModel(passes: 2)
        XCTAssertFalse(b.options.includeHeader); XCTAssertEqual(b.options.lineEnding, .crlf)
        XCTAssertEqual(b.options.passes, 2)
        UserDefaults.standard.set(nil, forKey: "saveOptions")
    }
}
