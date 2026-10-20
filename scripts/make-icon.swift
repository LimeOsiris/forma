// Generates Forma's app icon as an .iconset (then `iconutil -c icns`).
// Concept: a rounded square (the original format) overlapping a circle (the new one);
// the overlap is knocked out to suggest one becoming the other. Monochrome graphite
// with a single restrained blue, legible down to 16 px.
//
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    // macOS icon grid: 824/1024 body with a soft drop shadow.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset * 1.12, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2237
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0.96, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Very subtle vertical sheen.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                              colors: [CGColor(gray: 0.995, alpha: 1), CGColor(gray: 0.915, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()

    // Hairline edge.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: s * 0.001, dy: s * 0.001), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
    ctx.setLineWidth(max(1, s * 0.002))
    ctx.strokePath()

    // The mark.
    let unit = body.width
    let sq = CGRect(x: body.minX + unit * 0.2, y: body.minY + unit * 0.36, width: unit * 0.42, height: unit * 0.42)
    let circle = CGRect(x: body.minX + unit * 0.38, y: body.minY + unit * 0.2, width: unit * 0.42, height: unit * 0.42)
    let sqPath = CGPath(roundedRect: sq, cornerWidth: unit * 0.085, cornerHeight: unit * 0.085, transform: nil)
    let circlePath = CGPath(ellipseIn: circle, transform: nil)
    let graphite = CGColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
    let blue = CGColor(srgbRed: 0.04, green: 0.45, blue: 0.96, alpha: 1)

    // Filled circle (destination format) in the accent.
    ctx.addPath(circlePath)
    ctx.setFillColor(blue)
    ctx.fillPath()

    // Square outline (source format), thick enough for 16 px.
    let stroke = max(1.2, unit * 0.06)
    ctx.addPath(CGPath(roundedRect: sq.insetBy(dx: stroke / 2, dy: stroke / 2), cornerWidth: unit * 0.07, cornerHeight: unit * 0.07, transform: nil))
    ctx.setStrokeColor(graphite)
    ctx.setLineWidth(stroke)
    ctx.strokePath()

    // Where they overlap, the square's outline turns white over the circle: the "transformation".
    ctx.saveGState()
    ctx.addPath(circlePath)
    ctx.clip()
    ctx.addPath(CGPath(roundedRect: sq.insetBy(dx: stroke / 2, dy: stroke / 2), cornerWidth: unit * 0.07, cornerHeight: unit * 0.07, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(stroke)
    ctx.strokePath()
    _ = sqPath
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("\(name).png"))
}
print(out.path)
