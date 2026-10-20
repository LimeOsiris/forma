import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
@testable import FormaCore

/// Generates real test files on disk. Nothing is mocked: every fixture is a valid file
/// produced by system encoders, so conversions are exercised end to end.
enum Fixtures {
    static func tempDir(_ name: String = #function) throws -> URL {
        let safe = name.replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FormaTests-\(safe)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// RGBA image: left half opaque red, right half fully transparent.
    static func halfTransparentImage(width: Int = 64, height: Int = 32) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return ctx.makeImage()!
    }

    static func solidImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    @discardableResult
    static func writeImages(_ images: [CGImage], type: String, to url: URL, props: [CFString: Any] = [:], frameProps: [CFString: Any] = [:]) throws -> URL {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil)!
        if !props.isEmpty { CGImageDestinationSetProperties(dest, props as CFDictionary) }
        for img in images { CGImageDestinationAddImage(dest, img, frameProps as CFDictionary) }
        guard CGImageDestinationFinalize(dest) else { throw FormaError.encodeFailed(.png) }
        return url
    }

    static func png(in dir: URL, name: String = "sample.png") throws -> URL {
        try writeImages([halfTransparentImage()], type: "public.png", to: dir.appendingPathComponent(name), frameProps: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
    }

    /// A 40×20 JPEG tagged with EXIF orientation 6 (rotate 90° CW to display).
    static func rotatedJPEG(in dir: URL) throws -> URL {
        try writeImages([solidImage(width: 40, height: 20, red: 0, green: 0, blue: 1)], type: "public.jpeg",
                        to: dir.appendingPathComponent("rotated.jpg"), frameProps: [kCGImagePropertyOrientation: 6])
    }

    static func animatedGIF(in dir: URL, frames: Int = 3) throws -> URL {
        let imgs = (0..<frames).map { i in solidImage(width: 16, height: 16, red: CGFloat(i) / CGFloat(frames), green: 0.5, blue: 0) }
        return try writeImages(imgs, type: "com.compuserve.gif", to: dir.appendingPathComponent("anim.gif"),
                               props: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
                               frameProps: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]])
    }

    static func multipageTIFF(in dir: URL, pages: Int = 3) throws -> URL {
        let imgs = (0..<pages).map { _ in solidImage(width: 20, height: 30, red: 0, green: 1, blue: 0) }
        return try writeImages(imgs, type: "public.tiff", to: dir.appendingPathComponent("pages.tiff"))
    }

    static func svg(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("shape.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="60" viewBox="0 0 120 60">
          <rect x="0" y="0" width="60" height="60" fill="#00ff00"/>
          <circle cx="90" cy="30" r="25" fill="#0000ff"/>
        </svg>
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Multi-page PDF with a real text layer, drawn with Core Text.
    static func textPDF(in dir: URL, pages: [String], name: String = "doc.pdf", rotateFirstPage: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        if rotateFirstPage, let doc = PDFDocument(url: url) {
            doc.page(at: 0)?.rotation = 90
            doc.write(to: url)
        }
        return url
    }

    static func encryptedPDF(in dir: URL) throws -> URL {
        let plain = try textPDF(in: dir, pages: ["Secret"], name: "plain.pdf")
        let doc = PDFDocument(url: plain)!
        let url = dir.appendingPathComponent("locked.pdf")
        doc.write(to: url, withOptions: [.userPasswordOption: "hunter2", .ownerPasswordOption: "owner"])
        return url
    }

    static func docx(in dir: URL) throws -> URL {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "Quarterly Report\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 28)]))
        s.append(NSAttributedString(string: "Revenue grew ", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        s.append(NSAttributedString(string: "strongly", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        s.append(NSAttributedString(string: " this quarter.\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let data = try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let url = dir.appendingPathComponent("report.docx")
        try data.write(to: url)
        return url
    }

    static func markdown(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("notes.md")
        try """
        # Forma Notes

        Some **bold** and *italic* text with `code`.

        - First item
        - Second item

        | Format | Lossy |
        |--------|:-----:|
        | PNG    | No    |
        | JPEG   | Yes   |
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// One second of a 440 Hz sine wave as 16-bit stereo WAV.
    static func wav(in dir: URL, seconds: Double = 1) throws -> URL {
        let url = dir.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = Float(sin(2 * .pi * 440 * Double(i) / 44_100) * 0.5) }
        }
        try file.write(from: buffer)
        return url
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (data[0], data[1], data[2], data[3])
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    }

    static func frameCount(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(src)
    }

    static func signature(_ url: URL) -> FileFormat? { FileTypeDetector().sniff(url) }

    static var coordinator: ConversionCoordinator { ConversionCoordinator(registry: .standard(tools: .none)) }
}
