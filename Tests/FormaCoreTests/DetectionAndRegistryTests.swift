import Foundation
import Testing
@testable import FormaCore

@Suite("File type detection")
struct DetectionTests {
    let detector = FileTypeDetector()

    @Test func detectsCommonSignatures() throws {
        let dir = try Fixtures.tempDir()
        #expect(detector.format(of: try Fixtures.png(in: dir)) == .png)
        #expect(detector.format(of: try Fixtures.rotatedJPEG(in: dir)) == .jpeg)
        #expect(detector.format(of: try Fixtures.animatedGIF(in: dir)) == .gif)
        #expect(detector.format(of: try Fixtures.multipageTIFF(in: dir)) == .tiff)
        #expect(detector.format(of: try Fixtures.textPDF(in: dir, pages: ["Hi"])) == .pdf)
        #expect(detector.format(of: try Fixtures.svg(in: dir)) == .svg)
        #expect(detector.format(of: try Fixtures.docx(in: dir)) == .docx)
        #expect(detector.format(of: try Fixtures.markdown(in: dir)) == .markdown)
        #expect(detector.format(of: try Fixtures.wav(in: dir, seconds: 0.1)) == .wav)
    }

    @Test func contentWinsOverMisleadingExtension() throws {
        let dir = try Fixtures.tempDir()
        let jpg = try Fixtures.rotatedJPEG(in: dir)
        let lying = dir.appendingPathComponent("actually-jpeg.png")
        try FileManager.default.copyItem(at: jpg, to: lying)
        let d = try #require(detector.detect(lying))
        #expect(d.format == .jpeg)
        #expect(d.extensionMismatch)
    }

    @Test func textRenamedAsPDFIsNotTreatedAsPDF() throws {
        let dir = try Fixtures.tempDir()
        let fake = dir.appendingPathComponent("fake.pdf")
        try "hello, not a pdf".write(to: fake, atomically: true, encoding: .utf8)
        #expect(detector.format(of: fake) != .pdf)
    }

    @Test func emptyBinaryExtensionIsRejected() throws {
        let dir = try Fixtures.tempDir()
        let empty = dir.appendingPathComponent("empty.png")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        #expect(detector.format(of: empty) == nil)
    }

    @Test func screenshotNamesAreRecognised() {
        #expect(FileInspector.isScreenshot(URL(fileURLWithPath: "/tmp/Screenshot 2026-10-20 at 10.00.00.png")))
        #expect(!FileInspector.isScreenshot(URL(fileURLWithPath: "/tmp/holiday.png")))
    }

    @Test func factsReportAlphaFramesAndPages() throws {
        let dir = try Fixtures.tempDir()
        let png = FileInspector().facts(for: try Fixtures.png(in: dir), format: .png)
        #expect(png.hasAlpha)
        #expect(png.pixelWidth == 64)
        let gif = FileInspector().facts(for: try Fixtures.animatedGIF(in: dir), format: .gif)
        #expect(gif.isAnimated && gif.frameCount == 3)
        let pdf = FileInspector().facts(for: try Fixtures.textPDF(in: dir, pages: ["a", "b"]), format: .pdf)
        #expect(pdf.pageCount == 2)
        let locked = FileInspector().facts(for: try Fixtures.encryptedPDF(in: dir), format: .pdf)
        #expect(locked.isEncrypted)
    }
}

@Suite("Conversion registry")
struct RegistryTests {
    @Test func offersCoreImageAndDocumentPaths() {
        let r = ConversionRegistry.standard(tools: .none)
        for (i, o) in [(FileFormat.png, FileFormat.jpeg), (.jpeg, .png), (.png, .heic), (.heic, .png), (.jpeg, .pdf), (.png, .pdf),
                       (.pdf, .png), (.pdf, .jpeg), (.txt, .pdf), (.markdown, .html), (.markdown, .pdf), (.docx, .pdf),
                       (.docx, .txt), (.docx, .html), (.rtf, .pdf), (.html, .pdf), (.pdf, .txt), (.wav, .m4a), (.svg, .png)] {
            #expect(r.canConvert(i, to: o), "\(i) → \(o) should be supported")
        }
    }

    @Test func neverOffersIdentityOrFakeConversions() {
        let r = ConversionRegistry.standard(tools: .none)
        for f in FileFormat.allCases { #expect(!r.canConvert(f, to: f)) }
        // macOS can't encode WebP or MP3; without the optional tools these must not appear.
        #expect(!r.canConvert(.png, to: .webp))
        #expect(!r.canConvert(.wav, to: .mp3))
        #expect(!r.canConvert(.png, to: .docx))
    }

    @Test func externalToolsUnlockPathsAndTakePriority() {
        let fake = URL(fileURLWithPath: "/usr/bin/true")
        let r = ConversionRegistry.standard(tools: ToolAvailability(paths: [.cwebp: fake, .ffmpeg: fake, .libreOffice: fake]))
        #expect(r.canConvert(.png, to: .webp))
        #expect(r.canConvert(.wav, to: .mp3))
        #expect(r.capability(from: .docx, to: .pdf)?.providerID == "libreoffice")
        #expect(ConversionRegistry.standard(tools: .none).capability(from: .docx, to: .pdf)?.providerID == "document")
    }

    @Test func capabilitiesDescribeEditabilityHonestly() {
        let r = ConversionRegistry.standard(tools: .none)
        #expect(r.capability(from: .png, to: .pdf)?.editability == .rasterized)
        #expect(r.capability(from: .docx, to: .pdf)?.editability == .annotationOnly)
        #expect(r.capability(from: .pdf, to: .png)?.editability == .rasterized)
        #expect(r.capability(from: .markdown, to: .txt)?.editability == .full)
        #expect(r.capability(from: .docx, to: .rtf)?.editability == .limited)
    }

    @Test func caveatsWarnBeforeLosingTransparencyOrAnimation() throws {
        let dir = try Fixtures.tempDir()
        let r = ConversionRegistry.standard(tools: .none)
        let png = FileInspector().facts(for: try Fixtures.png(in: dir), format: .png)
        #expect(r.caveats(for: png, to: .jpeg, options: .init()).contains { $0.message.contains("Transparent") })
        #expect(!r.caveats(for: png, to: .heic, options: .init()).contains { $0.message.contains("Transparent") })
        let gif = FileInspector().facts(for: try Fixtures.animatedGIF(in: dir), format: .gif)
        #expect(r.caveats(for: gif, to: .png, options: .init()).contains { $0.severity == .requiresConfirmation })
    }

    @Test func multiFileDestinations() {
        let r = ConversionRegistry.standard(tools: .none)
        let common = r.commonDestinations(for: [.png, .jpeg])
        #expect(common.contains(.pdf) && common.contains(.tiff))
        #expect(!r.commonDestinations(for: [.png, .docx]).contains(.jpeg))
        #expect(r.anyDestinations(for: [.png, .docx]).contains(.jpeg))
    }
}
