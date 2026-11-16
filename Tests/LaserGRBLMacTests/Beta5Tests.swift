import XCTest
import AppKit
@testable import LaserGRBLMac
import LaserGRBLCore

final class ViewportTests: XCTestCase {
    let area = (400.0, 300.0), size = CGSize(width: 800, height: 600)

    func testFitShowsTheWholeAreaCentred() {
        let v = LayoutViewport()
        let s = v.scale(area: area, size: size)
        XCTAssertEqual(s, min((800 - 48) / 400, (600 - 48) / 300), accuracy: 1e-9)
        let o = v.origin(area: area, size: size)
        XCTAssertEqual(Double(o.x) + 400 * s / 2, 400, accuracy: 1e-9)
        XCTAssertEqual(Double(o.y) + 300 * s / 2, 300, accuracy: 1e-9)
    }

    func testZoomKeepsThePointUnderThePointerWhereItIs() {
        var v = LayoutViewport()
        let anchor = CGPoint(x: 600, y: 200)
        func mm(_ v: LayoutViewport) -> (Double, Double) {
            let s = v.scale(area: area, size: size), o = v.origin(area: area, size: size)
            return ((Double(anchor.x) - Double(o.x)) / s, area.1 - (Double(anchor.y) - Double(o.y)) / s)
        }
        let before = mm(v)
        v.zoom(by: 3, around: anchor, area: area, size: size)
        XCTAssertEqual(v.zoom, 3, accuracy: 1e-9)
        XCTAssertEqual(mm(v).0, before.0, accuracy: 1e-6); XCTAssertEqual(mm(v).1, before.1, accuracy: 1e-6)
        v.zoom(by: 0.5, around: CGPoint(x: 100, y: 500), area: area, size: size)
        XCTAssertEqual(v.zoom, 1.5, accuracy: 1e-9)
        v.zoom(by: 1000, around: anchor, area: area, size: size)
        XCTAssertEqual(v.zoom, LayoutViewport.zoomRange.upperBound, "limited")
        v.zoom(by: 1e-9, around: anchor, area: area, size: size)
        XCTAssertEqual(v.zoom, LayoutViewport.zoomRange.lowerBound)
        v.fit()
        XCTAssertEqual(v, LayoutViewport())
    }

    func testPanMovesTheView() {
        var v = LayoutViewport()
        let o0 = v.origin(area: area, size: size)
        v.pan = CGPoint(x: 30, y: -10)
        let o1 = v.origin(area: area, size: size)
        XCTAssertEqual(Double(o1.x - o0.x), 30, accuracy: 1e-9); XCTAssertEqual(Double(o1.y - o0.y), -10, accuracy: 1e-9)
    }
}

@MainActor
final class LayoutArrangeTests: XCTestCase {
    func box(_ m: LayoutModel, _ name: String, x: Double, y: Double, w: Double = 10, h: Double = 10) -> LayoutObject {
        let shape = [Polyline([Pt(0, 0), Pt(10, 0), Pt(10, 10), Pt(0, 10)], closed: true)]
        return m.addVectors(shape, name: name, layer: 0, at: Pt(x, y), size: (w, h))!
    }

    func testShiftClickBuildsAMultipleSelectionThatMovesTogether() {
        let m = LayoutModel()
        let a = box(m, "a", x: 0, y: 0), b = box(m, "b", x: 30, y: 0), c = box(m, "c", x: 60, y: 0)
        m.select(a.id)
        m.select(b.id, additive: true)
        XCTAssertEqual(Set(m.selectedIDs), [a.id, b.id])
        m.select(c.id, additive: true); m.select(b.id, additive: true)
        XCTAssertEqual(Set(m.selectedIDs), [a.id, c.id], "a second shift-click takes it out again")
        m.moveSelected(by: 5, 7, from: Dictionary(uniqueKeysWithValues: m.selectedObjects.map { ($0.id, Pt($0.x, $0.y)) }))
        m.endInteraction()
        XCTAssertEqual(m.doc.objects.first { $0.id == a.id }?.x, 5); XCTAssertEqual(m.doc.objects.first { $0.id == c.id }?.y, 7)
        XCTAssertEqual(m.doc.objects.first { $0.id == b.id }?.x, 30, "the unselected one stays")
        m.undo()
        XCTAssertEqual(m.doc.objects.first { $0.id == a.id }?.x, 0, "the whole move is one undo step")
        m.selectAll()
        XCTAssertEqual(m.selectedIDs.count, 3)
        m.deleteSelection()
        XCTAssertTrue(m.doc.isEmpty); XCTAssertNil(m.selection); XCTAssertTrue(m.extraSelection.isEmpty)
    }

