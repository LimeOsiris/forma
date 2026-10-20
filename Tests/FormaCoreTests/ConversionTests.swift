import AVFoundation
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import FormaCore

@Suite("Image conversion")
struct ImageConversionTests {
    let coordinator = Fixtures.coordinator

    @Test func pngToJPEGFlattensTransparencyOntoWhite() async throws {
        let dir = try Fixtures.tempDir()
        let src = try Fixtures.png(in: dir)
        let result = try await coordinator.convert(src, to: .jpeg, into: dir)
        let out = try #require(result.outputs.first)
        #expect(out.lastPathComponent == "sample.jpg")
        #expect(Fixtures.signature(out) == .jpeg)
        let img = try #require(Fixtures.loadImage(out))
        #expect(img.width == 64 && img.height == 32)
        let left = Fixtures.pixel(img, x: 8, y: 16), right = Fixtures.pixel(img, x: 56, y: 16)
        #expect(left.r > 200 && left.g < 60 && left.b < 60, "opaque red stays red")
        #expect(right.r > 240 && right.g > 240 && right.b > 240, "transparent area becomes white, not black")
        #expect(FileManager.default.fileExists(atPath: src.path), "original is untouched")
    }

    @Test(arguments: [FileFormat.heic, .tiff, .bmp, .gif, .avif])
    func pngToOtherRasterFormats(_ format: FileFormat) async throws {
        guard ImageConversionProvider.encodableOutputs().contains(format) else { return }
        let dir = try Fixtures.tempDir("png-\(format.rawValue)")
        let result = try await coordinator.convert(try Fixtures.png(in: dir), to: format, into: dir)
        let out = try #require(result.outputs.first)
        #expect(Fixtures.signature(out) == format || FileTypeDetector.compatible(Fixtures.signature(out) ?? .png, format))
        let img = try #require(Fixtures.loadImage(out))
        #expect(img.width == 64 && img.height == 32)
    }

    @Test func heicRoundTripBackToPNG() async throws {
        let dir = try Fixtures.tempDir()
        let heic = try await coordinator.convert(try Fixtures.png(in: dir), to: .heic, into: dir).outputs[0]
        let back = try await coordinator.convert(heic, to: .png, into: dir).outputs[0]
        #expect(back.lastPathComponent == "sample 2.png", "doesn't overwrite the original sample.png")
        #expect(Fixtures.signature(back) == .png)
        let img = try #require(Fixtures.loadImage(back))
        #expect(Fixtures.pixel(img, x: 8, y: 16).r > 200)
        #expect(Fixtures.pixel(img, x: 56, y: 16).a < 20, "HEIC keeps transparency")
    }

    @Test func jpegToPNGPreservesOrientationMetadataOnPassThrough() async throws {
        let dir = try Fixtures.tempDir()
        let out = try await coordinator.convert(try Fixtures.rotatedJPEG(in: dir), to: .png, into: dir).outputs[0]
        #expect(Fixtures.properties(out)[kCGImagePropertyOrientation] as? Int == 6)
    }

