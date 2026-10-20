import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Raster and vector image conversion using ImageIO and Core Graphics.
///
/// - Pass-through paths use `CGImageDestinationAddImageFromSource`, which keeps EXIF/GPS
///   metadata, orientation and the embedded colour profile untouched.
/// - Paths that must re-render pixels (resize, transparency flattening, PDF) bake the
///   EXIF orientation into the pixels and reset the orientation tag to 1.
public struct ImageConversionProvider: ConversionProvider {
    public let id = "image"
    public init() {}

    static let rasterInputs: [FileFormat] = [.png, .jpeg, .heic, .avif, .webp, .tiff, .bmp, .gif]
    static let rasterOutputs: [FileFormat] = [.png, .jpeg, .heic, .avif, .tiff, .bmp, .gif]
    /// Hard ceiling to protect memory; users can set a max size to go beyond it.
    static let maxPixels = 400_000_000

    public func capabilities(tools: ToolAvailability) -> [ConversionCapability] {
        let encodable = Set(Self.encodableOutputs())
        var caps: [ConversionCapability] = []
        for input in Self.rasterInputs + [.svg] {
            for output in Self.rasterOutputs where output != input && encodable.contains(output) {
                caps.append(ConversionCapability(
                    input: input, output: output, providerID: id,
                    isLossless: !output.isLossyByNature && input != .svg && output != .gif,
                    preservesMetadata: input != .svg,
                    preservesTransparency: output.supportsTransparency,
                    editability: .full,
                    priority: 10,
                    notes: input == .svg ? [.info("Vector artwork will be rasterized.")] : []
                ))
            }
            caps.append(ConversionCapability(
                input: input, output: .pdf, providerID: id,
                isLossless: input != .svg ? !input.isLossyByNature : true,
                preservesMetadata: false,
                preservesTransparency: true,
                editability: input == .svg ? .annotationOnly : .rasterized,
                priority: 10,
                notes: input == .svg ? [.info("Vector artwork stays sharp at any zoom.")] : [.info("The PDF contains the picture; it isn't an editable text document.")]
            ))
        }
        return caps
    }

    /// Asks ImageIO which encoders this Mac actually has (HEIC/AVIF depend on hardware and OS).
    public static func encodableOutputs() -> [FileFormat] {
        let ids = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return rasterOutputs.filter { $0.imageIOIdentifier.map(ids.contains) ?? false }
    }

    public func caveats(for facts: FileFacts, to output: FileFormat, options: ConversionOptions) -> [Caveat] {
        var result: [Caveat] = []
        if facts.hasAlpha && !output.supportsTransparency && facts.format != .svg {
            result.append(.warning("Transparent areas will become \(options.flattenBackgroundWhite ? "white" : "black")."))
        }
        if facts.isAnimated && output != .gif {
            if output == .tiff || output == .pdf {
                result.append(.info("Each of the \(facts.frameCount) animation frames becomes a page; timing is not kept."))
            } else if !options.acceptFirstFrameOnly {
                result.append(.confirm("Only the first of \(facts.frameCount) animation frames will be kept."))
            }
        } else if facts.frameCount > 1 && !output.supportsMultipleFrames {
            result.append(.info("Each of the \(facts.frameCount) pages will be saved as a separate file."))
        }
        if output.isLossyByNature && !facts.format.isLossyByNature {
            result.append(.info("Lossy compression at \(Int(options.quality * 100))% quality."))
        }
        if output == .gif && facts.format != .gif {
            result.append(.info("GIF is limited to 256 colours."))
        }
        return result
    }