    func testAlignDistributeAndArrayFromTheModel() {
        let m = LayoutModel()
        let a = box(m, "a", x: 0, y: 0), b = box(m, "b", x: 33, y: 8), c = box(m, "c", x: 90, y: 20)
        m.selectAll()
        m.align(.bottom, workArea: (400, 300))
        XCTAssertEqual(m.doc.objects.map { $0.y }, [0, 0, 0])
        m.distribute(.horizontal)
        XCTAssertEqual(m.doc.objects[1].x, 45, accuracy: 1e-9)
        m.undo(); m.undo()
        XCTAssertEqual(m.doc.objects[1].y, 8, accuracy: 1e-9)
        // a single object is aligned with the work area
        m.select(c.id)
        m.align(.right, workArea: (400, 300))
        XCTAssertEqual(m.doc.objects[2].x, 390, accuracy: 1e-9)
        // an array of a text with a number
        var spec = TextSpec(); spec.text = "SN {n:2}"
        let t = m.addText(spec, layer: 0, at: Pt(10, 100))
        XCTAssertEqual(m.makeArray(rows: 2, columns: 2, gapX: 3, gapY: 3, numberFrom: 5), 3)
        XCTAssertEqual(m.doc.objects.count, 3 + 4)
        let texts = m.doc.objects.compactMap { o -> String? in if case .text(let s) = o.kind { return s.text }; return nil }
        XCTAssertEqual(texts, ["SN 05", "SN 06", "SN 07", "SN 08"])
        XCTAssertEqual(m.selection, t.id); XCTAssertEqual(m.extraSelection.count, 3)
        m.undo()
        XCTAssertEqual(m.doc.objects.count, 4, "one undo takes the whole array away (three boxes and the text stay)")
        _ = a; _ = b
    }

    func testPictureCopiesGetTheirOwnPictureData() throws {
        let m = LayoutModel()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let pic = try XCTUnwrap(m.addImage(data: png, name: "pic"))
        XCTAssertEqual(m.makeArray(rows: 1, columns: 3, gapX: 2, gapY: 0, numberFrom: nil), 2)
        let ids = m.doc.objects.compactMap { $0.kind.imageIDValue }
        XCTAssertEqual(Set(ids).count, 3)
        for id in ids { XCTAssertNotNil(m.cgImage(id)) }
        _ = pic
    }
}

extension LayoutKind { var imageIDValue: String? { if case .image(let id, _) = self { return id }; return nil } }

final class UpdaterGateTests: XCTestCase {
    func testSparkleOnlyStartsWithAKeyAnHttpsFeedAndARealApp() {
        let on: [String: Any] = ["SUPublicEDKey": "abc123=", "SUFeedURL": "https://example.com/appcast.xml"]
        XCTAssertTrue(AutoUpdater.shouldEnable(info: on, bundlePath: "/Applications/LaserCraft.app"))
        XCTAssertFalse(AutoUpdater.shouldEnable(info: on, bundlePath: "/tmp/.build/debug"), "not inside a real app")
        XCTAssertFalse(AutoUpdater.shouldEnable(info: ["SUFeedURL": "https://example.com/a.xml"], bundlePath: "/A.app"), "no key")
        XCTAssertFalse(AutoUpdater.shouldEnable(info: ["SUPublicEDKey": "  ", "SUFeedURL": "https://example.com/a.xml"], bundlePath: "/A.app"))
        XCTAssertFalse(AutoUpdater.shouldEnable(info: ["SUPublicEDKey": "k", "SUFeedURL": "http://example.com/a.xml"], bundlePath: "/A.app"), "https only")
        XCTAssertFalse(AutoUpdater.shouldEnable(info: [:], bundlePath: "/A.app"))
        XCTAssertFalse(AutoUpdater.shared.isEnabled, "the beta ships without a key: the GitHub check is used")
    }

    func testInfoPlistPointsAtTheAppcastButCarriesNoKey() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let d = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        XCTAssertEqual(d["SUFeedURL"] as? String, "https://raw.githubusercontent.com/thorin-eifel/LaserCraft/main/appcast.xml")
        XCTAssertNil(d["SUPublicEDKey"], "the key is added by whoever signs the updates, never guessed")
    }
}
