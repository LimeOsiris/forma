import AudioToolbox
import AVFoundation
import Foundation

/// Genuine audio transcoding with AVFoundation: decode to PCM, re-encode with the
/// target codec. Also extracts audio from movies and rewraps MOV ⇄ MP4 losslessly.
public struct AudioConversionProvider: ConversionProvider {
    public let id = "audio"
    public init() {}

    static let audioInputs: [FileFormat] = [.m4a, .wav, .aiff, .caf, .mp3, .flac, .aac, .mov, .mp4]

    /// Encoders available on this Mac (FLAC encoding depends on the OS version).
    static func audioOutputs() -> [FileFormat] {
        var outs: [FileFormat] = [.m4a, .wav, .aiff, .caf]
        if encoderAvailable(kAudioFormatFLAC) { outs.append(.flac) }
        return outs
    }

    static func encoderAvailable(_ format: AudioFormatID) -> Bool {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        guard AudioFormatGetProperty(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size, &ids) == noErr else { return false }
        return ids.contains(format)
    }

    public func capabilities(tools: ToolAvailability) -> [ConversionCapability] {
        var caps: [ConversionCapability] = []
        let outs = Self.audioOutputs()
        for input in Self.audioInputs {
            for output in outs where output != input {
                let lossless = output != .m4a && !input.isLossyByNature
                caps.append(ConversionCapability(
                    input: input, output: output, providerID: id,
                    isLossless: lossless, preservesMetadata: false, editability: .viewOnly, priority: 20,
                    notes: input.category == .video ? [.info("Only the audio track is kept.")] : []
                ))
            }
        }
        caps.append(ConversionCapability(input: .mov, output: .mp4, providerID: id, isLossless: true, preservesMetadata: true,
                                         editability: .viewOnly, priority: 20, notes: [.info("Rewraps the streams without re-encoding when possible.")]))
        caps.append(ConversionCapability(input: .mp4, output: .mov, providerID: id, isLossless: true, preservesMetadata: true,
                                         editability: .viewOnly, priority: 20, notes: [.info("Rewraps the streams without re-encoding.")]))
        return caps
    }

    public func caveats(for facts: FileFacts, to output: FileFormat, options: ConversionOptions) -> [Caveat] {
        var r: [Caveat] = []
        if facts.format.isLossyByNature && !output.isLossyByNature && output.category == .audio {
            r.append(.info("The source is already compressed; a lossless copy won't restore lost detail but will be larger."))
        }
        if output == .m4a { r.append(.info("Encoded as AAC at 256 kbps.")) }
        return r
    }

    public func convert(_ job: ConversionJob, progress: ProgressHandler) async throws -> ProviderResult {
        let url = job.defaultOutputURL
        if job.output.category == .video {
            let caveats = try await rewrap(job.input, to: url, fileType: job.output == .mp4 ? .mp4 : .mov)
            progress(1)
            return ProviderResult(files: [url], caveats: caveats)
        }
        try await transcode(job.input, to: url, format: job.output, progress: progress)
        return ProviderResult(files: [url])
    }

    // MARK: - Transcoding

    func transcode(_ input: URL, to output: URL, format: FileFormat, progress: ProgressHandler) async throws {
        let asset = AVURLAsset(url: input)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .audio) } catch { throw FormaError.corrupted(input.lastPathComponent) }
        guard let track = tracks.first else {
            throw FormaError.underlying("“\(input.lastPathComponent)” doesn't contain an audio track.")
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        guard let asbd = descriptions.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) else {
            throw FormaError.corrupted(input.lastPathComponent)
        }
        var sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
        let channels = max(1, min(Int(asbd.mChannelsPerFrame), format == .m4a ? 2 : 8))
        if format == .m4a { sampleRate = min(sampleRate, 48_000) }

        let sourceBits: Int = {
            if asbd.mFormatID == kAudioFormatLinearPCM { return max(16, min(32, Int(asbd.mBitsPerChannel))) }
            if asbd.mFormatID == kAudioFormatFLAC || asbd.mFormatID == kAudioFormatAppleLossless { return 24 }
            return 16
        }()
        let pcmBits = sourceBits >= 24 ? 24 : 16

        let settings: [String: Any]
        switch format {
        case .wav, .caf:
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                        AVLinearPCMBitDepthKey: pcmBits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        case .aiff:
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                        AVLinearPCMBitDepthKey: pcmBits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsNonInterleaved: false]
        case .flac:
            settings = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                        AVEncoderBitDepthHintKey: pcmBits]
        case .m4a:
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                        AVEncoderBitRateKey: channels == 1 ? 128_000 : 256_000]
        default:
            throw FormaError.unsupportedConversion(from: FileFormat.from(extension: input.pathExtension) ?? .m4a, to: format)
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw FormaError.corrupted(input.lastPathComponent) }
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw FormaError.corrupted(input.lastPathComponent) }
        reader.add(readerOutput)
        guard reader.startReading() else { throw FormaError.corrupted(input.lastPathComponent) }
        defer { if reader.status == .reading { reader.cancelReading() } }

        guard let processing = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: true) else {
            throw FormaError.encodeFailed(format)
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        } catch {
            throw FormaError.encodeFailed(format)
        }

        var written: Double = 0
        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            // The buffer list advertises frameLength bytes, so size it before copying in.
            buffer.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            guard status == noErr else { throw FormaError.corrupted(input.lastPathComponent) }
            do { try file.write(from: buffer) } catch { throw FormaError.encodeFailed(format) }
            written += Double(frames) / sampleRate
            if duration > 0 { progress(min(0.99, written / duration)) }
        }
        if reader.status == .failed { throw FormaError.corrupted(input.lastPathComponent) }
        progress(1)
    }

    // MARK: - Rewrap

    func rewrap(_ input: URL, to output: URL, fileType: AVFileType) async throws -> [Caveat] {
        let asset = AVURLAsset(url: input)
        var caveats: [Caveat] = []
        var preset = AVAssetExportPresetPassthrough
        if !(await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType)) {
            preset = AVAssetExportPresetHighestQuality
            caveats.append(.info("The streams couldn't be copied as-is, so the video was re-encoded."))
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw FormaError.encodeFailed(fileType == .mp4 ? .mp4 : .mov) }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = fileType == .mp4
        let box = UncheckedBox(session)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                box.value.exportAsynchronously { c.resume() }
            }
        } onCancel: {
            box.value.cancelExport()
        }
        try Task.checkCancellation()
        switch session.status {
        case .completed: return caveats
        case .cancelled: throw FormaError.cancelled
        default: throw FormaError.underlying(session.error?.localizedDescription ?? "The movie couldn't be exported.")
        }
    }
}
