// Generates the sample content and composites the images used in README.md.
//
//   swift scripts/readme-assets.swift samples <dir>          # original demo photo + documents
//   swift scripts/readme-assets.swift window <in.png> <out.png> [--dark]
//   swift scripts/readme-assets.swift hero <icon.png> <wheel.png> <out.png>
//   swift scripts/readme-assets.swift pair <light.png> <dark.png> <out.png>
//   swift scripts/readme-assets.swift flow <a.png> <b.png> <c.png> <out.png>
//
// Everything is drawn here or captured from the app; no third-party artwork is used.
import AppKit
import CoreGraphics

let args = Array(CommandLine.arguments.dropFirst())
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func canvas(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

func load(_ path: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

func save(_ ctx: CGContext, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print(path)
}

func text(_ s: String, in ctx: CGContext, at p: CGPoint, size: CGFloat, weight: NSFont.Weight, color c: NSColor, kern: CGFloat = 0) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c, .kern: kern])
    attr.draw(at: p)
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Sample content

/// An original, procedurally drawn landscape used as the demo photo.
func landscape(_ path: String) {
    let w = 2400, h = 1600
    let ctx = canvas(w, h)
    let W = CGFloat(w), H = CGFloat(h)
    let sky = CGGradient(colorsSpace: sRGB, colors: [color(0x1d2b64), color(0x5b4a8b), color(0xf3906b), color(0xfcd581)] as CFArray, locations: [0, 0.45, 0.8, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: H * 0.42), options: [.drawsAfterEndLocation])
    // Sun glow
    let glow = CGGradient(colorsSpace: sRGB, colors: [color(0xfff1c1, 0.95), color(0xffc46b, 0.35), color(0xffc46b, 0)] as CFArray, locations: [0, 0.25, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W * 0.66, y: H * 0.5), startRadius: 0, endCenter: CGPoint(x: W * 0.66, y: H * 0.5), endRadius: W * 0.32, options: [])
    ctx.setFillColor(color(0xfff6d8))
    ctx.fillEllipse(in: CGRect(x: W * 0.66 - 90, y: H * 0.5 - 90, width: 180, height: 180))
    // Mountain ridges, back to front
    func ridge(base: CGFloat, amp: CGFloat, seed: Double, fill: CGColor) {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: 0))
        var x: CGFloat = 0
        while x <= W {
            let t = Double(x / W)
            let y = base + amp * CGFloat(sin(t * 7 + seed) * 0.5 + sin(t * 17 + seed * 2) * 0.25 + sin(t * 41 + seed * 3) * 0.08)
            ctx.addLine(to: CGPoint(x: x, y: y))
            x += 8
        }
        ctx.addLine(to: CGPoint(x: W, y: 0))
        ctx.closePath()
        ctx.setFillColor(fill)
        ctx.fillPath()
    }
    ridge(base: H * 0.5, amp: 110, seed: 1.3, fill: color(0x8b5d86, 0.85))
    ridge(base: H * 0.43, amp: 130, seed: 2.9, fill: color(0x5a3f73))
    ridge(base: H * 0.35, amp: 90, seed: 4.2, fill: color(0x35295a))
    // Lake with reflection
    let lake = CGGradient(colorsSpace: sRGB, colors: [color(0xf6a77a, 0.9), color(0x26204a)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: H * 0.27))
    ctx.drawLinearGradient(lake, start: CGPoint(x: 0, y: H * 0.27), end: CGPoint(x: 0, y: 0), options: [])
    ctx.setFillColor(color(0xfff1c1, 0.55))
    for i in 0..<14 {
        let y = H * 0.25 - CGFloat(i) * 30
        let half = CGFloat(160 - i * 9)
        ctx.fill(CGRect(x: W * 0.66 - half, y: y, width: half * 2, height: 6))
    }
    ctx.restoreGState()
    ridge(base: H * 0.12, amp: 40, seed: 6.1, fill: color(0x191433))
    save(ctx, path)
}

func samples(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    landscape(dir + "/Lake at Dusk.png")
    let md = """
    # Forma 1.0 Launch Plan

    Forma turns everyday file conversions into **two clicks**: right-click a file in Finder, pick a format on the wheel, done.

    ## Goals

    - Ship a native, *privacy-first* converter that feels built into macOS
    - Cover the conversions people actually do: images, PDFs, documents
    - Keep every file on the Mac — **no uploads, no accounts**

    ## Milestones

    | Milestone | Owner | Status |
    |-----------|-------|:------:|
    | Conversion engine | Core | ✅ Done |
    | Radial wheel | Design | ✅ Done |
    | Editors | Apps | ✅ Done |
    | Notarized release | Release | ⏳ Next |

    > “The best interface is the one you never have to look for.”

    ## Try it

    ```bash
    scripts/build.sh && scripts/install.sh
    ```

    Then select a file in Finder and press `⌥⌘K`.
    """
    try! md.write(toFile: dir + "/Launch Plan.md", atomically: true, encoding: .utf8)
    print(dir + "/Launch Plan.md")
}

// MARK: - Compositing

