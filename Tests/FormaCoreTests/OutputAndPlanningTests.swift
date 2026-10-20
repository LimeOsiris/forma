import Foundation
import Testing
@testable import FormaCore

@Suite("Output naming and placement")
struct OutputTests {
    @Test func uniqueNamesNeverCollide() throws {
        let dir = try Fixtures.tempDir()
        let first = OutputLocator.uniqueURL(in: dir, baseName: "report", pathExtension: "pdf")
        #expect(first.lastPathComponent == "report.pdf")
        FileManager.default.createFile(atPath: first.path, contents: Data("x".utf8))
        let second = OutputLocator.uniqueURL(in: dir, baseName: "report", pathExtension: "pdf")
        #expect(second.lastPathComponent == "report 2.pdf")
        FileManager.default.createFile(atPath: second.path, contents: Data("x".utf8))
        #expect(OutputLocator.uniqueURL(in: dir, baseName: "report", pathExtension: "pdf").lastPathComponent == "report 3.pdf")
    }

    @Test func sanitizePreventsTraversalAndHiddenFiles() {
        #expect(OutputLocator.sanitize("../../etc/passwd") == "-..-etc-passwd")
        #expect(!OutputLocator.sanitize("../x").contains("/"))
        #expect(OutputLocator.sanitize(".hidden") == "hidden")
        #expect(OutputLocator.sanitize("") == "Converted")
        #expect(OutputLocator.sanitize("a\u{0}b\nc") == "abc")
        #expect(OutputLocator.sanitize(String(repeating: "é", count: 300)).utf8.count <= 200)
    }

    @Test func finalizeDoesNotOverwriteExistingFiles() throws {
        let dir = try Fixtures.tempDir()
        let existing = dir.appendingPathComponent("photo.jpg")
        try Data("original".utf8).write(to: existing)
        let work = try OutputLocator.makeWorkDirectory(near: dir)
        let produced = work.appendingPathComponent("photo.jpg")
        try Data("new".utf8).write(to: produced)
        let placed = try OutputLocator().finalize([produced], into: dir, baseName: "photo", format: .jpeg)
        #expect(placed.outputs[0].lastPathComponent == "photo 2.jpg")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "original")
    }

    @Test func multipleOutputsAreGroupedInAFolder() throws {
        let dir = try Fixtures.tempDir()
        let work = try OutputLocator.makeWorkDirectory(near: dir)
        let files = try (1...3).map { i -> URL in
            let u = work.appendingPathComponent("doc page \(i).png")
            try Data([UInt8(i)]).write(to: u)
            return u
        }
        let placed = try OutputLocator().finalize(files, into: dir, baseName: "doc", format: .png)
        #expect(placed.folder?.lastPathComponent == "doc (PNG)")
        #expect(placed.outputs.count == 3)
        #expect(placed.outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func unwritableDestinationIsReported() throws {
        let dir = try Fixtures.tempDir()
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let source = locked.appendingPathComponent("x.png")
        #expect(throws: FormaError.destinationNotWritable(locked)) {
            try OutputLocator().destinationDirectory(for: source, policy: .besideOriginal)
        }
    }

    @Test func customFolderPolicy() throws {
        let dir = try Fixtures.tempDir()
        let out = dir.appendingPathComponent("Converted", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let resolved = try OutputLocator().destinationDirectory(for: URL(fileURLWithPath: "/tmp/a.png"), policy: .folder(out))
        #expect(resolved == out)
    }
}

@Suite("Wheel planning")
struct WheelPlannerTests {
    let registry = ConversionRegistry.standard(tools: .none)

    func facts(_ format: FileFormat, screenshot: Bool = false, pages: Int = 1) -> FileFacts {
        var f = FileFacts(url: URL(fileURLWithPath: "/tmp/x.\(format.preferredExtension)"), format: format, byteCount: 100)
        f.isScreenshot = screenshot
        f.pageCount = pages
        return f
    }