    @Test func resizingBakesOrientationIntoPixels() async throws {
        let dir = try Fixtures.tempDir()
        var options = ConversionOptions()
        options.maxPixelSize = 20
        let out = try await coordinator.convert(try Fixtures.rotatedJPEG(in: dir), to: .png, options: options, into: dir).outputs[0]
        let img = try #require(Fixtures.loadImage(out))
        #expect(img.width == 10 && img.height == 20, "40×20 rotated 90° and scaled to 20px long edge")
        #expect((Fixtures.properties(out)[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func jpegQualityAffectsSize() async throws {
        let dir = try Fixtures.tempDir()
        let noisy = dir.appendingPathComponent("noise.png")
        var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        let ctx = CGContext(data: &bytes, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        try Fixtures.writeImages([ctx.makeImage()!], type: "public.png", to: noisy)
        var low = ConversionOptions(); low.quality = 0.2
        var high = ConversionOptions(); high.quality = 0.95
        let a = try await coordinator.convert(noisy, to: .jpeg, options: low, into: dir, baseName: "low").outputs[0]
        let b = try await coordinator.convert(noisy, to: .jpeg, options: high, into: dir, baseName: "high").outputs[0]
        let sa = try a.resourceValues(forKeys: [.fileSizeKey]).fileSize!, sb = try b.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        #expect(sa < sb)
    }

    @Test func pngToPDFUsesImageResolutionForPageSize() async throws {
        let dir = try Fixtures.tempDir()
        let result = try await coordinator.convert(try Fixtures.png(in: dir), to: .pdf, into: dir)
        #expect(result.editability == .rasterized)
        let doc = try #require(PDFDocument(url: result.outputs[0]))
        #expect(doc.pageCount == 1)
        let box = try #require(doc.page(at: 0)?.bounds(for: .mediaBox))
        #expect(abs(box.width - 32) < 0.5 && abs(box.height - 16) < 0.5, "64×32 px at 144 dpi = 32×16 pt")
    }

    @Test func animatedGIFKeepsFramesInGIFAndTIFF() async throws {
        let dir = try Fixtures.tempDir()
        let gif = try Fixtures.animatedGIF(in: dir)
        let tiff = try await coordinator.convert(gif, to: .tiff, into: dir).outputs[0]
        #expect(Fixtures.frameCount(tiff) == 3)
        let png = try await coordinator.convert(gif, to: .png, into: dir)
        #expect(Fixtures.frameCount(png.outputs[0]) == 1)
        #expect(png.caveats.contains { $0.message.contains("first of 3") })
    }

    @Test func multipageTIFFToPNGWritesOneFilePerPage() async throws {
        let dir = try Fixtures.tempDir()
        let result = try await coordinator.convert(try Fixtures.multipageTIFF(in: dir), to: .png, into: dir)
        #expect(result.outputs.count == 3)
        #expect(result.containerFolder?.lastPathComponent == "pages (PNG)")
        #expect(result.outputs.allSatisfy { Fixtures.signature($0) == .png })
        let pdf = try await coordinator.convert(try Fixtures.multipageTIFF(in: dir), to: .pdf, into: dir)
        #expect(PDFDocument(url: pdf.outputs[0])?.pageCount == 3)
    }

    @Test func svgRasterizesAndStaysVectorInPDF() async throws {
        let dir = try Fixtures.tempDir()
        let svg = try Fixtures.svg(in: dir)
        let png = try await coordinator.convert(svg, to: .png, into: dir).outputs[0]
        let img = try #require(Fixtures.loadImage(png))
        #expect(img.width == 1024 && img.height == 512)
        let green = Fixtures.pixel(img, x: 100, y: 256)
        #expect(green.g > 200 && green.r < 50)
        let pdf = try await coordinator.convert(svg, to: .pdf, into: dir).outputs[0]
        let box = try #require(PDFDocument(url: pdf)?.page(at: 0)?.bounds(for: .mediaBox))
        #expect(box.width == 120 && box.height == 60)
    }

    @Test func corruptedImageFailsWithReadableError() async throws {
        let dir = try Fixtures.tempDir()
        let bad = dir.appendingPathComponent("broken.png")
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(Data(repeating: 0xAB, count: 64))
        try data.write(to: bad)
        await #expect(throws: FormaError.self) { try await coordinator.convert(bad, to: .jpeg, into: dir) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "broken.png" }
        #expect(leftovers.isEmpty, "no partial output left behind")
    }
}

@Suite("PDF conversion")
struct PDFConversionTests {
    let coordinator = Fixtures.coordinator

    @Test func pdfToPNGRendersEachPage() async throws {
        let dir = try Fixtures.tempDir()
        let pdf = try Fixtures.textPDF(in: dir, pages: ["One", "Two", "Three"])
        var options = ConversionOptions(); options.pdfRenderDPI = 72
        let result = try await coordinator.convert(pdf, to: .png, options: options, into: dir)
        #expect(result.outputs.count == 3)
        #expect(result.outputs.map(\.lastPathComponent) == ["doc page 1.png", "doc page 2.png", "doc page 3.png"])
        let img = try #require(Fixtures.loadImage(result.outputs[0]))
        #expect(img.width == 612 && img.height == 792)
        #expect(Fixtures.pixel(img, x: 5, y: 5).r == 255, "white page background")
    }

