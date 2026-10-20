import Foundation

/// Every failure Forma can surface. Messages are written for people, not engineers.
public enum FormaError: Error, Equatable, Sendable {
    case unsupportedInput(String)
    case unsupportedConversion(from: FileFormat, to: FileFormat)
    case unreadable(String)
    case corrupted(String)
    case passwordProtected(String)
    case missingTool(ExternalTool)
    case toolFailed(ExternalTool, String)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case destinationNotWritable(URL)
    case fileNotFound(URL)
    case imageTooLarge(width: Int, height: Int)
    case encodeFailed(FileFormat)
    case noTextFound
    case cancelled
    case nothingSelected
    case underlying(String)

    public var title: String {
        switch self {
        case .cancelled: "Conversion cancelled"
        case .nothingSelected: "Nothing selected"
        case .missingTool: "Extra component needed"
        default: "Couldn't convert"
        }
    }
}

extension FormaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedInput(let name):
            "Forma doesn't know how to read “\(name)”."
        case .unsupportedConversion(let from, let to):
            "Forma can't convert \(from.displayName) files to \(to.displayName)."
        case .unreadable(let name):
            "Couldn't read “\(name)”. Make sure the file still exists and that Forma has access to it."
        case .corrupted(let name):
            "Couldn't convert “\(name)” because the file appears to be damaged or isn't what its extension says."
        case .passwordProtected(let name):
            "Couldn't convert “\(name)” because it is password protected."
        case .missingTool(let tool):
            "This conversion needs \(tool.displayName), which isn't installed. See Settings › Integrations."
        case .toolFailed(let tool, let detail):
            "\(tool.displayName) couldn't convert this file." + (detail.isEmpty ? "" : " \(detail)")
        case .insufficientDiskSpace(let needed, let available):
            "There isn't enough free space. About \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) is needed, but only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available."
        case .destinationNotWritable(let url):
            "Forma can't save into “\(url.lastPathComponent)”. Choose another location in Settings, or turn on “Ask where to save”."
        case .fileNotFound(let url):
            "“\(url.lastPathComponent)” no longer exists."
        case .imageTooLarge(let w, let h):
            "This image is too large to process (\(w) × \(h) pixels). Try setting a maximum size."
        case .encodeFailed(let format):
            "macOS couldn't write a \(format.displayName) file from this content."
        case .noTextFound:
            "No text could be found in this document."
        case .cancelled:
            "The conversion was cancelled. No files were changed."
        case .nothingSelected:
            "Select one or more files in Finder first."
        case .underlying(let message):
            message
        }
    }
}

extension FormaError {
    /// Maps arbitrary errors into user-facing ones, recognising common POSIX/Cocoa causes.
    public static func wrap(_ error: Error) -> FormaError {
        if let e = error as? FormaError { return e }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) {
            return .insufficientDiskSpace(needed: 0, available: 0)
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError:
                return .insufficientDiskSpace(needed: 0, available: 0)
            case NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
                if let url = ns.userInfo[NSURLErrorKey] as? URL { return .destinationNotWritable(url.deletingLastPathComponent()) }
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                if let url = ns.userInfo[NSURLErrorKey] as? URL { return .fileNotFound(url) }
            case NSUserCancelledError:
                return .cancelled
            default: break
            }
        }
        return .underlying(ns.localizedDescription)
    }
}
