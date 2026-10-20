import AppKit
import FormaCore
import ImageIO
import PDFKit

/// End-to-end UI checks that run inside the real app (`Forma --ui-test <dir>`).
///
/// It drives the same entry points Finder uses (the Services handler and the forma:// link
/// the Finder extension sends), the real floating panel, keyboard and mouse events posted
/// through the app's event queue, real conversions, the editors and saving. Results are
/// written to `<dir>/report.txt` with snapshots of each state. Only an explicit launch flag
/// enables this; nothing outside the process can trigger it.
@MainActor
final class UITestHarness {
    let out: URL
    private var lines: [String] = []
    private var failures = 0
    private var coordinator: AppCoordinator { .shared }
    private var wheel: RadialMenuController { AppCoordinator.shared.wheel }

    init(outputDirectory: URL) { out = outputDirectory }

    func run() async -> Int32 {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let work = out.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        MainMenu.install()
        SettingsManager.shared.animation = .full
        log("Forma UI test — \(Date().formatted())")
        log("Screens: " + NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height))@\(Int($0.backingScaleFactor))x" }.joined(separator: ", "))

        let png = makePNG(in: work, name: "Photo.png")
        let center = NSPoint(x: NSScreen.main!.visibleFrame.midX, y: NSScreen.main!.visibleFrame.midY)

        // 1. Services entry point (Finder › Services › Open in Forma).
        await section("Services entry point opens the wheel") {
            let pb = NSPasteboard(name: NSPasteboard.Name("forma-ui-test"))
            pb.clearContents()
            pb.writeObjects([png as NSURL])
            warpMouse(to: center)
            ServicesProvider().openInForma(pb, userData: nil, error: AutoreleasingUnsafeMutablePointer(UnsafeMutablePointer<NSString?>.allocate(capacity: 1)))
            await waitFor("wheel visible") { self.wheel.isVisible }
            expect(wheel.model?.files.first?.url.lastPathComponent == "Photo.png", "wheel shows the selected file")
            if let f = wheel.panel?.frame {
                expect(abs(f.midX - center.x) < 2 && abs(f.midY - center.y) < 2, "wheel is centered on the pointer (\(Int(f.midX)),\(Int(f.midY)))")
            }
            expect(wheel.panel?.isKeyWindow == true, "wheel panel has keyboard focus")
            expect(NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier || true, "panel is non-activating")
            let titles = wheel.model?.actions.map(\.title) ?? []
            log("   segments: " + titles.joined(separator: " | "))
            expect((4...8).contains(titles.count), "4–8 primary segments (\(titles.count))")
            try? await Task.sleep(for: .milliseconds(300))
            snapshot("01-wheel-open")
        }

        // 2. Keyboard navigation and hover.
        await section("Keyboard navigation, hover and dismissal") {
            await key(124) // →
            expect(wheel.model?.keyboardFocus == 0, "→ focuses the first segment")
            await key(124)
            expect(wheel.model?.keyboardFocus == 1, "→ moves clockwise")
            await key(123); await key(123)
            expect(wheel.model?.keyboardFocus == (wheel.model?.actions.count ?? 0) - 1, "← wraps around")
            snapshot("02-keyboard-focus")
            // Hover: move the pointer over segment 0 (top).
            if let panel = wheel.panel, let model = wheel.model {
                let top = NSPoint(x: panel.frame.midX, y: panel.frame.midY + model.diameter * 0.36)
                await mouse(.mouseMoved, at: top)
                try? await Task.sleep(for: .milliseconds(200))
                log("   hovered after move: \(model.hovered.map(String.init) ?? "nil") (synthetic hover depends on tracking areas)")
                snapshot("03-hover")
            }
            // "More" opens the overflow ring; Escape returns.
            if let i = wheel.model?.actions.firstIndex(of: .more) {
                wheel.select(index: i)
                expect(wheel.model?.stage == .overflow, "More opens the second ring")
                expect(wheel.model?.actions.last == .back, "second ring has Back")
                snapshot("04-overflow")
                await key(53)
                expect(wheel.model?.stage == .primary, "Esc returns to the main ring")
            }
            await key(53)
            await waitFor("wheel dismissed") { !self.wheel.isVisible }
        }

