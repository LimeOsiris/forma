# Forma

**Convert. Edit. Done.** A native macOS utility that converts and edits files from Finder through a radial wheel that opens at your pointer. Everything runs locally: no accounts, uploads, analytics or network requests.

```
Select a file in Finder → invoke Forma → pick a format on the wheel → the new file appears next to the original
                                                                    → Open · Edit · Reveal · Done
```

## Install

Requirements: macOS 14 or later, Apple silicon or Intel with a Swift 6 toolchain (Xcode **or** just the Command Line Tools).

```bash
scripts/build.sh
```

```bash
scripts/install.sh
```

`build.sh` produces a signed `Forma.app` (ad-hoc unless you set `SIGN_IDENTITY`) in `~/Library/Caches/Forma/build`, plus a copy in `./build`. `install.sh` copies it to `~/Applications` (set `INSTALL_DIR=/Applications` to change that), registers it with Launch Services, the Services menu and pluginkit, then launches it. It changes no system or privacy settings.

The app is built outside the project folder on purpose. iCloud/File Provider folders, such as a synced Desktop, add Finder metadata to bundles, and codesign rejects that.

## Ways to open the wheel

| Entry point | Setup | Permission | Status |
|---|---|---|---|
| **Right-click › Convert with Forma…** (Finder Sync extension) | Turn on *Forma* in System Settings › General › Login Items & Extensions › Finder | none | Built and registered with pluginkit; you have to switch it on yourself |
| **⌥⌘K** (configurable) on Finder's selection | none | Automation: macOS asks once whether Forma may control Finder | Works |
| **Right-click › Services › Open in Forma** | none | none | Registered and verified |
| **Shift + right-click** on a Finder item | Settings › Shortcuts › Enable… | Accessibility | Implemented; needs your approval, not verified on this machine (see below) |
| `open -a Forma file…`, drag onto the app, menu bar › Open Forma… | none | none | Works |

All of them open the same wheel and use the same conversion engine. To set up Shift + right-click, see [docs/FINDER_INTEGRATION.md](docs/FINDER_INTEGRATION.md), which also explains its limits.

### Using the wheel

- **Mouse:** hover to preview (the hub shows the format and any trade-off, like "Transparent areas will become white"), click to convert. You can also press, drag over a segment and release.
- **Keyboard:** ← → (or Tab) to move, Return/Space to choose, 1–8 to pick directly, Esc to go back or dismiss.
- **⌥ while choosing** shows options (quality, maximum size, PDF resolution).
- **More** opens a second ring. Click outside the ring or press Esc to dismiss.
- Quick conversions go straight to the confirmation card. Slower ones show progress in the hub (Esc cancels). If you dismiss the wheel, the conversion continues and a notification tells you when it's done.

## What converts (built in, no dependencies)

| From | To |
|---|---|
| PNG, JPEG, HEIC, AVIF, TIFF, BMP, GIF, WebP (read), SVG | PNG, JPEG, HEIC, AVIF, TIFF, BMP, GIF, PDF |
| PDF | PNG / JPEG / HEIC per page, multi-page TIFF, text (with on-device OCR for scans), split into single pages |
| Several images or PDFs | one combined or merged PDF |
| Markdown | HTML (styled, standalone), PDF, Word, RTF, ODT, text |
| Word (DOCX/DOC), ODT, RTF, RTFD, HTML, text | PDF, Word, ODT, RTF, HTML, text, Markdown |
| M4A, WAV, AIFF, CAF, MP3, FLAC, AAC, MOV/MP4 audio | M4A (AAC), WAV, AIFF, CAF, FLAC; MOV ⇄ MP4 rewrap |

Every conversion re-encodes the file; renaming an extension never counts as conversion. Outputs are written to a scratch folder, checked by signature, and only then moved into place. Forma **never overwrites** anything: if the name is taken it writes `photo 2.jpg`, then `photo 3.jpg`, and so on.

### Optional components, detected automatically

| Tool | Adds | Licence | Install |
|---|---|---|---|
| LibreOffice | High-fidelity Word/ODT → PDF (preferred when present) | MPL 2.0 | libreoffice.org, into /Applications |
| FFmpeg | MP3 output | LGPL/GPL (build dependent) | `brew install ffmpeg` |
| cwebp | WebP output | BSD-3 | `brew install webp` |

Forma looks for these only at fixed install paths (it never uses a shell PATH). It runs them with separate argument arrays, never shell strings, and they run locally. **None were installed on the build machine, so these three paths are implemented but untested.**

## Editing

**Edit** on the wheel or the confirmation card opens Forma's editor for the file:

- **Images:** crop (with aspect presets), rotate, flip, resize, exposure, brightness, contrast, saturation, sharpness, plus rectangle, oval, arrow, pen, highlight and text markup. Edits are non-destructive with full undo/redo, and saving has quality control.
- **PDFs:** page thumbnails with drag-to-reorder, rotate, delete, insert pages from PDFs or images, highlights, notes, text boxes, shapes, freehand drawing, signatures and undo/redo. Forma edits **annotations and pages only**. It can't rewrite a PDF's original text, and the editor says so.
- **Text and Markdown:** syntax highlighting, live preview, find and replace, font size, undo, export to PDF/HTML.
- **Rich text (RTF, RTFD, DOCX, ODT, DOC, HTML):** edited with the macOS text engine. Word, ODT and HTML files show a "may lose formatting" notice with **Open in Default App**, and their Save button defaults to *Save a Copy*.

