// Entry point for `swift run FormaTestRunner`.
// Command Line Tools (without Xcode) can build Swift Testing bundles but its
// `swift test` helper doesn't execute them, so the same tests also build as an
// executable that calls Swift Testing's entry point directly.
import Testing

await Testing.__swiftPMEntryPoint() as Never
