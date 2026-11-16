import XCTest
@testable import LaserGRBLCore

final class SettingsFileTests: XCTestCase {
    func testOnlyNumberedSettingsAreAccepted() {
        let text = """
        $100=250.000
          $101=250.000
        $30=1000
        $32=1
        $RST=*
        $H
        $J=G91 X1000 F500
        $SLP
        $X
        $110=abc
        $120=
        G1 X5 Y5 F300
        $130=400.0; $RST=$
        $1000=5
        $5=1
        """
        XCTAssertEqual(GrblSettingsFile.settingLines(in: text), ["$100=250.000", "$101=250.000", "$30=1000", "$32=1", "$5=1"])
    }

    func testAWindowsFileWithCarriageReturnsWorks() {
        XCTAssertEqual(GrblSettingsFile.settingLines(in: "$0=10\r\n$1=25\r\n"), ["$0=10", "$1=25"])
        XCTAssertEqual(GrblSettingsFile.settingLines(in: ""), [])
    }

    func testExportListsOnlyKnownSettingsInOrder() {
        XCTAssertEqual(GrblSettingsFile.text(settings: [100: "250", 30: "1000", 5: "0"], keys: [5, 30, 100, 999]), "$5=0\n$30=1000\n$100=250\n")
        // an export can be imported again unchanged
        let back = GrblSettingsFile.settingLines(in: GrblSettingsFile.text(settings: [100: "250.000", 32: "1"], keys: [32, 100]))
        XCTAssertEqual(back, ["$32=1", "$100=250.000"])
    }
}

final class ProjectWriteSafetyTests: XCTestCase {
    func testAFailedWriteLeavesNoTemporaryFolderAndKeepsTheOldProject() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("a.lasercraft")
        var doc = LayoutDocument()
        doc.serial = 7
        try ProjectIO.write(ProjectFile(document: doc), images: [:], to: target)
        // an image id with a slash cannot be written into images/: the whole write must fail cleanly
        XCTAssertThrowsError(try ProjectIO.write(ProjectFile(document: doc), images: ["no/such/folder": Data([1])], to: target))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftovers, ["a.lasercraft"], "no hidden .tmp folder remains")
        XCTAssertEqual(try ProjectIO.read(from: target).0.document.serial, 7, "the earlier project is untouched")
    }
}

final class RemoteHeaderTests: XCTestCase {
    func testNonAsciiTitlesAreEncodedForTheHeader() throws {
        XCTAssertEqual(RemoteNotification.headerSafe("Job finished"), "Job finished")
        let enc = RemoteNotification.headerSafe("Zadanie zakończone")
        XCTAssertTrue(enc.hasPrefix("=?UTF-8?B?") && enc.hasSuffix("?="))
        let b64 = String(enc.dropFirst(10).dropLast(2))
        XCTAssertEqual(String(data: try XCTUnwrap(Data(base64Encoded: b64)), encoding: .utf8), "Zadanie zakończone")
        XCTAssertEqual(RemoteNotification.headerSafe("one\ntwo"), "one", "a header is a single line")
        let req = try XCTUnwrap(RemoteNotification.request(address: "ntfy://my-laser", message: .init(title: "Gotowe ✓", body: "x", failed: false)))
        XCTAssertTrue(req.value(forHTTPHeaderField: "Title")!.hasPrefix("=?UTF-8?B?"))
        XCTAssertNil(RemoteNotification.request(address: "ftp://example.com", message: .init(title: "t", body: "b", failed: false)))
        XCTAssertNil(RemoteNotification.request(address: "file:///etc/passwd", message: .init(title: "t", body: "b", failed: false)))
    }
}