    @Test func pdfToJPEGAtHigherDPI() async throws {
        let dir = try Fixtures.tempDir()
        let pdf = try Fixtures.textPDF(in: dir, pages: ["Solo"])
        let result = try await coordinator.convert(pdf, to: .jpeg, into: dir)
        #expect(result.outputs.count == 1)
        #expect(result.outputs[0].lastPathComponent == "doc.jpg")
        let img = try #require(Fixtures.loadImage(result.outputs[0]))
        #expect(img.width == 1275 && img.height == 1650, "150 dpi default")
    }

    @Test func rotatedPagesRenderUpright() async throws {
        let dir = try Fixtures.tempDir()
        let pdf = try Fixtures.textPDF(in: dir, pages: ["Turned"], rotateFirstPage: true)
        var options = ConversionOptions(); options.pdfRenderDPI = 72
        let img = try #require(Fixtures.loadImage(try await coordinator.convert(pdf, to: .png, options: options, into: dir).outputs[0]))
        #expect(img.width == 792 && img.height == 612)
    }

    @Test func pdfToTextExtractsTextLayer() async throws {
        let dir = try Fixtures.tempDir()
        let pdf = try Fixtures.textPDF(in: dir, pages: ["Hello Forma", "Second page"])
        let out = try await coordinator.convert(pdf, to: .txt, into: dir).outputs[0]
        let text = try String(contentsOf: out, encoding: .utf8)
        #expect(text.contains("Hello Forma") && text.contains("Second page"))
    }

    @Test func scannedPDFFallsBackToOCR() async throws {
        let dir = try Fixtures.tempDir()
        // Rasterize a text PDF, then wrap the picture in a PDF: no text layer remains.
        let textPDF = try Fixtures.textPDF(in: dir, pages: ["INVOICE 2048"], name: "source.pdf")
        var opts = ConversionOptions(); opts.pdfRenderDPI = 200
        let png = try await coordinator.convert(textPDF, to: .png, options: opts, into: dir).outputs[0]
        let scanned = try await coordinator.convert(png, to: .pdf, into: dir, baseName: "scanned").outputs[0]
        #expect(PDFDocument(url: scanned)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let result = try await coordinator.convert(scanned, to: .txt, into: dir)
        let text = try String(contentsOf: result.outputs[0], encoding: .utf8)
        #expect(text.uppercased().contains("INVOICE"))
        #expect(result.caveats.contains { $0.message.contains("recognized") })
    }

    @Test func passwordProtectedPDFIsReportedClearly() async throws {
        let dir = try Fixtures.tempDir()
        let locked = try Fixtures.encryptedPDF(in: dir)
        await #expect(throws: FormaError.passwordProtected("locked.pdf")) {
            try await coordinator.convert(locked, to: .png, into: dir)
        }
        #expect(FormaError.passwordProtected("locked.pdf").localizedDescription == "Couldn't convert “locked.pdf” because it is password protected.")
    }

    @Test func mergeAndSplit() throws {
        let dir = try Fixtures.tempDir()
        let a = try Fixtures.textPDF(in: dir, pages: ["A1", "A2"], name: "a.pdf")
        let b = try Fixtures.textPDF(in: dir, pages: ["B1"], name: "b.pdf")
        let merged = dir.appendingPathComponent("merged.pdf")
        try PDFOperations.merge([a, b], to: merged)
        let doc = try #require(PDFDocument(url: merged))
        #expect(doc.pageCount == 3)
        #expect(doc.page(at: 2)?.string?.contains("B1") == true)
        let parts = try PDFOperations.split(merged, into: dir, baseName: "merged")
        #expect(parts.count == 3)
        #expect(PDFDocument(url: parts[1])?.string?.contains("A2") == true)
    }

    @Test func cancellationLeavesNoOutput() async throws {
        let dir = try Fixtures.tempDir()
        let pdf = try Fixtures.textPDF(in: dir, pages: (1...60).map { "Page \($0)" })
        let task = Task { try await coordinator.convert(pdf, to: .png, options: { var o = ConversionOptions(); o.pdfRenderDPI = 300; return o }(), into: dir) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: FormaError.cancelled) { try await task.value }
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == ["doc.pdf"], "nothing but the source remains: \(contents)")
    }
}

