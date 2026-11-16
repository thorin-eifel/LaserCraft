import XCTest
@testable import LaserGRBLCore

/// A G-code file can be anything: opening it must never crash, hang, or leave NaN in the time estimate.
final class HostileGCodeTests: XCTestCase {
    func testAbsurdNumbersAndBrokenLines() {
        let lines = [
            "G1 X1e999 Y-1e999 F0", "G1 X nan Y inf", "G2 X5 Y5 I0 J0", "G3 X5 Y5 R0", "G2 X0 Y0 I1e308 J1e308", "G2 X1e308 Y0 R1",
            "G1 F-100 X5", "S-50 M3", "G91 G1 X1e308", "G91 G1 X1e308", "G20 G1 X1e300", "G4 P1e308", "G4 P-5",
            "((((", ")", "; only a comment", "G1 X", "G1 XX5 YY6", "X5 Y5", "%", "$J=X5", "\u{1}\u{2}", String(repeating: "G1 X1 Y1 ", count: 5000),
            "G2 X10 Y0 I5 J0", "G3 X10 Y0 I5 J0", "G2 X10 Y0 R5", "G2 X10 Y0 R1",
        ]
        let t = Date()
        let p = GCodeProgram(text: lines.joined(separator: "\n"), name: "hostile.nc")
        XCTAssertLessThan(Date().timeIntervalSince(t), 5, "reading took too long")
        for v in [p.burnSeconds, p.burnPowerSeconds, p.burnLength] { XCTAssertFalse(v.isNaN, "estimate is NaN") }
        // resuming in the middle of such a file must also work (it builds the restore lines from the state before the line)
        _ = p.resumeCommands(from: p.commands.count / 2)
        _ = p.resumeState(before: p.commands.count)
    }

    func testAnEmptyAndAGiantFile() {
        XCTAssertTrue(GCodeProgram(text: "").isEmpty)
        var text = ""
        for i in 0..<200_000 { text += "G1 X\(i % 300) Y\((i / 300) % 300) S500\n" }
        let t = Date()
        let p = GCodeProgram(text: text)
        XCTAssertLessThan(Date().timeIntervalSince(t), 10, "200 000 lines should be read in seconds")
        XCTAssertEqual(p.commands.count, 200_000)
    }
}