    public func convert(_ job: ConversionJob, progress: ProgressHandler) async throws -> ProviderResult {
        try Task.checkCancellation()
        if job.inputFormat == .svg {
            return try convertSVG(job)
        }
        guard let source = CGImageSourceCreateWithURL(job.input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete || CGImageSourceGetCount(source) > 0,
              CGImageSourceGetCount(source) > 0 else {
            throw FormaError.corrupted(job.input.lastPathComponent)
        }
        let count = CGImageSourceGetCount(source)
        let props0 = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = props0[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props0[kCGImagePropertyPixelHeight] as? Int ?? 0
        if w * h > Self.maxPixels && job.options.maxPixelSize == nil {
            throw FormaError.imageTooLarge(width: w, height: h)
        }
        let isAnimated = job.inputFormat == .gif && count > 1

        if job.output == .pdf {
            let url = job.defaultOutputURL
            try writePDF(source: source, frames: Array(0..<count), to: url, options: job.options, progress: progress)
            return ProviderResult(files: [url])
        }

        if count > 1 && job.output.supportsMultipleFrames {
            // GIF → GIF or GIF/TIFF → multi-page TIFF: keep every frame in one file.
            let url = job.defaultOutputURL
            try writeImage(source: source, frames: Array(0..<count), format: job.output, to: url, options: job.options, progress: progress)
            return ProviderResult(files: [url])
        }

        if count > 1 && !isAnimated {
            // Multi-page TIFF → single-frame format: one file per page.
            var files: [URL] = []
            let digits = String(count).count
            for i in 0..<count {
                try Task.checkCancellation()
                let name = "\(job.baseName) page \(String(format: "%0\(digits)d", i + 1))"
                let url = job.workDirectory.appendingPathComponent(name).appendingPathExtension(job.output.preferredExtension)
                try writeImage(source: source, frames: [i], format: job.output, to: url, options: job.options, progress: { _ in })
                files.append(url)
                progress(Double(i + 1) / Double(count))
            }
            return ProviderResult(files: files)
        }

        let url = job.defaultOutputURL
        try writeImage(source: source, frames: [0], format: job.output, to: url, options: job.options, progress: progress)
        var caveats: [Caveat] = []
        if isAnimated { caveats.append(.info("Kept the first of \(count) animation frames.")) }
        return ProviderResult(files: [url], caveats: caveats)
    }

    // MARK: - Raster writing

    func writeImage(source: CGImageSource, frames: [Int], format: FileFormat, to url: URL, options: ConversionOptions, progress: ProgressHandler) throws {
        guard let typeID = format.imageIOIdentifier,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, typeID as CFString, frames.count, nil) else {
            throw FormaError.encodeFailed(format)
        }
        var fileProps: [CFString: Any] = [:]
        if format == .gif, let srcProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
           let gif = srcProps[kCGImagePropertyGIFDictionary] {
            fileProps[kCGImagePropertyGIFDictionary] = gif // keeps loop count
        }
        if !fileProps.isEmpty { CGImageDestinationSetProperties(dest, fileProps as CFDictionary) }

        for (n, index) in frames.enumerated() {
            try Task.checkCancellation()
            let srcProps = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let hasAlpha = srcProps[kCGImagePropertyHasAlpha] as? Bool ?? false
            let needsFlatten = hasAlpha && !format.supportsTransparency
            var frameProps = srcProps
            frameProps.removeValue(forKey: kCGImagePropertyPixelWidth)
            frameProps.removeValue(forKey: kCGImagePropertyPixelHeight)
            if format.isLossyByNature {
                frameProps[kCGImageDestinationLossyCompressionQuality] = options.quality
            }
            if options.maxPixelSize != nil || needsFlatten {
                guard var image = Self.orientedImage(source, index: index, maxPixelSize: options.maxPixelSize) else {
                    throw FormaError.corrupted(url.lastPathComponent)
                }
                if needsFlatten { image = try Self.flatten(image, white: options.flattenBackgroundWhite) }
                frameProps[kCGImagePropertyOrientation] = 1
                if var tiff = frameProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFOrientation] = 1
                    frameProps[kCGImagePropertyTIFFDictionary] = tiff
                }
                CGImageDestinationAddImage(dest, image, frameProps as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(dest, source, index, frameProps as CFDictionary)
            }
            progress(Double(n + 1) / Double(frames.count) * 0.9)
        }
        guard CGImageDestinationFinalize(dest) else { throw FormaError.encodeFailed(format) }
        progress(1)
    }

    /// Decodes a frame with EXIF orientation applied, optionally downscaled.
    public static func orientedImage(_ source: CGImageSource, index: Int, maxPixelSize: Int?) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(w, h)
        let target = min(maxPixelSize ?? longest, longest)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, target),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, opts as CFDictionary)
    }

    static func flatten(_ image: CGImage, white: Bool) throws -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw FormaError.encodeFailed(.jpeg)
        }
        ctx.setFillColor(white ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = ctx.makeImage() else { throw FormaError.encodeFailed(.jpeg) }
        return out
    }

    // MARK: - PDF

    func writePDF(source: CGImageSource, frames: [Int], to url: URL, options: ConversionOptions, progress: ProgressHandler) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { throw FormaError.encodeFailed(.pdf) }
        for (n, index) in frames.enumerated() {
            try Task.checkCancellation()
            guard let image = Self.orientedImage(source, index: index, maxPixelSize: options.maxPixelSize) else {
                throw FormaError.corrupted(url.lastPathComponent)
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let dpi = Self.resolution(props)
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
            ctx.beginPage(mediaBox: &box)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: box)
            ctx.endPage()
            progress(Double(n + 1) / Double(frames.count))
        }
        ctx.closePDF()
    }

    /// Image DPI from metadata; screenshots and web images usually report 72 or 144.
    static func resolution(_ props: [CFString: Any]) -> CGFloat {
        let dpi = (props[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return CGFloat(min(max(dpi, 36), 1200))
    }

    // MARK: - SVG

    func convertSVG(_ job: ConversionJob) throws -> ProviderResult {
        let image = try Self.loadSVG(job.input)
        let size = image.size
        guard size.width > 0, size.height > 0 else { throw FormaError.corrupted(job.input.lastPathComponent) }
        let url = job.defaultOutputURL
        if job.output == .pdf {
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw FormaError.encodeFailed(.pdf) }
            ctx.beginPage(mediaBox: &box)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            image.draw(in: box)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPage()
            ctx.closePDF()
            return ProviderResult(files: [url])
        }
        let longest = max(size.width, size.height)
        let target = CGFloat(job.options.maxPixelSize ?? Int(min(max(longest * 2, 1024), 8192)))
        let scale = target / longest
        let pw = max(1, Int((size.width * scale).rounded())), ph = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FormaError.encodeFailed(job.output)
        }
        if !job.output.supportsTransparency {
            ctx.setFillColor(CGColor(gray: job.options.flattenBackgroundWhite ? 1 : 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: pw, height: ph))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage(),
              let typeID = job.output.imageIOIdentifier,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, typeID as CFString, 1, nil) else {
            throw FormaError.encodeFailed(job.output)
        }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        if job.output.isLossyByNature { props[kCGImageDestinationLossyCompressionQuality] = job.options.quality }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FormaError.encodeFailed(job.output) }
        return ProviderResult(files: [url])
    }

    static func loadSVG(_ url: URL) throws -> NSImage {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data), image.isValid else {
            throw FormaError.corrupted(url.lastPathComponent)
        }
        return image
    }
}
