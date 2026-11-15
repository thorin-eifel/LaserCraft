import SwiftUI
import LaserGRBLCore

/// Pre-built drawing paths for the loaded job, in machine millimetres.
final class PreviewModel: ObservableObject {
    static let levels = 8

    struct Layer { var path = Path(); var gray: Double }

    private(set) var travel = Path()
    private(set) var burn: [Layer] = (0..<PreviewModel.levels).map { i in
        let t = Double(i + 1) / Double(PreviewModel.levels)
        return Layer(gray: 0.55 - 0.55 * t)   // lowest power = mid grey, highest = black
    }
    private(set) var done = Path()
    private(set) var program: GCodeProgram?
    private var doneCursor = 0
    private var doneUpTo = 0

    @Published var revision = 0          // bump to redraw
    @Published var requestFit = false

    func set(program p: GCodeProgram) {
        program = p
        var t = Path()
        var layers = [Path](repeating: Path(), count: PreviewModel.levels)
        let maxP = max(p.maxPower, 1)
        var last: [(Float, Float)?] = Array(repeating: nil, count: PreviewModel.levels)
        var lastTravel: (Float, Float)? = nil
        for s in p.segments {
            if s.power > 0 {
                let lv = min(PreviewModel.levels - 1, Int(s.power / maxP * Float(PreviewModel.levels - 1) + 0.5))
                if let l = last[lv], l.0 == s.x0, l.1 == s.y0 {
                    layers[lv].addLine(to: CGPoint(x: CGFloat(s.x1), y: CGFloat(s.y1)))
                } else {
                    layers[lv].move(to: CGPoint(x: CGFloat(s.x0), y: CGFloat(s.y0)))
                    layers[lv].addLine(to: CGPoint(x: CGFloat(s.x1), y: CGFloat(s.y1)))
                }
                last[lv] = (s.x1, s.y1)
            } else {
                if let l = lastTravel, l.0 == s.x0, l.1 == s.y0 {
                    t.addLine(to: CGPoint(x: CGFloat(s.x1), y: CGFloat(s.y1)))
                } else {
                    t.move(to: CGPoint(x: CGFloat(s.x0), y: CGFloat(s.y0)))
                    t.addLine(to: CGPoint(x: CGFloat(s.x1), y: CGFloat(s.y1)))
                }
                lastTravel = (s.x1, s.y1)
            }
        }
        travel = t
        for i in 0..<PreviewModel.levels { burn[i].path = layers[i] }
        done = Path(); doneCursor = 0; doneUpTo = 0
        revision += 1
    }

    func clear() {
        program = nil; travel = Path(); done = Path(); doneCursor = 0; doneUpTo = 0
        for i in 0..<PreviewModel.levels { burn[i].path = Path() }
        revision += 1
    }

    /// Adds the part of the job the machine has already accepted to the "done" overlay.
    func updateDone(upTo n: Int) {
        guard let p = program else { return }
        if n < doneUpTo { done = Path(); doneCursor = 0 }
        doneUpTo = n
        var any = false
        var lastEnd: (Float, Float)? = nil
        while doneCursor < p.segments.count, Int(p.segments[doneCursor].command) < n {
            let s = p.segments[doneCursor]
            doneCursor += 1
            if s.power <= 0 { continue }
            if let l = lastEnd, l.0 == s.x0, l.1 == s.y0 {
                done.addLine(to: CGPoint(x: CGFloat(s.x1), y: CGFloat(s.y1)))
            } else {
                done.move(to: CGPoint(x: CGFloat(s.x0), y: CGFloat(s.y0)))
                done.addLine(to: CGPoint(x: CGFloat(s.x1), y: CGFloat(s.y1)))
            }
            lastEnd = (s.x1, s.y1)
            any = true
        }
        if any { revision += 1 }
    }
}
