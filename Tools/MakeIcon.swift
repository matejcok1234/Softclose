import AppKit
import CoreGraphics

// Draws Softclose's icon: the lid caught mid-fold, tipping away from you.

func drawIcon(size: CGFloat, into context: CGContext) {
    let s = size / 1024.0
    func p(_ v: CGFloat) -> CGFloat { v * s }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // MARK: Plate
    let inset: CGFloat = p(96)
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let plateRadius = p(190)
    let platePath = CGPath(roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil)

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let plateGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.20, green: 0.21, blue: 0.24, alpha: 1),
        CGColor(red: 0.055, green: 0.055, blue: 0.070, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(plateGradient,
                               start: CGPoint(x: plate.minX, y: plate.maxY),
                               end: CGPoint(x: plate.maxX, y: plate.minY),
                               options: [])
    context.restoreGState()

    // Hairline so the plate reads on a light background too.
    context.saveGState()
    context.addPath(platePath)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    context.setLineWidth(p(3))
    context.strokePath()
    context.restoreGState()

    // MARK: Deck
    // A slab in perspective: wider at the near edge than at the hinge.
    let deckNearHalf = p(300)
    let deckFarHalf = p(238)
    let deckNearY = p(300)
    let hingeY = p(384)
    let centre = size / 2

    let deck = CGMutablePath()
    deck.move(to: CGPoint(x: centre - deckNearHalf, y: deckNearY))
    deck.addLine(to: CGPoint(x: centre + deckNearHalf, y: deckNearY))
    deck.addLine(to: CGPoint(x: centre + deckFarHalf, y: hingeY))
    deck.addLine(to: CGPoint(x: centre - deckFarHalf, y: hingeY))
    deck.closeSubpath()

    context.saveGState()
    context.addPath(deck)
    context.clip()
    let deckGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.62, green: 0.64, blue: 0.68, alpha: 1),
        CGColor(red: 0.34, green: 0.35, blue: 0.39, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(deckGradient,
                               start: CGPoint(x: centre, y: deckNearY),
                               end: CGPoint(x: centre, y: hingeY),
                               options: [])
    context.restoreGState()

    // MARK: Lid
    // Bottom edge pinned at the hinge, top edge foreshortened and raised. The
    // sides pull very slightly inward so the sheet reads as curving away
    // rather than tipping as a rigid board.
    let lidBottomHalf = deckFarHalf
    let lidTopHalf = p(196)
    let lidTopY = p(706)
    let waist = p(16)
    let topArc = p(16)

    let lid = CGMutablePath()
    lid.move(to: CGPoint(x: centre - lidBottomHalf, y: hingeY))
    lid.addQuadCurve(to: CGPoint(x: centre - lidTopHalf, y: lidTopY),
                     control: CGPoint(x: centre - (lidBottomHalf + lidTopHalf) / 2 + waist,
                                      y: (hingeY + lidTopY) / 2))
    lid.addQuadCurve(to: CGPoint(x: centre + lidTopHalf, y: lidTopY),
                     control: CGPoint(x: centre, y: lidTopY + topArc))
    lid.addQuadCurve(to: CGPoint(x: centre + lidBottomHalf, y: hingeY),
                     control: CGPoint(x: centre + (lidBottomHalf + lidTopHalf) / 2 - waist,
                                      y: (hingeY + lidTopY) / 2))
    lid.addLine(to: CGPoint(x: centre - lidBottomHalf, y: hingeY))
    lid.closeSubpath()

    // The glow the screen throws onto the deck.
    context.saveGState()
    context.addPath(deck)
    context.clip()
    context.setShadow(offset: .zero, blur: p(70), color: CGColor(red: 0.75, green: 0.85, blue: 1.0, alpha: 0.55))
    context.addPath(lid)
    context.setFillColor(CGColor(red: 0.75, green: 0.85, blue: 1.0, alpha: 0.9))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(lid)
    context.clip()
    let lidGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        CGColor(red: 0.80, green: 0.87, blue: 0.98, alpha: 1),
        CGColor(red: 0.36, green: 0.45, blue: 0.62, alpha: 1),
    ] as CFArray, locations: [0, 0.5, 1])!
    // Brightest at the hinge, falling off as the sheet turns away.
    context.drawLinearGradient(lidGradient,
                               start: CGPoint(x: centre, y: hingeY),
                               end: CGPoint(x: centre, y: lidTopY + p(60)),
                               options: [])

    // Rows bunching up toward the far edge — the cue that sells foreshortening.
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
    context.setLineWidth(p(5))
    for fraction in [0.42, 0.68, 0.86] as [CGFloat] {
        let y = hingeY + (lidTopY - hingeY) * fraction
        let halfWidth = lidBottomHalf + (lidTopHalf - lidBottomHalf) * fraction
        context.move(to: CGPoint(x: centre - halfWidth + p(18), y: y))
        context.addLine(to: CGPoint(x: centre + halfWidth - p(18), y: y))
        context.strokePath()
    }
    context.restoreGState()

    // Highlight along the hinge, where the two surfaces meet.
    context.saveGState()
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
    context.setLineWidth(p(7))
    context.setLineCap(.round)
    context.move(to: CGPoint(x: centre - lidBottomHalf + p(6), y: hingeY))
    context.addLine(to: CGPoint(x: centre + lidBottomHalf - p(6), y: hingeY))
    context.strokePath()
    context.restoreGState()
}

func writePNG(size: Int, to url: URL) {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no context") }
    drawIcon(size: CGFloat(size), into: context)
    guard let image = context.makeImage() else { fatalError("no image") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    try! data.write(to: url)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in variants {
    writePNG(size: size, to: outputDirectory.appendingPathComponent("\(name).png"))
}
print("wrote \(variants.count) sizes to \(outputDirectory.path)")
