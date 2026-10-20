# Contributing to Forma

Thanks for helping make Forma better. Bug reports, format requests and pull requests are all welcome.

## Development setup

You need macOS 14 or later and Swift 6 (Xcode, or just the Command Line Tools).

```bash
git clone https://github.com/LimeOsiris/forma.git
```

```bash
cd forma && swift build
```

- **Run the app:** `scripts/build.sh && scripts/install.sh`, or open `Package.swift` in Xcode and run the `Forma` scheme.
- **Run the tests:** `swift run FormaTestRunner` for unit tests, and `.build/debug/Forma --ui-test /tmp/forma-ui` for the in-app UI checks.
- **Regenerate the README images:** `scripts/screenshots.sh`.

## Guidelines

- **Keep the engine UI-free.** Conversion logic belongs in `Sources/FormaCore`, with tests in `Tests/FormaCoreTests`.
- **New formats** go in a `ConversionProvider`. Declare honest capabilities (lossless, editability, required tool), report caveats before converting, and write only inside the job's work directory.
- **Never fake a conversion.** Renaming an extension isn't conversion. Add a round-trip test that checks the output's signature and content.
- **Apple frameworks first.** External tools must stay optional, use fixed install paths, and run with argument arrays, never shell strings.
- **Privacy is a feature.** No network calls, telemetry or file scanning.
- **Match the house style.** Swift 6 language mode, zero warnings, and comments that explain *why*.
- **Accessibility:** new UI needs VoiceOver labels, keyboard access and Reduce Motion support.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Make sure `swift run FormaTestRunner` passes and the build has no warnings.
3. If you changed the UI, run the UI harness and include before/after screenshots.
4. Describe what changed and why. Link the issue if there is one.

## Reporting bugs

Use the **Bug report** template. Include your macOS version, the file type, and which entry point you used (Finder menu, shortcut, Services, Shift + right-click). Please don't attach private files; a small sample that reproduces the problem is ideal.
