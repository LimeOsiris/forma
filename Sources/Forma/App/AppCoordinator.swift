import AppKit
import FormaCore
import os

let formaLog = Logger(subsystem: "app.forma.mac", category: "invocation")
import UniformTypeIdentifiers

/// Shared conversion engine. Heavy work happens inside providers, lazily, off the main thread.
@MainActor
final class Engine {
    static let shared = Engine()

    private(set) var tools: ToolAvailability
    private(set) var registry: ConversionRegistry
    private(set) var coordinator: ConversionCoordinator
    let history = HistoryStore(fileURL: HistoryStore.defaultURL)

    private init() {
        tools = ExternalToolLocator.detect()
        registry = .standard(tools: tools)
        coordinator = ConversionCoordinator(registry: registry)
    }

    var batch: BatchCoordinator { BatchCoordinator(coordinator: coordinator) }

    /// Re-checks optional tools (cheap: a few file-existence checks).
    func refreshTools() {
        let now = ExternalToolLocator.detect()
        guard now != tools else { return }
        tools = now
        registry = .standard(tools: now)
        coordinator = ConversionCoordinator(registry: registry)
    }
}

/// Where an invocation came from; used for placement and diagnostics.
enum InvocationOrigin: String {
    case shiftRightClick, hotKey, service, finderExtension, openFile, menuBar, commandLine
}

