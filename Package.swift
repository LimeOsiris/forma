// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Command Line Tools ship Swift Testing outside the default search path; Xcode doesn't need this.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingFlags: [String] = FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework") ? ["-F", cltFrameworks] : []
let testingLinkFlags: [String] = testingFlags.isEmpty ? [] : ["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                                                              "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"]

let package = Package(
    name: "Forma",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FormaCore", targets: ["FormaCore"]),
        .executable(name: "Forma", targets: ["Forma"]),
    ],
    targets: [
        // Conversion engine, file detection, planning. No UI; fully unit-testable.
        .target(
            name: "FormaCore",
            path: "Sources/FormaCore"
        ),
        // The macOS app: menu bar agent, radial wheel, editors, Finder entry points.
        .executableTarget(
            name: "Forma",
            dependencies: ["FormaCore"],
            path: "Sources/Forma"
        ),
        .testTarget(
            name: "FormaCoreTests",
            dependencies: ["FormaCore"],
            path: "Tests/FormaCoreTests",
            swiftSettings: [.unsafeFlags(testingFlags)],
            linkerSettings: [.unsafeFlags(testingLinkFlags)]
        ),
        // Same tests as an executable: `swift run FormaTestRunner` (works with Command Line Tools only).
        .executableTarget(
            name: "FormaTestRunner",
            dependencies: ["FormaCore"],
            path: "Tests/FormaTestRunner",
            swiftSettings: [.unsafeFlags(testingFlags)],
            linkerSettings: [.unsafeFlags(testingLinkFlags)]
        ),
    ]
)
