import Foundation

/// Knows every provider and answers "what can this file become, and who does it?".
///
/// Direct conversions are always preferred. A two-step path is offered only when
/// no direct path exists, the first hop is lossless, and the trade-off is disclosed.
public struct ConversionRegistry: Sendable {
    public let providers: [any ConversionProvider]
    public let tools: ToolAvailability
    private let table: [FileFormat: [FileFormat: ConversionCapability]]

    public init(providers: [any ConversionProvider], tools: ToolAvailability) {
        self.providers = providers
        self.tools = tools
        var direct: [FileFormat: [FileFormat: ConversionCapability]] = [:]
        for provider in providers {
            for cap in provider.capabilities(tools: tools) where cap.input != cap.output {
                if let existing = direct[cap.input]?[cap.output], existing.priority <= cap.priority { continue }
                direct[cap.input, default: [:]][cap.output] = cap
            }
        }
        // Compose two-step paths for gaps, never through a lossy or rasterizing first hop.
        var composed = direct
        for (input, outs) in direct {
            for (mid, first) in outs where first.isLossless && first.editability != .rasterized && first.requiredTool == nil {
                for (output, second) in direct[mid] ?? [:] where output != input && direct[input]?[output] == nil && composed[input]?[output] == nil {
                    var cap = second
                    cap.input = input
                    cap.via = mid
                    cap.isLossless = first.isLossless && second.isLossless
                    cap.preservesMetadata = first.preservesMetadata && second.preservesMetadata
                    cap.priority = first.priority + second.priority + 1000
                    cap.notes = first.notes + second.notes + [.info("Converted via \(mid.displayName).")]
                    composed[input, default: [:]][output] = cap
                }
            }
        }
        self.table = composed
    }

    /// All outputs reachable from `input`, best capability per output.
    public func destinations(for input: FileFormat) -> [ConversionCapability] {
        (table[input] ?? [:]).values.sorted { $0.output.rawValue < $1.output.rawValue }
    }

    public func capability(from input: FileFormat, to output: FileFormat) -> ConversionCapability? {
        table[input]?[output]
    }

    public func canConvert(_ input: FileFormat, to output: FileFormat) -> Bool {
        capability(from: input, to: output) != nil
    }

    public func provider(id: String) -> (any ConversionProvider)? {
        providers.first { $0.id == id }
    }

    /// Outputs every given input format can reach — used for multi-file selections.
    public func commonDestinations(for inputs: [FileFormat]) -> Set<FileFormat> {
        guard let first = inputs.first else { return [] }
        var set = Set(destinations(for: first).map(\.output))
        for f in inputs.dropFirst() { set.formIntersection(destinations(for: f).map(\.output)) }
        return set
    }

    /// Outputs that at least one input can reach (the rest get skipped with a report).
    public func anyDestinations(for inputs: [FileFormat]) -> Set<FileFormat> {
        Set(inputs.flatMap { destinations(for: $0).map(\.output) })
    }

    public func caveats(for facts: FileFacts, to output: FileFormat, options: ConversionOptions) -> [Caveat] {
        guard let cap = capability(from: facts.format, to: output) else { return [] }
        var result = cap.notes
        if let via = cap.via, let p1 = providers.first(where: { $0.capabilities(tools: tools).contains { $0.input == facts.format && $0.output == via } }) {
            result += p1.caveats(for: facts, to: via, options: options)
        } else if let p = provider(id: cap.providerID) {
            result += p.caveats(for: facts, to: output, options: options)
        }
        // De-duplicate while keeping order.
        var seen = Set<Caveat>()
        return result.filter { seen.insert($0).inserted }
    }

    /// Standard set of built-in providers plus any external-tool providers that are usable.
    public static func standard(tools: ToolAvailability) -> ConversionRegistry {
        ConversionRegistry(providers: [
            ImageConversionProvider(),
            PDFConversionProvider(),
            DocumentConversionProvider(),
            AudioConversionProvider(),
            LibreOfficeConversionProvider(),
            FFmpegConversionProvider(),
            WebPEncoderProvider(),
        ], tools: tools)
    }
}
