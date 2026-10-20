import Foundation

/// A pluggable converter. Providers are stateless value types; heavy resources are
/// created lazily inside `convert` so registering a provider costs nothing at launch.
public protocol ConversionProvider: Sendable {
    var id: String { get }

    /// The paths this provider can perform given which optional tools are installed.
    func capabilities(tools: ToolAvailability) -> [ConversionCapability]

    /// File-specific caveats, computed before conversion so the UI can warn first.
    func caveats(for facts: FileFacts, to output: FileFormat, options: ConversionOptions) -> [Caveat]

    /// Performs the conversion, writing only inside `job.workDirectory`.
    /// Must honour task cancellation and report progress in 0...1.
    func convert(_ job: ConversionJob, progress: ProgressHandler) async throws -> ProviderResult
}

public extension ConversionProvider {
    func caveats(for facts: FileFacts, to output: FileFormat, options: ConversionOptions) -> [Caveat] { [] }
}

/// Which optional external tools are present. Injected so tests are deterministic.
public struct ToolAvailability: Sendable, Equatable {
    public var paths: [ExternalTool: URL]

    public init(paths: [ExternalTool: URL] = [:]) { self.paths = paths }

    public func has(_ tool: ExternalTool) -> Bool { paths[tool] != nil }
    public func path(_ tool: ExternalTool) -> URL? { paths[tool] }

    public static let none = ToolAvailability()
}