@Suite("Document conversion")
struct DocumentConversionTests {
    let coordinator = Fixtures.coordinator

    @Test func markdownToHTMLIsStandaloneAndStructured() async throws {
        let dir = try Fixtures.tempDir()
        let out = try await coordinator.convert(try Fixtures.markdown(in: dir), to: .html, into: dir).outputs[0]
        let html = try String(contentsOf: out, encoding: .utf8)
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<h1 id=\"forma-notes\">Forma Notes</h1>"))
        #expect(html.contains("<strong>bold</strong>") && html.contains("<em>italic</em>"))
        #expect(html.contains("<table>") && html.contains("<th style=\"text-align: center\">Lossy</th>"))
    }

    @Test func markdownToPDFHasTextLayer() async throws {
        let dir = try Fixtures.tempDir()
        let result = try await coordinator.convert(try Fixtures.markdown(in: dir), to: .pdf, into: dir)
        #expect(result.editability == .annotationOnly)
        let doc = try #require(PDFDocument(url: result.outputs[0]))
        #expect(doc.pageCount >= 1)
        let text = doc.string ?? ""
        #expect(text.contains("Forma Notes") && text.contains("Second item") && text.contains("JPEG"))
    }

    @Test func plainTextToPDFPaginates() async throws {
        let dir = try Fixtures.tempDir()
        let txt = dir.appendingPathComponent("long.txt")
        try (1...400).map { "Line number \($0)" }.joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
        let doc = try #require(PDFDocument(url: try await coordinator.convert(txt, to: .pdf, into: dir).outputs[0]))
        #expect(doc.pageCount > 3)
        #expect(doc.page(at: 0)?.string?.contains("Line number 1") == true)
        #expect(doc.string?.contains("Line number 400") == true)
    }

    @Test func docxToPDFTextAndMarkdown() async throws {
        let dir = try Fixtures.tempDir()
        let docx = try Fixtures.docx(in: dir)
        let pdf = try #require(PDFDocument(url: try await coordinator.convert(docx, to: .pdf, into: dir).outputs[0]))
        #expect(pdf.string?.contains("Quarterly Report") == true)
        let txt = try String(contentsOf: try await coordinator.convert(docx, to: .txt, into: dir).outputs[0], encoding: .utf8)
        #expect(txt.contains("Revenue grew strongly this quarter."))
        let md = try String(contentsOf: try await coordinator.convert(docx, to: .markdown, into: dir).outputs[0], encoding: .utf8)
        #expect(md.contains("# Quarterly Report"))
        #expect(md.contains("**strongly**"))
        let html = try String(contentsOf: try await coordinator.convert(docx, to: .html, into: dir).outputs[0], encoding: .utf8)
        #expect(html.lowercased().contains("<html") && html.contains("Quarterly Report"))
        #expect(!html.lowercased().contains("<script"))
    }

    @Test func richTextRoundTripsThroughWordAndODT() async throws {
        let dir = try Fixtures.tempDir()
        let md = try Fixtures.markdown(in: dir)
        let rtf = try await coordinator.convert(md, to: .rtf, into: dir).outputs[0]
        #expect(Fixtures.signature(rtf) == .rtf)
        let docx = try await coordinator.convert(rtf, to: .docx, into: dir).outputs[0]
        #expect(Fixtures.signature(docx) == .docx)
        let odt = try await coordinator.convert(docx, to: .odt, into: dir).outputs[0]
        #expect(Fixtures.signature(odt) == .odt)
        let back = try String(contentsOf: try await coordinator.convert(odt, to: .txt, into: dir).outputs[0], encoding: .utf8)
        #expect(back.contains("Forma Notes") && back.contains("First item"))
    }

    @Test func htmlToPDF() async throws {
        let dir = try Fixtures.tempDir()
        let html = dir.appendingPathComponent("page.html")
        try "<!doctype html><html><body><h1>Hello HTML</h1><p>Paragraph <b>bold</b>.</p><script>alert(1)</script></body></html>"
            .write(to: html, atomically: true, encoding: .utf8)
        let doc = try #require(PDFDocument(url: try await coordinator.convert(html, to: .pdf, into: dir).outputs[0]))
        #expect(doc.string?.contains("Hello HTML") == true)
        #expect(doc.string?.contains("alert") != true)
    }
}