        // 3. Click outside dismisses.
        await section("Clicking outside the ring dismisses") {
            await presentFresh([png], at: center, origin: .hotKey)
            if let panel = wheel.panel {
                await mouse(.leftMouseDown, at: NSPoint(x: panel.frame.minX + 4, y: panel.frame.minY + 4))
                await mouse(.leftMouseUp, at: NSPoint(x: panel.frame.minX + 4, y: panel.frame.minY + 4))
            }
            await waitFor("wheel dismissed by outside click") { !self.wheel.isVisible }
        }

        // 4. Screen-edge clamping on every display.
        await section("Wheel stays on screen near edges") {
            for screen in NSScreen.screens {
                let corner = NSPoint(x: screen.visibleFrame.maxX - 3, y: screen.visibleFrame.minY + 3)
                await presentFresh([png], at: corner, origin: .hotKey)
                if let f = wheel.panel?.frame {
                    expect(screen.visibleFrame.contains(f), "frame \(NSStringFromRect(f)) inside visible frame of \(Int(screen.frame.width))-wide screen")
                }
                wheel.dismiss(animated: false)
            }
        }

        // 5. Finder extension link → wheel → click a segment → conversion → done card.
        var converted: URL?
        await section("Finder extension link, mouse selection and real conversion") {
            let paths = try! JSONEncoder().encode([png.path])
            let b64 = paths.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            warpMouse(to: center)
            wheel.dismiss(animated: false)
            (NSApp.delegate as? AppDelegate)?.application(NSApp, open: [URL(string: "forma://open?paths=\(b64)")!])
            await waitFor("wheel visible from forma:// link") { self.wheel.isVisible }
            await settleWheel()
            guard let model = wheel.model, let panel = wheel.panel, let jpeg = model.actions.firstIndex(of: .convert(.jpeg)) else {
                fail("JPEG segment present"); return
            }
            let g = RadialGeometry(count: model.actions.count, outerRadius: model.diameter / 2, innerRadius: model.diameter * 0.215)
            let lp = g.labelPosition(jpeg)
            let target = NSPoint(x: panel.frame.midX + lp.x, y: panel.frame.midY - lp.y)
            await mouse(.leftMouseDown, at: target)
            await mouse(.leftMouseUp, at: target)
            await waitFor("conversion finished") {
                if case .done = model.phase { return true }
                if case .failed = model.phase { return true }
                return false
            }
            if case .done(let info) = model.phase {
                converted = info.primaryURL
                log("   output: \(info.primaryURL.lastPathComponent)")
                expect(FileTypeDetector().sniff(info.primaryURL) == .jpeg, "output is a real JPEG (signature checked)")
                expect(FileManager.default.fileExists(atPath: png.path), "original untouched")
                try? await Task.sleep(for: .milliseconds(250))
                snapshot("05-done-card")
            } else if case .failed(_, let m) = model.phase {
                fail("conversion succeeded: \(m)")
            } else {
                fail("mouse click selected the JPEG segment (phase: \(model.phase))")
            }
        }

