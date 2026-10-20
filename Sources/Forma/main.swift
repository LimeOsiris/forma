import AppKit

// Forma runs as a menu bar agent (LSUIElement). It becomes a regular app with a
// Dock icon and menu bar only while an editor or Settings window is open.
let app = NSApplication.shared
let delegate = AppDelegate()
let arguments = Array(CommandLine.arguments.dropFirst())
if CommandLineInterface.handles(arguments) {
    delegate.cliArguments = arguments
}
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