/// Wraps a raw window capture in macOS window chrome: rounded corners, traffic lights,
/// hairline border and a soft shadow, on a transparent background.
func window(_ input: String, _ output: String, dark: Bool) {
    let img = load(input)
    let scale: CGFloat = 2
    let pad = 60 * scale
    let w = CGFloat(img.width), h = CGFloat(img.height)
    let ctx = canvas(Int(w + pad * 2), Int(h + pad * 2))
    let frame = CGRect(x: pad, y: pad, width: w, height: h)
    let radius = 12 * scale
    let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * scale), blur: 40 * scale, color: color(0x000000, dark ? 0.55 : 0.28))
    ctx.addPath(path)
    ctx.setFillColor(dark ? color(0x1e1e1e) : color(0xffffff))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(img, in: frame)
    ctx.restoreGState()
    // Traffic lights
    let lights: [UInt32] = [0xff5f57, 0xfebc2e, 0x28c840]
    for (i, c) in lights.enumerated() {
        let d = 12 * scale
        let cx = frame.minX + (20 + CGFloat(i) * 20) * scale
        let cy = frame.maxY - 26 * scale
        ctx.setFillColor(color(c))
        ctx.fillEllipse(in: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
        ctx.setStrokeColor(color(0x000000, 0.12))
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
    }
    ctx.addPath(path)
    ctx.setStrokeColor(dark ? color(0xffffff, 0.14) : color(0x000000, 0.14))
    ctx.setLineWidth(1)
    ctx.strokePath()
    save(ctx, output)
}

func hero(_ iconPath: String, _ wheelPath: String, _ output: String) {
    let W: CGFloat = 2560, H: CGFloat = 1160
    let ctx = canvas(Int(W), Int(H))
    let bg = CGGradient(colorsSpace: sRGB, colors: [color(0xf7f7f9), color(0xe6e8ee)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
    // Soft accent glow behind the wheel
    let glow = CGGradient(colorsSpace: sRGB, colors: [color(0x0a73f5, 0.20), color(0x0a73f5, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W * 0.72, y: H * 0.5), startRadius: 0, endCenter: CGPoint(x: W * 0.72, y: H * 0.5), endRadius: 620, options: [])
    // Dotted grid, very faint
    ctx.setFillColor(color(0x000000, 0.045))
    var y: CGFloat = 30
    while y < H { var x: CGFloat = 30; while x < W { ctx.fillEllipse(in: CGRect(x: x, y: y, width: 3, height: 3)); x += 40 }; y += 40 }

    let icon = load(iconPath)
    ctx.draw(icon, in: CGRect(x: 170, y: H / 2 + 60, width: 240, height: 240))
    text("Forma", in: ctx, at: CGPoint(x: 176, y: H / 2 - 120), size: 168, weight: .bold, color: NSColor(white: 0.08, alpha: 1), kern: -4)
    text("Convert. Edit. Done.", in: ctx, at: CGPoint(x: 182, y: H / 2 - 200), size: 58, weight: .medium, color: NSColor(white: 0.32, alpha: 1))
    text("A radial conversion wheel for Finder — native, private, instant.", in: ctx, at: CGPoint(x: 184, y: H / 2 - 270), size: 36, weight: .regular, color: NSColor(white: 0.45, alpha: 1))

    let wheel = load(wheelPath)
    let side: CGFloat = 1000
    ctx.draw(wheel, in: CGRect(x: W * 0.72 - side / 2, y: H / 2 - side / 2, width: side, height: side))
    save(ctx, output)
}

func pair(_ light: String, _ dark: String, _ output: String) {
    let a = load(light), b = load(dark)
    let cell = CGFloat(max(a.width, b.width))
    let ctx = canvas(Int(cell * 2), Int(cell))
    ctx.setFillColor(color(0xeef0f4)); ctx.fill(CGRect(x: 0, y: 0, width: cell, height: cell))
    ctx.setFillColor(color(0x1c1c1f)); ctx.fill(CGRect(x: cell, y: 0, width: cell, height: cell))
    ctx.draw(a, in: CGRect(x: 0, y: 0, width: cell, height: cell))
    ctx.draw(b, in: CGRect(x: cell, y: 0, width: cell, height: cell))
    save(ctx, output)
}

func flow(_ paths: [String], _ output: String) {
    let imgs = paths.map(load)
    let cell = CGFloat(imgs.map(\.width).max()!)
    let gap: CGFloat = 120
    let W = cell * CGFloat(imgs.count) + gap * CGFloat(imgs.count - 1)
    let ctx = canvas(Int(W), Int(cell + 120))
    let labels = ["1  Hover to preview", "2  Click to convert", "3  Open · Edit · Reveal"]
    for (i, img) in imgs.enumerated() {
        let x = CGFloat(i) * (cell + gap)
        ctx.draw(img, in: CGRect(x: x, y: 120, width: cell, height: cell))
        text(labels[i], in: ctx, at: CGPoint(x: x + cell / 2 - 190, y: 40), size: 40, weight: .semibold, color: NSColor(white: 0.45, alpha: 1))
        if i < imgs.count - 1 {
            let ax = x + cell + gap * 0.2, ay = 120 + cell / 2
            ctx.setStrokeColor(color(0x8e8e93)); ctx.setLineWidth(6); ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: ax, y: ay)); ctx.addLine(to: CGPoint(x: ax + gap * 0.6, y: ay)); ctx.strokePath()
            ctx.move(to: CGPoint(x: ax + gap * 0.6 - 20, y: ay + 18)); ctx.addLine(to: CGPoint(x: ax + gap * 0.6, y: ay)); ctx.addLine(to: CGPoint(x: ax + gap * 0.6 - 20, y: ay - 18)); ctx.strokePath()
        }
    }
    save(ctx, output)
}

switch args.first {
case "samples": samples(args[1])
case "window": window(args[1], args[2], dark: args.contains("--dark"))
case "hero": hero(args[1], args[2], args[3])
case "pair": pair(args[1], args[2], args[3])
case "flow": flow(Array(args[1...3]), args[4])
default: print("usage: see header"); exit(2)
}
