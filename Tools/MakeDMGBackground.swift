import AppKit
import CoreGraphics

// The backdrop for the install window: dark, with the drop target marked out
// and an arrow between the two icons. Drawn rather than shipped as a binary
// asset, so it stays in step with the icon and is diffable.

let width = 600.0, height = 400.0

func draw(scale: CGFloat, to url: URL) {
    let pixelWidth = Int(width * scale), pixelHeight = Int(height * scale)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no context") }
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)

    // Ground, matching the icon's plate.
    let base = CGGradient(colorsSpace: colorSpace, colors: [
        CGColor(red: 0.42, green: 0.44, blue: 0.48, alpha: 1),
        CGColor(red: 0.29, green: 0.30, blue: 0.34, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(base, start: CGPoint(x: 0, y: height),
                               end: CGPoint(x: width, y: 0), options: [])

    // A cool wash behind the app, where the screen's light would fall.
    if let glow = CGGradient(colorsSpace: colorSpace, colors: [
        CGColor(red: 0.45, green: 0.6, blue: 0.9, alpha: 0.16),
        CGColor(red: 0.45, green: 0.6, blue: 0.9, alpha: 0.0),
    ] as CFArray, locations: [0, 1]) {
        context.drawRadialGradient(glow, startCenter: CGPoint(x: 165, y: 235), startRadius: 0,
                                   endCenter: CGPoint(x: 165, y: 235), endRadius: 210,
                                   options: [])
    }

    // Arrow between the icons: a shaft that fades in, and a solid head.
    let shaftY = 235.0
    if let fade = CGGradient(colorsSpace: colorSpace, colors: [
        CGColor(gray: 1, alpha: 0.0),
        CGColor(gray: 1, alpha: 0.55),
    ] as CFArray, locations: [0, 1]) {
        context.saveGState()
        context.addRect(CGRect(x: 258, y: shaftY - 1.5, width: 74, height: 3))
        context.clip()
        context.drawLinearGradient(fade, start: CGPoint(x: 258, y: 0),
                                   end: CGPoint(x: 332, y: 0), options: [])
        context.restoreGState()
    }
    context.setFillColor(CGColor(gray: 1, alpha: 0.55))
    context.move(to: CGPoint(x: 348, y: shaftY))
    context.addLine(to: CGPoint(x: 330, y: shaftY + 9))
    context.addLine(to: CGPoint(x: 330, y: shaftY - 9))
    context.closePath()
    context.fillPath()

    // Ring marking where Applications sits, so the target reads as a target
    // even before the icon is drawn over it by the Finder.
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
    context.setLineWidth(1.5)
    let ring = CGRect(x: 435 - 62, y: 235 - 62, width: 124, height: 124)
    context.addPath(CGPath(roundedRect: ring, cornerWidth: 26, cornerHeight: 26, transform: nil))
    context.strokePath()

    // Wordmark and instruction.
    func text(_ string: String, size: CGFloat, weight: NSFont.Weight,
              alpha: CGFloat, y: CGFloat, tracking: CGFloat = 0) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: alpha),
            .kern: tracking,
        ]
        let line = NSAttributedString(string: string, attributes: attributes)
        let bounds = line.size()
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        line.draw(at: NSPoint(x: (width - bounds.width) / 2, y: y))
        NSGraphicsContext.restoreGraphicsState()
    }
    text("Softclose", size: 21, weight: .semibold, alpha: 0.98, y: 96)
    text("Drag it across to install", size: 12, weight: .regular, alpha: 0.62, y: 72)

    guard let image = context.makeImage() else { fatalError("no image") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: width, height: height)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.lastPathComponent) at \(Int(scale))x")
}

let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build")
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
draw(scale: 1, to: directory.appendingPathComponent("dmg-background.png"))
draw(scale: 2, to: directory.appendingPathComponent("dmg-background@2x.png"))
