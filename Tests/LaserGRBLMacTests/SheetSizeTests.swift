import XCTest
import SwiftUI
import AppKit
@testable import LaserGRBLMac

@MainActor
final class SheetSizeTests: XCTestCase {
    func testBigDialogsOpenAsLargeAsTheWindow() throws {
        let model = AppModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 950), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let size = SheetSize.full
        XCTAssertEqual(size.width, window.frame.width - 40, accuracy: 1)
        XCTAssertEqual(size.height, window.frame.height - 40, accuracy: 1)
        let image = NSHostingView(rootView: ImageImportView(url: root.appendingPathComponent("examples/sample-picture.png")).environmentObject(model))
        XCTAssertEqual(image.fittingSize.width, size.width, accuracy: 2, "picture import fills the window")
        XCTAssertEqual(image.fittingSize.height, size.height, accuracy: 2)
        let vector = NSHostingView(rootView: VectorSheet(source: .text).environmentObject(model))
        XCTAssertEqual(vector.fittingSize.width, size.width, accuracy: 2)
        // never smaller than what the controls need
        XCTAssertGreaterThanOrEqual(size.width, 820); XCTAssertGreaterThanOrEqual(size.height, 640)
    }
}