Overwriting the file you're editing always asks first; **Save a Copy** is the default action.

## Settings

The menu bar icon opens **Open Forma…**, **Convert Finder Selection**, **Recent Conversions**, **Settings…** and **Quit**. Settings are grouped into:

- **General:** launch at login, save location (next to the original, ask each time, or a folder), notifications, history.
- **Conversion:** quality, PDF resolution, OCR, ask for options, open after converting, adaptive ordering, pinned formats.
- **Appearance:** system/light/dark, accent colour, wheel size, compact mode, animation level (Reduce Motion is honoured).
- **Shortcuts:** shortcut recorder, Shift + right-click toggle, reset.
- **Integrations:** live permission status, Finder extension state, optional tools.
- **About.**

**Smart ordering** starts from file-type defaults: screenshots favour JPEG, PDF and HEIC; Word files favour PDF, RTF, Text and HTML; PDFs lead with Edit and Text. Formats you use often earn a slot on the wheel, but a format keeps its position once it's there, and pinned formats always show. Usage counts are stored only in `~/Library/Application Support/Forma/history.json`.

## Command line

The app binary also works headless, which is handy for scripting and testing:

```bash
~/Applications/Forma.app/Contents/MacOS/Forma --list photo.png
```

```bash
~/Applications/Forma.app/Contents/MacOS/Forma --convert notes.md --to pdf --out ~/Desktop
```

## Testing

```bash
swift run FormaTestRunner
```

```bash
swift build --product Forma && .build/debug/Forma --ui-test /tmp/forma-ui
```

- **Unit and round-trip suite:** 67 tests in 11 suites. They generate real fixtures and check output signatures, pixel values (transparency flattened to white, not black), dimensions, EXIF orientation, page counts, extracted and OCR'd text, audio duration, no-overwrite naming, path sanitising, cancellation leaving no partial files, password-protected PDFs, batch planning and wheel ordering. `swift test` runs the same suite under Xcode. With the Command Line Tools alone, SwiftPM builds Swift Testing bundles but doesn't execute them, which is why the executable runner exists.
- **In-app UI harness:** 44 checks. It drives the real app through the Services handler and the forma:// link the Finder extension sends: the wheel opens centred on the pointer with key focus, arrow keys move around, hover works, More/Back, Esc and outside clicks dismiss, the wheel stays on screen at edges, a mouse click on a segment runs a real conversion, then the done card's **E** key opens the editor, rotate/exposure/markup with undo and redo, and Save writes a rotated file. It also covers the PDF editor (annotate, rotate, reorder, save, reload), the Markdown editor (type, save) and a three-image batch combine, in light and dark, saving a report and snapshots to the output folder.

Results on the build machine (macOS 26.6, Swift 6.3.3, Command Line Tools only): **67/67 unit tests pass, and 44/44 UI checks passed in 8 consecutive runs.** Single-file conversions took 0.03 s (PNG → JPEG) and about 0.5 s (Markdown → PDF/DOCX). The built app is 4.7 MB.

## Privacy and security

- Forma makes no network requests, collects no telemetry and keeps no account. It doesn't index or scan your files; it touches only the files you hand it.
- It's not sandboxed, by necessity: it writes next to your originals, sends Apple Events to Finder and optionally runs an event tap. The Finder extension **is** sandboxed.
- It asks for Accessibility only when you click **Enable…** for Shift + right-click. Automation consent is requested by macOS on first use of the shortcut.
- The forma:// link only ever opens the wheel; it never converts anything by itself.
- Output names are sanitised (no `/`, `:`, control characters or leading dots), files are written atomically, and malformed files are treated as untrusted input that fails with a readable error.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/FINDER_INTEGRATION.md](docs/FINDER_INTEGRATION.md) and [docs/RELEASE.md](docs/RELEASE.md).

## Known limitations

- **Shift + right-click** depends on Finder's accessibility tree, which Apple doesn't document. Verifying it needs you to grant Accessibility, which wasn't possible here. When Forma can't identify the clicked item with certainty, Finder's normal menu appears instead.
- **Ad-hoc signing** means macOS ties privacy permissions to the exact build, so after a rebuild you may need to re-grant Accessibility and Automation. Signing with a stable identity avoids that.
- **Word/ODT without LibreOffice** goes through the macOS text engine. Headers, footers, footnotes, comments and complex layouts don't carry over, and the UI says so.
- **WebP and MP3 output** need the optional tools above. WebP *input* is native.
- **Animated GIFs:** converting to a single-frame format keeps the first frame, and Forma asks you to confirm before it does. GIF → GIF and GIF → TIFF/PDF keep every frame.
- **Builds are arm64 only** from these scripts. A universal build needs Xcode, or a second build for x86_64 combined with `lipo`.
- **No Xcode project:** Xcode wasn't installed, so the project is a Swift package. Xcode opens `Package.swift` directly for the app and tests; the Finder extension bundle is assembled by `scripts/build.sh`.
