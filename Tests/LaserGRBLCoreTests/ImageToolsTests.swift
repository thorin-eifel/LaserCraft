import XCTest
import CoreGraphics
@testable import LaserGRBLCore

final class ImageToolsTests: XCTestCase {
    /// 4 x 2 picture: top row red, green, blue, white; bottom row black, black, black, black.
    func sample() throws -> CGImage {
        let px: [[(UInt8, UInt8, UInt8)]] = [
            [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)],
            [(0, 0, 0), (0, 0, 0), (0, 0, 0), (0, 0, 0)],
        ]
        var rgba: [UInt8] = []
        for row in px { for p in row { rgba += [p.0, p.1, p.2, 255] } }
        return try XCTUnwrap(RasterImage(width: 4, height: 2, rgba: rgba).makeCGImage())
    }

    func color(_ img: CGImage, _ x: Int, _ y: Int) throws -> (UInt8, UInt8, UInt8) {
        let r = try XCTUnwrap(RasterImage(cgImage: img, width: img.width, height: img.height))
        let i = (y * r.width + x) * 4
        return (r.rgba[i], r.rgba[i + 1], r.rgba[i + 2])
    }

    func testRotateClockwiseSwapsTheSidesAndMovesPixels() throws {
        var o = RasterOptions(); o.rotation = 90
        let t = RasterConverter.transformed(try sample(), o)
        XCTAssertEqual(t.width, 2); XCTAssertEqual(t.height, 4)
        // clockwise: the old top row becomes the right column, read top to bottom: red, green, blue, white
        XCTAssertTrue(try color(t, 1, 0) == (255, 0, 0))
        XCTAssertTrue(try color(t, 1, 1) == (0, 255, 0))
        XCTAssertTrue(try color(t, 1, 2) == (0, 0, 255))
        XCTAssertTrue(try color(t, 0, 0) == (0, 0, 0))
        o.rotation = 270
        let c = RasterConverter.transformed(try sample(), o)
        XCTAssertTrue(try color(c, 0, 3) == (255, 0, 0), "counter-clockwise puts red at the bottom left")
        o.rotation = 180
        let u = RasterConverter.transformed(try sample(), o)
        XCTAssertEqual(u.width, 4)
        XCTAssertTrue(try color(u, 3, 1) == (255, 0, 0))
    }

    func testMirroring() throws {
        var o = RasterOptions(); o.flipH = true
        let h = RasterConverter.transformed(try sample(), o)
        XCTAssertTrue(try color(h, 3, 0) == (255, 0, 0)); XCTAssertTrue(try color(h, 0, 0) == (255, 255, 255))
        o = RasterOptions(); o.flipV = true
        let v = RasterConverter.transformed(try sample(), o)
        XCTAssertTrue(try color(v, 0, 1) == (255, 0, 0)); XCTAssertTrue(try color(v, 0, 0) == (0, 0, 0))
    }

    func testCrop() throws {
        var o = RasterOptions(); o.cropLeft = 0.25; o.cropBottom = 0.5
        let t = RasterConverter.transformed(try sample(), o)
        XCTAssertEqual(t.width, 3); XCTAssertEqual(t.height, 1)
        XCTAssertTrue(try color(t, 0, 0) == (0, 255, 0), "the first column (red) and the bottom row are gone")
        XCTAssertEqual(RasterConverter.aspect(of: try sample(), o), 1.0 / 3.0, accuracy: 0.001)
        o.rotation = 90
        XCTAssertEqual(RasterConverter.aspect(of: try sample(), o), 3.0, accuracy: 0.001)
    }

    func testGeneratedGCodeFollowsTheTransform() throws {
        // a black dot in the top left corner of a white picture ends up at the right after a clockwise turn
        var rgba = [UInt8](repeating: 255, count: 4 * 4 * 4)
        rgba[0] = 0; rgba[1] = 0; rgba[2] = 0
        let cg = try XCTUnwrap(RasterImage(width: 4, height: 4, rgba: rgba).makeCGImage())
        var o = RasterOptions(); o.widthMM = 4; o.heightMM = 4; o.linesPerMM = 1; o.formula = .simpleAverage; o.whiteClip = 0
        o.rotation = 90
        let program = GCodeProgram(text: try XCTUnwrap(RasterConverter.generate(image: cg, options: o)))
        XCTAssertEqual(program.burnBounds.minX, 3, accuracy: 0.51)
        XCTAssertEqual(program.burnBounds.minY, 3, accuracy: 0.51, "top of the picture = largest Y")
    }

    func testResolutionHelper() {
        XCTAssertEqual(ResolutionHelper.suggestedLinesPerMM(spotSize: 0.1), 10)
        XCTAssertEqual(ResolutionHelper.suggestedLinesPerMM(spotSize: 0.15), 6.5)
        XCTAssertEqual(ResolutionHelper.suggestedLinesPerMM(spotSize: 0.001), 20, "capped")
        XCTAssertEqual(ResolutionHelper.suggestedLinesPerMM(spotSize: 5), 0.5, "floored")
        XCTAssertFalse(ResolutionHelper.linesOverlap(linesPerMM: 6, spotSize: 0.15))
        XCTAssertTrue(ResolutionHelper.linesOverlap(linesPerMM: 12, spotSize: 0.15))
        // 100 x 50 mm at 4 lines/mm = 200 lines of 100 mm at 1200 mm/min = 1000 s
        XCTAssertEqual(ResolutionHelper.engravingSeconds(widthMM: 100, heightMM: 50, linesPerMM: 4, speed: 1200), 1000, accuracy: 0.01)
    }

    func testPresetKeepsThePicturesOwnGeometry() throws {
        var current = RasterOptions()
        current.widthMM = 80; current.heightMM = 60; current.offsetX = 5; current.rotation = 90; current.cropLeft = 0.1
        let preset = try XCTUnwrap(ImagePreset.builtIns.first { $0.name == "Sharp logo" })
        let applied = preset.applied(to: current)
        XCTAssertEqual(applied.widthMM, 80); XCTAssertEqual(applied.offsetX, 5)
        XCTAssertEqual(applied.rotation, 90); XCTAssertEqual(applied.cropLeft, 0.1)
        XCTAssertEqual(applied.contrast, 150); XCTAssertEqual(applied.linesPerMM, 5)
    }

    func testPresetsSurviveSavingAndLoading() throws {
        var o = RasterOptions(); o.tool = .dithering; o.dithering = .stucki; o.direction = .diagonal; o.laserOn = "M3"
        let p = ImagePreset(name: "Mine", options: o, minPowerPercent: 10, maxPowerPercent: 70)
        let data = try JSONEncoder().encode([p])
        let back = try JSONDecoder().decode([ImagePreset].self, from: data)
        XCTAssertEqual(back, [p])
        XCTAssertGreaterThanOrEqual(ImagePreset.builtIns.count, 4)
    }
}