/// Routes every entry point to the same wheel and the same conversion engine.
@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()

    let wheel = RadialMenuController()
    private var work: Task<Void, Never>?
    private var activeModel: RadialMenuModel?
    private var settings: SettingsManager { .shared }
    private var engine: Engine { .shared }

    private init() {
        wheel.handlers = .init(
            select: { [weak self] action in self?.handle(action) },
            confirmOptions: { [weak self] in self?.confirmOptions() },
            cancelWork: { [weak self] in self?.cancelWork() },
            done: { [weak self] choice in self?.handleDone(choice) },
            dismissed: { [weak self] in self?.wheelDismissed() }
        )
    }

    // MARK: - Entry

    /// Shows the wheel for `urls` near `point` (Cocoa screen coordinates; defaults to the cursor).
    func present(_ urls: [URL], at point: NSPoint? = nil, origin: InvocationOrigin) {
        let location = point ?? NSEvent.mouseLocation
        formaLog.info("present \(urls.count, privacy: .public) item(s) via \(origin.rawValue, privacy: .public)")
        let files = urls.filter { !FinderItemResolver.isPlainDirectory($0) }
        guard !files.isEmpty else {
            Toast.show(urls.isEmpty ? FormaError.nothingSelected.localizedDescription : "Forma converts files, not folders.", symbol: "questionmark.folder", near: location)
            return
        }
        if case .working = wheel.model?.phase { _ = wheel.detachIfWorking() }
        engine.refreshTools()
        let coordinator = engine.coordinator
        Task {
            // Header reads only; fast even for dozens of files, but kept off the main thread.
            let facts: [FileFacts] = await Task.detached(priority: .userInitiated) {
                files.prefix(2000).compactMap { try? coordinator.inspect($0) }
            }.value
            guard !facts.isEmpty else {
                let name = files.count == 1 ? "“\(files[0].lastPathComponent)”" : "these files"
                Toast.show("Forma doesn't know how to convert \(name).", symbol: "doc.questionmark", near: location)
                return
            }
            if facts.count == 1, facts[0].isEncrypted {
                Toast.show(FormaError.passwordProtected(facts[0].url.lastPathComponent).localizedDescription, symbol: "lock", near: location)
                return
            }
            self.showWheel(for: facts, at: location)
        }
    }

    private func showWheel(for facts: [FileFacts], at point: NSPoint) {
        let planner = WheelPlanner(registry: engine.registry, maxPrimary: settings.maxSegments)
        let plan = planner.plan(for: facts, usage: engine.history.usage, pinned: settings.pinnedFormats, adaptive: settings.adaptiveOrdering)
        guard !plan.primary.isEmpty else {
            Toast.show("No conversions are available for this file.", symbol: "nosign", near: point)
            return
        }
        let model = RadialMenuModel(files: facts, plan: plan, options: settings.conversionOptions,
                                    reduceMotion: settings.reduceMotion, accent: settings.accent.color, diameter: settings.wheelSize.diameter)
        if facts.count == 1 {
            for action in plan.primary + plan.overflow {
                guard let out = action.trackedFormat else { continue }
                model.caveatCache[action] = engine.coordinator.caveats(for: facts[0], to: out, options: model.options)
            }
        }
        activeModel = model
        wheel.show(model, at: point)
    }

    // MARK: - Actions

    private func handle(_ action: WheelAction) {
        guard let model = wheel.model else { return }
        switch action {
        case .edit:
            let url = model.files[0].url
            wheel.dismiss()
            EditorCoordinator.shared.open(url)
        case .quickLook:
            let urls = model.files.map(\.url)
            wheel.dismiss()
            QuickLookController.shared.show(urls)
        case .more, .back:
            break
        default:
            let needsConfirm = (model.caveatCache[action] ?? []).contains { $0.severity == .requiresConfirmation }
            let optionHeld = NSEvent.modifierFlags.contains(.option)
            let hasOptions = Self.hasOptions(action, files: model.files)
            if needsConfirm || ((settings.askForOptions || optionHeld) && hasOptions) {
                model.phase = .options(action)
            } else {
                run(action, model: model)
            }
        }
    }

    static func hasOptions(_ action: WheelAction, files: [FileFacts]) -> Bool {
        guard case .convert(let f) = action else { return false }
        return f.category == .image
    }

    private func confirmOptions() {
        guard let model = wheel.model, case .options(let action) = model.phase else { return }
        model.options.acceptFirstFrameOnly = true
        run(action, model: model)
    }

    private func cancelWork() {
        work?.cancel()
    }

    private func wheelDismissed() {
        // A finished or abandoned wheel releases its model; running work keeps its own reference.
    }

    // MARK: - Running conversions

    private func run(_ action: WheelAction, model: RadialMenuModel) {
        let options = model.options
        model.phase = .choosing
        model.busy = true
        let files = model.files

        switch action {
        case .convert(let format) where files.count > 1:
            runBatch(.each(format), model: model, options: options)
        case .combinePDF:
            runBatch(.combinePDF, model: model, options: options)
        case .convert(let format):
            runSingle(files[0].url, to: format, model: model, options: options)
        case .extractText:
            runSingle(files[0].url, to: .txt, model: model, options: options)
        case .splitPDF:
            runSplit(files[0].url, model: model)
        default:
            break
        }
    }

    /// Picks the output folder (and maybe name), asking only when policy or permissions require it.
    private func destination(for source: URL, format: FileFormat, isBatch: Bool) -> (dir: URL, base: String?)? {
        let policy = settings.outputPolicy
        if policy != .ask {
            do {
                return (try engine.coordinator.locator.destinationDirectory(for: source, policy: policy), nil)
            } catch FormaError.destinationNotWritable {
                // Fall through to asking: e.g. a read-only volume or a locked folder.
            } catch {
                return (source.deletingLastPathComponent(), nil)
            }
        }
        return askForDestination(for: source, format: format, isBatch: isBatch)
    }

    private func askForDestination(for source: URL, format: FileFormat, isBatch: Bool) -> (dir: URL, base: String?)? {
        NSApp.activate(ignoringOtherApps: true)
        if isBatch {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Convert Here"
            panel.message = "Choose where to save the converted files."
            panel.directoryURL = source.deletingLastPathComponent()
            return panel.runModal() == .OK ? panel.url.map { ($0, nil) } : nil
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [format.utType]
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "." + format.preferredExtension
        panel.prompt = "Convert"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // NSSavePanel already confirmed replacing; Forma still never overwrites: a unique name is chosen if needed.
        return (url.deletingLastPathComponent(), url.deletingPathExtension().lastPathComponent)
    }

    private func runSingle(_ source: URL, to format: FileFormat, model: RadialMenuModel, options: ConversionOptions) {
        guard let dest = destination(for: source, format: format, isBatch: false) else { model.phase = .choosing; model.busy = false; return }
        let coordinator = engine.coordinator
        let throttle = ProgressThrottle()
        let name = source.lastPathComponent
        showWorkingSoon(model, label: name)
        work = Task { [weak self] in
            do {
                let result = try await coordinator.convert(source, to: format, options: options, into: dest.dir, baseName: dest.base) { p in
                    guard throttle.shouldReport(p) else { return }
                    Task { @MainActor in if case .working = model.phase { model.phase = .working(progress: p, label: name) } }
                }
                self?.finished(single: result, inputFormat: model.files[0].format, model: model)
            } catch {
                self?.failed(FormaError.wrap(error), model: model)
            }
        }
    }

    private func runBatch(_ mode: BatchMode, model: RadialMenuModel, options: ConversionOptions) {
        let batch = engine.batch
        let urls = model.files.map(\.url)
        var policy = settings.outputPolicy
        if policy == .ask {
            let fmt: FileFormat = { if case .each(let f) = mode { return f }; return .pdf }()
            guard let dest = askForDestination(for: urls[0], format: fmt, isBatch: true) else { model.busy = false; return }
            policy = .folder(dest.dir)
        }
        let plan = batch.plan(urls, mode: mode)
        guard !plan.isEmpty else {
            model.busy = false
            model.phase = .failed(title: "Nothing to convert", message: plan.skipped.first?.reason ?? "None of the selected files can be converted this way.")
            return
        }
        let total = plan.items.count
        model.phase = .working(progress: 0, label: "\(total) files")
        let throttle = ProgressThrottle()
        work = Task { [weak self] in
            let report = await batch.run(plan, options: options, policy: policy) { fraction, current in
                guard throttle.shouldReport(fraction) else { return }
                let done = min(total, Int(fraction * Double(total)) + 1)
                let label = mode == .combinePDF ? "Combining \(total) files" : "\(done) of \(total) · \(current)"
                Task { @MainActor in if case .working = model.phase { model.phase = .working(progress: fraction, label: label) } }
            }
            self?.finished(batch: report, mode: mode, model: model)
        }
    }

    private func runSplit(_ source: URL, model: RadialMenuModel) {
        guard let dest = destination(for: source, format: .pdf, isBatch: false) else { model.busy = false; return }
        showWorkingSoon(model, label: source.lastPathComponent)
        let locator = engine.coordinator.locator
        work = Task { [weak self] in
            do {
                let base = OutputLocator.sanitize(source.deletingPathExtension().lastPathComponent)
                let result: ConversionResult = try await Task.detached {
                    let workDir = try OutputLocator.makeWorkDirectory(near: dest.dir)
                    defer { try? FileManager.default.removeItem(at: workDir) }
                    let parts = try PDFOperations.split(source, into: workDir, baseName: base)
                    let placed = try locator.finalize(parts, into: dest.dir, baseName: base, format: .pdf, folderName: "\(base) pages")
                    return ConversionResult(source: source, outputs: placed.outputs, containerFolder: placed.folder, format: .pdf, editability: .annotationOnly, caveats: [])
                }.value
                self?.finished(single: result, inputFormat: .pdf, model: model)
            } catch {
                self?.failed(FormaError.wrap(error), model: model)
            }
        }
    }

    /// Fast conversions go straight to the confirmation; the spinner only appears after 180 ms.
    private func showWorkingSoon(_ model: RadialMenuModel, label: String) {
        model.hovered = nil
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            if model.phase == .choosing, model.busy, self.wheel.model === model {
                model.phase = .working(progress: nil, label: label)
            }
        }
    }

    // MARK: - Completion

    private func finished(single result: ConversionResult, inputFormat: FileFormat, model: RadialMenuModel) {
        work = nil
        engine.history.record(input: inputFormat, output: result.format, source: result.source, result: result.primaryURL, keepHistory: settings.keepHistory)
        StatusItemController.shared.rebuildMenu()
        let count = result.outputs.count
        let info = RadialMenuModel.DoneInfo(
            title: result.containerFolder?.lastPathComponent ?? result.outputs.first?.lastPathComponent ?? "",
            detail: count > 1 ? "\(count) files · \(result.format.displayName)" : "Saved in \(result.primaryURL.deletingLastPathComponent().lastPathComponent)",
            primaryURL: result.primaryURL,
            allOutputs: result.outputs,
            editable: count == 1 && EditorCoordinator.canEdit(result.outputs[0]),
            editability: result.editability,
            notes: result.caveats.filter { $0.severity != .info || $0.message.contains("recognized") || $0.message.contains("first") }.map(\.message)
        )
        complete(info: info, model: model, notification: "Converted to \(result.format.displayName)")
    }

    private func finished(batch report: BatchReport, mode: BatchMode, model: RadialMenuModel) {
        work = nil
        if report.cancelled && report.results.isEmpty { dismissIfCurrent(model); return }
        let outputs = report.results.flatMap(\.outputs)
        if case .each(let f) = mode {
            for r in report.results { engine.history.record(input: FileTypeDetector().format(of: r.source), output: f, source: r.source, result: r.primaryURL, keepHistory: settings.keepHistory) }
        } else if let r = report.results.first {
            engine.history.record(input: nil, output: .pdf, source: r.source, result: r.primaryURL, keepHistory: settings.keepHistory)
        }
        StatusItemController.shared.rebuildMenu()
        guard let first = outputs.first else {
            let message = report.failures.first?.message ?? "None of the files could be converted."
            failed(.underlying(message), model: model)
            return
        }
        var notes: [String] = report.failures.prefix(2).map { "\($0.url.lastPathComponent): \($0.message)" }
        if !report.skipped.isEmpty { notes.append("Skipped \(report.skipped.count): " + report.skipped.prefix(3).map(\.url.lastPathComponent).joined(separator: ", ")) }
        let info = RadialMenuModel.DoneInfo(
            title: outputs.count == 1 ? first.lastPathComponent : report.summary,
            detail: outputs.count == 1 ? "Saved in \(first.deletingLastPathComponent().lastPathComponent)" : "Saved next to the originals",
            primaryURL: first,
            allOutputs: outputs,
            editable: outputs.count == 1 && EditorCoordinator.canEdit(first),
            editability: outputs.count == 1 ? report.results.first?.editability : nil,
            notes: notes
        )
        complete(info: info, model: model, notification: report.summary)
    }

    private func complete(info: RadialMenuModel.DoneInfo, model: RadialMenuModel, notification: String) {
        let visible = wheel.model === model
        if settings.openEditorAfterConversion && info.editable {
            if visible { wheel.dismiss() }
            EditorCoordinator.shared.open(info.primaryURL)
            return
        }
        if settings.openAfterConversion {
            NSWorkspace.shared.open(info.primaryURL)
        }
        if visible {
            model.phase = .done(info)
            wheel.scheduleAutoClose()
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "Converted. \(info.title)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        } else if settings.showNotifications {
            Notifier.post(title: notification, body: info.title, reveal: info.allOutputs)
        }
    }

    private func failed(_ error: FormaError, model: RadialMenuModel) {
        work = nil
        if error == .cancelled { dismissIfCurrent(model); return }
        if wheel.model === model {
            model.phase = .failed(title: error.title, message: error.localizedDescription)
        } else if settings.showNotifications {
            Notifier.post(title: error.title, body: error.localizedDescription, reveal: [])
        }
    }

    private func dismissIfCurrent(_ model: RadialMenuModel) {
        if wheel.model === model { wheel.dismiss() }
    }

    private func handleDone(_ choice: RadialMenuActions.DoneChoice) {
        guard let model = wheel.model, case .done(let info) = model.phase else { wheel.dismiss(); return }
        wheel.dismiss()
        switch choice {
        case .open:
            NSWorkspace.shared.open(info.allOutputs.count > 1 ? info.primaryURL.deletingLastPathComponent() : info.primaryURL)
        case .edit:
            EditorCoordinator.shared.open(info.primaryURL)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(info.allOutputs.isEmpty ? [info.primaryURL] : Array(info.allOutputs.prefix(200)))
        case .close:
            break
        }
    }

    // MARK: - Other entry points

    /// Hotkey: act on Finder's selection.
    func invokeOnFinderSelection() {
        let point = NSEvent.mouseLocation
        switch FinderSelection.selectedFiles() {
        case .success(let urls): present(urls, at: point, origin: .hotKey)
        case .failure(let f): Toast.show(f.message, symbol: f == .nothingSelected ? "cursorarrow.click.2" : "exclamationmark.triangle", near: point)
        }
    }

    /// Menu bar "Open Forma…": choose files with an open panel.
    func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to convert or edit"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        present(panel.urls, at: NSPoint(x: screen.midX, y: screen.midY), origin: .menuBar)
    }
}

extension FinderSelection.Failure: Equatable {
    static func == (a: Self, b: Self) -> Bool { a.message == b.message }
}

/// Limits progress UI updates to ~30 per second.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func shouldReport(_ p: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if p >= 1 || now.timeIntervalSince(last) > 1.0 / 30 { last = now; return true }
        return false
    }
}
