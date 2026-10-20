# Architecture

```
Sources/
  FormaCore/                 UI-free engine (unit tested)
    Model/                   FileFormat, ConversionCapability, Editability, Caveat, FormaError
    Detection/               FileTypeDetector (magic bytes > UTType > extension), FileInspector
    Engine/                  ConversionProvider protocol, ConversionRegistry, ConversionCoordinator, BatchCoordinator
    Providers/               Image (ImageIO/CG), PDF (PDFKit/CG/Vision), Document (TextKit), Audio (AVFoundation),
                             LibreOffice / FFmpeg / cwebp (optional external tools)
    Planning/                OutputLocator (naming, atomic placement), WheelPlanner, HistoryStore
    Support/                 MarkdownRenderer, AttributedDocumentIO, AttributedPDFWriter, AttributedMarkdownWriter
  Forma/                     The app (AppKit + SwiftUI)
    App/                     main, AppDelegate (+Services, main menu), AppCoordinator, Engine, SettingsManager,
                             StatusItemController, CommandLineInterface, UITestHarness
    Radial/                  RadialGeometry, RadialMenuModel, RadialMenuView, WheelCards, RadialMenuController
    Integration/             EventTapManager, FinderItemResolver, FinderSelection, HotKeyManager, IntegrationManager
    Editors/                 EditorCoordinator (+window controller), Image*, PDF*, Text* editors
    Settings/                Settings tabs, onboarding, editor snapshots
    Shared/                  Toast, Notifier, QuickLookController
Extensions/FinderSync/       Sandboxed Finder Sync extension (built by scripts/build.sh)
Tests/FormaCoreTests/        Swift Testing suites + real-file fixtures
Tests/FormaTestRunner/       Executable runner over the same tests (Command Line Tools)
```

## Conversion engine

- **`ConversionProvider`** declares its capabilities: input → output, lossless, metadata, transparency, editability, required tool and priority. Each provider computes caveats for a specific file before converting, and converts by writing **only inside a scratch directory** while honouring `Task` cancellation and reporting progress.
- **`ConversionRegistry`** keeps the best provider for each pair (an installed LibreOffice outranks the native engine for Word → PDF). It fills gaps with two-step paths only when the first step is lossless and not rasterising, and it discloses the step ("Converted via …"). Identity conversions never appear.
- **`ConversionCoordinator`** runs one conversion: inspect the file (signature, encryption, alpha, frames, pages), check free space and that the destination is writable, convert in a work directory on the same volume, validate the output's signature and size, then hand it to `OutputLocator.finalize`. Finalize moves the result into place with a no-overwrite rename and retries the next number if someone takes the name at the last moment. Several output files are grouped into a folder that is moved in one step. Partial files are never visible under a final name.
- **`BatchCoordinator`** plans the batch (skipping duplicates and unsupported files with a reason), runs it with overall progress, keeps going past individual failures, stops on cancellation, and returns a report.
- **Concurrency:** providers are `Sendable` value types that create heavy objects lazily. AppKit text import and pagination run on the main actor because AppKit requires it; everything else runs in the background. The package builds in Swift 6 language mode with no warnings.

## The wheel

- `WheelPlanner` turns a file's facts into 4–8 primary actions plus overflow. *Membership* adapts to pins and local usage; *order* follows each file type's canonical list, so positions stay put.
- `RadialMenuController` owns a borderless, non-activating `NSPanel` at pop-up-menu level. The panel takes keyboard focus while Finder stays the active app. It is clamped to the visible frame of the screen under the pointer, so it works across displays and Retina scales.
- Clicks are resolved in AppKit (`WheelHostingView`, with first-mouse acceptance). Hover, animation and accessibility live in SwiftUI. Keyboard input goes through a local monitor; clicks in other apps are caught by a global mouse monitor.
- Phases: choosing → options/confirmation → working (shown only after 180 ms) → done card / failure card. A conversion keeps running if the wheel is dismissed and notifies when it finishes.
- Accessibility: every segment is a VoiceOver button with a label, a hint (the trade-off) and an action, and the wheel announces itself when it opens. Increase Contrast uses solid strokes and fills; Reduce Motion (system setting or app setting) switches to fades only.

## Editors

The editors are `EditorDocument` models hosted by `EditorWindowController`, which sits in the responder chain for Save, Save a Copy and Export. Overwriting needs confirmation once per window. Edits register with the window's `UndoManager`, so Edit › Undo shows names like "Undo Crop". While an editor or Settings window is open, Forma switches from menu bar agent to regular app so the Dock icon and menu bar appear.

- **Image:** an `ImageEdits` value (crop → ordered geometry ops → Core Image adjustments → resize) plus markup stored in normalized canvas coordinates. A single `AnnotationRenderer` draws markup both on screen and in exported files, so they match.
- **PDF:** a PDFKit `PDFView` with a transparent overlay that turns drags into annotations. In Select mode the overlay only intercepts clicks on annotations, so text selection keeps working.
- **Text:** `NSTextView` (find bar, undo, font panel) with a regex Markdown highlighter and a WebKit preview with JavaScript disabled.

## Main dependencies

Only Apple frameworks: AppKit, SwiftUI, ImageIO, Core Graphics, Core Image, PDFKit, Vision, AVFoundation, AudioToolbox, UniformTypeIdentifiers, FinderSync, Quick Look, UserNotifications, ServiceManagement, Carbon (hotkey only) and ApplicationServices (AX and event tap). There are no third-party Swift packages.
