import XCTest
@testable import LaserGRBLMac

final class SafetyTests: XCTestCase {
    func testLaserOnCommandsNeedTheEyeProtectionCheck() {
        for g in ["M3 S10", "M4", "G1 X5 M3", "g90\nm3 s100", "M03 S5", "G0 X1\nM4 S20"] {
            XCTAssertTrue(LaserSafety.firesLaser(g), g)
        }
    }

    func testOtherCommandsDoNot() {
        for g in ["$H", "$X", "M5", "G92 X0 Y0", "G0 X0 Y0", "G1 X3 F100", "M30", "M33", "M40"] {
            XCTAssertFalse(LaserSafety.firesLaser(g), g)
        }
    }
}