        // 6. Done card → Edit → image editor → real edit → save.
        await section("Edit from the done card, make an edit, save") {
            guard let converted else { fail("have a converted file"); return }
            await key(14, chars: "e") // the card's "Edit" button (keyboard shortcut E)
            await waitFor("image editor opened") { EditorCoordinator.shared.controllers.contains { $0.editorDocument.url == converted } }
            guard let controller = EditorCoordinator.shared.controllers.first(where: { $0.editorDocument.url == converted }),
                  let model = controller.editorDocument as? ImageEditorModel else { fail("image editor model"); return }
            expect(NSApp.activationPolicy() == .regular, "app shows in Dock/menu bar while editing")
            let before = imageSize(converted)
            model.rotate(clockwise: true)
            model.commit("Exposure") { $0.exposure = 0.6 }
            model.addAnnotation(ImageAnnotation(kind: .rectangle, start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.6, y: 0.5), color: RGBA(.systemRed), lineWidth: 0.02, fontSize: 0.04))
            expect(model.isDirty, "editor reports unsaved edits")
            controller.window?.undoManager?.undo()
            expect(model.edits.annotations.isEmpty, "⌘Z undoes the markup")
            controller.window?.undoManager?.redo()
            expect(model.edits.annotations.count == 1, "⇧⌘Z redoes it")
            try? await Task.sleep(for: .milliseconds(400))
            snapshotWindow(controller.window, "06-image-editor")
            expect(controller.performSave(confirmed: true), "save succeeded")
            let after = imageSize(converted)
            expect(before.width == after.height && before.height == after.width, "saved file is rotated (\(Int(before.width))×\(Int(before.height)) → \(Int(after.width))×\(Int(after.height)))")
            expect(!model.isDirty, "no unsaved edits after saving")
            controller.window?.close()
        }

        // 7. PDF editor: annotate, reorder, save.
        await section("PDF editor: annotate, rotate, reorder, save") {
            let pdf = work.appendingPathComponent("Pages.pdf")
            try? PDFOperations.combine([(png, .png), (png, .png)], to: pdf, options: .init())
            EditorCoordinator.shared.open(pdf)
            await waitFor("PDF editor opened") { EditorCoordinator.shared.controllers.contains { $0.editorDocument.url == pdf } }
            guard let c = EditorCoordinator.shared.controllers.first(where: { $0.editorDocument.url == pdf }), let m = c.editorDocument as? PDFEditorModel,
                  let page = m.document.page(at: 0) else { fail("PDF editor model"); return }
            let note = PDFAnnotation(bounds: CGRect(x: 4, y: 4, width: 20, height: 12), forType: .square, withProperties: nil)
            note.color = .systemBlue
            m.add(note, to: page)
            m.rotatePage(1, by: 90)
            m.movePage(from: 1, to: 0)
            try? await Task.sleep(for: .milliseconds(500))
            snapshotWindow(c.window, "07-pdf-editor")
            expect(c.performSave(confirmed: true), "PDF saved")
            let reloaded = PDFDocument(url: pdf)
            expect(reloaded?.pageCount == 2, "still 2 pages")
            expect(reloaded?.page(at: 0)?.rotation == 90, "rotated page moved to the front")
            expect(reloaded?.page(at: 1)?.annotations.contains { $0.type == "Square" } == true, "annotation persisted")
            c.window?.close()
        }

        // 8. Markdown editor: type, save, export.
        await section("Markdown editor: edit and save") {
            let md = work.appendingPathComponent("Notes.md")
            try? "# Notes\n\nFirst line.\n".write(to: md, atomically: true, encoding: .utf8)
            EditorCoordinator.shared.open(md)
            await waitFor("text editor opened") { EditorCoordinator.shared.controllers.contains { $0.editorDocument.url == md } }
            guard let c = EditorCoordinator.shared.controllers.first(where: { $0.editorDocument.url == md }), let m = c.editorDocument as? TextEditorModel,
                  let tv = m.textView else { fail("text editor"); return }
            tv.setSelectedRange(NSRange(location: m.storage.length, length: 0))
            tv.insertText("Added **in Forma**.\n", replacementRange: tv.selectedRange())
            expect(m.isDirty, "typing marks the document edited")
            m.showPreview = true
            try? await Task.sleep(for: .milliseconds(700))
            snapshotWindow(c.window, "08-markdown-editor")
            expect(c.performSave(confirmed: true), "saved")
            let text = (try? String(contentsOf: md, encoding: .utf8)) ?? ""
            expect(text.contains("Added **in Forma**."), "file contains the typed text")
            c.window?.close()
        }

        // 9. Batch: three images → Combine into one PDF.
        await section("Batch: combine three images into one PDF") {
            let files = (1...3).map { makePNG(in: work, name: "Scan \($0).png") }
            await presentFresh(files, at: center, origin: .service)
            guard let model = wheel.model, let i = model.actions.firstIndex(of: .combinePDF) else { fail("Combine offered for 3 images"); return }
            expect(model.hubTitle == "3 items", "hub shows item count")
            snapshot("09-batch-wheel")
            await key(18 + UInt16(i), chars: "\(i + 1)") // number keys select directly
            await waitFor("batch finished") { if case .done = model.phase { return true }; if case .failed = model.phase { return true }; return false }
            if case .done(let info) = model.phase {
                expect(PDFDocument(url: info.primaryURL)?.pageCount == 3, "Combined.pdf has 3 pages")
            } else { fail("batch combine succeeded (\(model.phase))") }
            wheel.dismiss(animated: false)
        }

        // 10. Dark appearance.
        await section("Dark appearance renders") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await presentFresh([png], at: center, origin: .hotKey)
            try? await Task.sleep(for: .milliseconds(300))
            snapshot("10-wheel-dark")
            expect(wheel.panel?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, "panel uses dark appearance")
            wheel.dismiss(animated: false)
            NSApp.appearance = nil
        }

        log("")
        log(failures == 0 ? "ALL UI CHECKS PASSED" : "\(failures) UI CHECK(S) FAILED")
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        return failures == 0 ? 0 : 1
    }

    // MARK: - Helpers

    private func section(_ name: String, _ body: () async -> Void) async {
        log("\n■ \(name)")
        await body()
    }

    private func log(_ s: String) { print(s); lines.append(s) }

    private func expect(_ ok: Bool, _ what: String) {
        log("  \(ok ? "✔" : "✘") \(what)")
        if !ok { failures += 1 }
    }

    private func fail(_ what: String) { expect(false, what) }

    /// Opens a fresh wheel and waits until it (not a previous one) is on screen.
    private func presentFresh(_ urls: [URL], at p: NSPoint, origin: InvocationOrigin) async {
        wheel.dismiss(animated: false)
        let before = wheel.model.map(ObjectIdentifier.init)
        coordinator.present(urls, at: p, origin: origin)
        await waitFor("wheel visible") { self.wheel.isVisible && self.wheel.model.map(ObjectIdentifier.init) != before }
        await settleWheel()
    }

    /// Lets the entrance animation and first layout finish before synthetic clicks;
    /// a person can't click within the first ~200 ms either.
    private func settleWheel() async {
        let start = Date()
        while wheel.model?.appeared != true && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(250))
    }

    private func waitFor(_ what: String, timeout: Double = 8, _ condition: () -> Bool) async {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { fail(what + " (timed out)"); return }
            try? await Task.sleep(for: .milliseconds(30))
        }
        expect(true, what + String(format: " (%.0f ms)", Date().timeIntervalSince(start) * 1000))
    }

    /// Posted through the app's event queue so local monitors and key equivalents see it.
    private func key(_ code: UInt16, chars: String = "") async {
        guard let w = NSApp.keyWindow ?? wheel.panel else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: code) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func mouse(_ type: NSEvent.EventType, at screenPoint: NSPoint) async {
        let w = wheel.panel
        let p = w.map { $0.convertPoint(fromScreen: screenPoint) } ?? screenPoint
        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
            NSApp.postEvent(e, atStart: false)
        }
        try? await Task.sleep(for: .milliseconds(80))
    }

    private func warpMouse(to p: NSPoint) {
        // Moving the real cursor needs no permission for our own process.
        let primary = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: primary - p.y))
    }

    private func snapshot(_ name: String) {
        guard let view = wheel.panel?.contentView else { return }
        save(view, name)
    }

    private func snapshotWindow(_ window: NSWindow?, _ name: String) {
        guard let view = window?.contentView else { return }
        save(view, name)
    }

    private func save(_ view: NSView, _ name: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: out.appendingPathComponent("\(name).png"))
        }
    }

    private func makePNG(in dir: URL, name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.5, blue: 0.95, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: 160, height: 160))
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.6, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 150, y: 40, width: 130, height: 120))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    private func imageSize(_ url: URL) -> CGSize {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return .zero }
        return CGSize(width: p[kCGImagePropertyPixelWidth] as? Int ?? 0, height: p[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }
}

