import XCTest
import SwiftUI
import AppKit
@testable import LaserGRBLMac
import LaserGRBLCore

/// Renders the job preview to an image to make sure the drawing code produces visible output.
@MainActor
final class SnapshotTests: XCTestCase {
    func testPreviewRendersBurnLines() throws {
        var lines = ["G90", "M3", "G0 X10 Y10"]
        for r in [30.0, 20.0, 10.0] {
            lines.append("G0 X\(50 + r) Y50")
            lines.append("G1 X\(50 + r) Y50 F1200 S800")
            for i in 1...72 {
                let a = Double(i) * .pi / 36
                lines.append(String(format: "G1 X%.3f Y%.3f", 50 + r * cos(a), 50 + r * sin(a)))
            }
        }
        lines.append("M5")
        let model = AppModel()
        let program = GCodeProgram(text: lines.joined(separator: "\n"), name: "circles.nc")
        model.setProgram(program)

        let view = PreviewView(preview: model.preview, controller: model.controller)
            .environmentObject(model)
            .frame(width: 640, height: 480)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, 640)
        XCTAssertEqual(image.size.height, 480)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        // something other than the white background must have been drawn
        var dark = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let c = rep.colorAt(x: x, y: y), c.redComponent < 0.5, c.greenComponent < 0.5 { dark += 1 }
            }
        }
        XCTAssertGreaterThan(dark, 50, "no burn lines were drawn")
    }
}

@MainActor
final class LayoutSnapshotTests: XCTestCase {
    func testLeftPanelAndBarsRender() throws {
        let model = AppModel()
        model.setProgram(GCodeProgram(text: "G90\nM3 S0\nG0 X10 Y10\nG1 X20 Y10 F1000 S500\nG1 X20 Y20\nM5", name: "demo.nc"))
        let view = VStack(spacing: 0) {
            LeftPanel(controller: model.controller).frame(width: 360, height: 520)
            Divider()
            ActionRow(controller: model.controller).frame(width: 700)
            StatusBar(controller: model.controller).frame(width: 900)
        }
        .environmentObject(model).background(Color.white)
        let r = ImageRenderer(content: view)
        r.scale = 1
        let img = try XCTUnwrap(r.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("laserc-layout.png"))
        XCTAssertGreaterThan(img.size.height, 400)
    }
}
