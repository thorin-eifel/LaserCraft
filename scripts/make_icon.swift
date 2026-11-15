// Turns Resources/AppIcon-source.png into a macOS-style icon (rounded corners, transparent margin, soft shadow).
// usage: swift scripts/make_icon.swift <source.png> <out.png>
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: make_icon.swift <source.png> <out.png>"); exit(1)
}

let size = 1024
let art: CGFloat = 824                      // Apple's icon grid: artwork 824 pt inside a 1024 pt canvas
let margin = (CGFloat(size) - art) / 2
let radius = art * 0.2237                   // macOS icon corner radius
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: margin, y: margin, width: art, height: art)
let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

// artwork, trimmed 1.5% to drop the dark fringe at the source's own corners
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let trim = art * 0.015
ctx.interpolationQuality = .high
ctx.draw(cg, in: rect.insetBy(dx: -trim, dy: -trim))
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
