import XCTest
import AppKit
@testable import LaserGRBLMac

final class IconTests: XCTestCase {
    /// Every symbol the app maps must exist in the installed SF Symbols.
    func testAllMappedSymbolsExist() {
        for (key, symbol) in Symbols.map {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(key) -> \(symbol)")
        }
    }

    /// Every icon name used in the Swift code (and offered for custom buttons) has a mapping.
    func testEveryIconUsedInTheCodeIsMapped() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = src.appendingPathComponent("Sources/LaserGRBLMac")
        var names = Set<String>()
        let patterns = [#"icon:\s*"(\w+)""#, #"UIcon\(name:\s*"(\w+)""#, #"arrow\(\.\w+,\s*"(\w+)""#, #"make\("[^"]+",\s*"[^"]*",\s*icon:\s*"(\w+)""#]
        for f in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) where f.pathExtension == "swift" {
            let text = try String(contentsOf: f, encoding: .utf8)
            for p in patterns {
                let re = try NSRegularExpression(pattern: p)
                for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    names.insert(String(text[Range(m.range(at: 1), in: text)!]))
                }
            }
        }
        XCTAssertGreaterThan(names.count, 15)
        for n in names { XCTAssertNotNil(Symbols.map[n], "icon \(n) has no SF Symbol") }
    }

    /// Icons are SF Symbols only: no bundled SVG artwork is left.
    func testNoSVGFilesRemain() throws {
        let res = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let enumerator = FileManager.default.enumerator(at: res, includingPropertiesForKeys: nil)
        while let u = enumerator?.nextObject() as? URL { XCTAssertNotEqual(u.pathExtension, "svg", u.path) }
    }
}

final class SoundTests: XCTestCase {
    func testEverySoundFileExists() {
        for kind in Sounds.Kind.allCases {
            XCTAssertTrue(FileManager.default.fileExists(atPath: "/System/Library/Sounds/\(kind.rawValue).aiff"), kind.rawValue)
        }
        // distinct sounds for the different moments
        XCTAssertEqual(Set(Sounds.Kind.allCases.map { $0.rawValue }).count, Sounds.Kind.allCases.count)
    }
}
