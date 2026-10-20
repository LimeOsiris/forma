import AppKit
import ApplicationServices
import FormaCore

/// Reads Finder's current selection over Apple Events. The first use triggers macOS's
/// "Forma wants to control Finder" consent prompt (Automation permission).
@MainActor
enum FinderSelection {
    static let finderBundleID = "com.apple.finder"

    enum Failure: Error {
        case finderNotRunning
        case notAuthorized
        case nothingSelected
        case scriptError(String)

        var message: String {
            switch self {
            case .finderNotRunning: "Finder isn't running."
            case .notAuthorized: "Forma needs permission to read Finder's selection. Allow it in System Settings › Privacy & Security › Automation › Forma."
            case .nothingSelected: FormaError.nothingSelected.localizedDescription
            case .scriptError(let m): "Couldn't read Finder's selection. \(m)"
            }
        }
    }

    static var isFinderRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID).isEmpty
    }

    static func selectedFiles() -> Result<[URL], Failure> {
        guard isFinderRunning else { return .failure(.finderNotRunning) }
        let source = """
        tell application id "com.apple.finder"
            set out to {}
            repeat with itemRef in (get selection as alias list)
                set end of out to POSIX path of itemRef
            end repeat
            return out
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return .failure(.scriptError("Script unavailable.")) }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 || code == -1744 { return .failure(.notAuthorized) }
            if code == -600 { return .failure(.finderNotRunning) }
            return .failure(.scriptError(errorInfo[NSAppleScript.errorMessage] as? String ?? "Error \(code)."))
        }
        var urls: [URL] = []
        if result.numberOfItems > 0 {
            for i in 1...result.numberOfItems {
                if let path = result.atIndex(i)?.stringValue { urls.append(URL(fileURLWithPath: path)) }
            }
        } else if let single = result.stringValue, !single.isEmpty {
            urls.append(URL(fileURLWithPath: single))
        }
        return urls.isEmpty ? .failure(.nothingSelected) : .success(urls)
    }

    enum AutomationStatus { case granted, notDetermined, denied, finderNotRunning, unknown }

    /// Checks Automation consent without prompting.
    static func automationStatus() -> AutomationStatus {
        guard isFinderRunning else { return .finderNotRunning }
        var target = AEAddressDesc()
        let bundleID = finderBundleID
        let status: OSStatus = bundleID.withCString { ptr in
            AECreateDesc(typeApplicationBundleID, ptr, strlen(ptr), &target)
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        }
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .finderNotRunning
        default: return .unknown
        }
    }
}