@Suite("Audio conversion")
struct AudioConversionTests {
    let coordinator = Fixtures.coordinator

    func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    @Test(arguments: [FileFormat.m4a, .aiff, .caf, .flac])
    func wavTranscodes(_ format: FileFormat) async throws {
        guard ConversionRegistry.standard(tools: .none).canConvert(.wav, to: format) else { return }
        let dir = try Fixtures.tempDir("wav-\(format.rawValue)")
        let out = try await coordinator.convert(try Fixtures.wav(in: dir), to: format, into: dir).outputs[0]
        #expect(Fixtures.signature(out) == format)
        #expect(abs(try await duration(out) - 1.0) < 0.1)
    }

    @Test func m4aBackToWAV() async throws {
        let dir = try Fixtures.tempDir()
        let m4a = try await coordinator.convert(try Fixtures.wav(in: dir), to: .m4a, into: dir).outputs[0]
        let wav = try await coordinator.convert(m4a, to: .wav, into: dir).outputs[0]
        #expect(wav.lastPathComponent == "tone 2.wav")
        #expect(Fixtures.signature(wav) == .wav)
        let file = try AVAudioFile(forReading: wav)
        #expect(file.fileFormat.channelCount == 2)
        #expect(file.length > 40_000)
    }
}

@Suite("Batch conversion")
struct BatchTests {
    let batch = BatchCoordinator(coordinator: Fixtures.coordinator)

    @Test func convertsCompatibleFilesAndSkipsTheRest() async throws {
        let dir = try Fixtures.tempDir()
        let a = try Fixtures.png(in: dir, name: "a.png")
        let b = try Fixtures.png(in: dir, name: "b.png")
        let md = try Fixtures.markdown(in: dir)
        let jpg = try Fixtures.rotatedJPEG(in: dir)
        let plan = batch.plan([a, b, md, jpg, a], mode: .each(.jpeg))
        #expect(plan.items.count == 2, "duplicates removed, markdown and existing JPEG skipped")
        #expect(plan.skipped.count == 2)
        let report = await batch.run(plan, options: .init(), policy: .besideOriginal) { _, _ in }
        #expect(report.results.count == 2)
        #expect(report.results.flatMap(\.outputs).allSatisfy { Fixtures.signature($0) == .jpeg })
        #expect(report.summary.contains("2 files converted") && report.summary.contains("2 skipped"))
    }

    @Test func combinesImagesIntoOnePDF() async throws {
        let dir = try Fixtures.tempDir()
        let files = try (1...4).map { try Fixtures.png(in: dir, name: "img\($0).png") } + [try Fixtures.textPDF(in: dir, pages: ["x", "y"])]
        let plan = batch.plan(files, mode: .combinePDF)
        let report = await batch.run(plan, options: .init(), policy: .besideOriginal) { _, _ in }
        let out = try #require(report.results.first?.outputs.first)
        #expect(out.lastPathComponent == "Combined.pdf")
        #expect(PDFDocument(url: out)?.pageCount == 6)
    }

    @Test func mergesPDFs() async throws {
        let dir = try Fixtures.tempDir()
        let a = try Fixtures.textPDF(in: dir, pages: ["1"], name: "a.pdf")
        let b = try Fixtures.textPDF(in: dir, pages: ["2", "3"], name: "b.pdf")
        let report = await batch.run(batch.plan([a, b], mode: .combinePDF), options: .init(), policy: .besideOriginal) { _, _ in }
        #expect(report.results.first?.outputs.first?.lastPathComponent == "Merged.pdf")
        #expect(PDFDocument(url: report.results[0].outputs[0])?.pageCount == 3)
    }

    @Test func cancellationStopsTheBatch() async throws {
        let dir = try Fixtures.tempDir()
        let files = try (1...30).map { try Fixtures.png(in: dir, name: "p\($0).png") }
        let plan = batch.plan(files, mode: .each(.tiff))
        let task = Task { await batch.run(plan, options: .init(), policy: .besideOriginal) { _, _ in } }
        task.cancel()
        let report = await task.value
        #expect(report.cancelled)
        #expect(report.results.count < 30)
    }
}