    @Test func pngWheelHasPrimaryFormatsEditAndMore() {
        let plan = WheelPlanner(registry: registry, maxPrimary: 6).plan(for: [facts(.png)])
        #expect(plan.primary.count == 6)
        #expect(plan.primary.contains(.convert(.jpeg)))
        #expect(plan.primary.last == .more)
        #expect(!plan.overflow.isEmpty)
        #expect(!plan.primary.contains(.convert(.png)))
        #expect(!plan.primary.contains(.convert(.webp)), "WebP output isn't available without cwebp")
    }

    @Test func screenshotPrioritisesJPEGAndPDF() {
        let plan = WheelPlanner(registry: registry).plan(for: [facts(.png, screenshot: true)])
        #expect(Array(plan.primary.prefix(2)) == [.convert(.jpeg), .convert(.pdf)])
    }

    @Test func pdfWheelLeadsWithEditAndText() {
        let plan = WheelPlanner(registry: registry).plan(for: [facts(.pdf, pages: 3)])
        #expect(Array(plan.primary.prefix(2)) == [.edit, .extractText])
        #expect(!plan.primary.contains(.convert(.txt)))
    }

    @Test func docxWheelMatchesSpecOrder() {
        let plan = WheelPlanner(registry: registry).plan(for: [facts(.docx)])
        #expect(Array(plan.primary.prefix(4)) == [.convert(.pdf), .convert(.rtf), .convert(.txt), .convert(.html)])
    }

    @Test func historyPromotesFormatButKeepsCanonicalOrder() {
        var usage = UsageStats()
        for _ in 0..<10 { usage.record(from: .png, to: .bmp) }
        let planner = WheelPlanner(registry: registry, maxPrimary: 6)
        let before = planner.plan(for: [facts(.png)], usage: UsageStats())
        let after = planner.plan(for: [facts(.png)], usage: usage)
        #expect(!before.primary.contains(.convert(.bmp)))
        #expect(after.primary.contains(.convert(.bmp)))
        // Items that stayed keep their relative order.
        let stayed = before.primary.filter { after.primary.contains($0) }
        #expect(stayed == after.primary.filter { before.primary.contains($0) })
        // Adaptive ordering can be switched off.
        #expect(planner.plan(for: [facts(.png)], usage: usage, adaptive: false) == before)
    }

    @Test func pinnedFormatsAlwaysAppear() {
        let plan = WheelPlanner(registry: registry, maxPrimary: 5).plan(for: [facts(.png)], pinned: [.gif])
        #expect(plan.primary.contains(.convert(.gif)))
    }

    @Test func multipleImagesOfferCombine() {
        let plan = WheelPlanner(registry: registry).plan(for: [facts(.png), facts(.jpeg), facts(.heic)])
        #expect(plan.primary.contains(.combinePDF))
        #expect(plan.primary.contains(.convert(.pdf)))
        #expect(!plan.primary.contains(.edit))
    }

    @Test func respectsSegmentLimits() {
        #expect(WheelPlanner(registry: registry, maxPrimary: 2).maxPrimary == 4)
        #expect(WheelPlanner(registry: registry, maxPrimary: 20).maxPrimary == 8)
    }
}

@Suite("History")
struct HistoryTests {
    @Test func recordsUsageAndRecentEntries() throws {
        let dir = try Fixtures.tempDir()
        let file = dir.appendingPathComponent("history.json")
        let out = dir.appendingPathComponent("a.pdf")
        try Data("x".utf8).write(to: out)
        let store = HistoryStore(fileURL: file)
        store.record(input: .png, output: .pdf, source: dir.appendingPathComponent("a.png"), result: out, keepHistory: true)
        store.record(input: .png, output: .pdf, source: nil, result: nil, keepHistory: false)
        let reloaded = HistoryStore(fileURL: file)
        #expect(reloaded.usage.count(from: .png, to: .pdf) == 2)
        #expect(reloaded.recent.count == 1)
        reloaded.clear()
        #expect(HistoryStore(fileURL: file).recent.isEmpty)
    }
}
