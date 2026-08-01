import AVFoundation
import Foundation

/// A re-encoded slice of a recording, ready to upload.
struct AudioChunk: Sendable {
    let url: URL
    let index: Int
    let start: TimeInterval
    let duration: TimeInterval
}

enum AudioTranscodeError: LocalizedError {
    case noAudioTrack
    case encoderSetupFailed(String)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "The recording has no audio track."
        case .encoderSetupFailed(let detail):
            return "Couldn't prepare the audio for upload. \(detail)"
        case .encodingFailed(let detail):
            return "Couldn't encode the audio for upload. \(detail)"
        }
    }
}

/// Re-encodes recorded audio down to an upload-friendly size and splits it into
/// chunks that fit comfortably in a single request body.
///
/// Two problems are being solved here. Audio has to be base64-encoded inline in
/// the JSON request, which inflates it by ~33%: an hour at the capture bitrate
/// would be a ~39 MB body. And speech recognition gains nothing from the capture
/// quality — 16 kHz mono at 24 kbps is the standard telephony-grade envelope that
/// speech models are trained on, and it cuts an hour to roughly 11 MB before
/// encoding, ~4 MB per chunk after splitting.
enum AudioTranscoder {
    /// Chunk length. Fifteen minutes keeps each request body a few MB while
    /// keeping the number of round trips (and speaker-continuity seams) low.
    static let chunkDuration: TimeInterval = 15 * 60

    static let uploadFormat = "m4a"

    private static let sampleRate = 16_000.0
    private static let bitRate = 24_000

    /// Produces one or more chunks in a temporary directory. The caller owns
    /// them and must call `cleanUp` when finished.
    static func prepareForUpload(sourceURL: URL) async throws -> [AudioChunk] {
        let asset = AVURLAsset(url: sourceURL)

        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw AudioTranscodeError.noAudioTrack
        }

        let total = try await asset.load(.duration).seconds
        guard total.isFinite, total > 0 else {
            throw AudioTranscodeError.noAudioTrack
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var chunks: [AudioChunk] = []
        var start: TimeInterval = 0
        var index = 0

        while start < total {
            let duration = min(chunkDuration, total - start)
            // A sliver at the tail is not worth a round trip; it gets dropped
            // rather than sent as a near-empty request.
            if duration < 0.5 { break }

            let output = directory.appendingPathComponent("chunk-\(index).m4a")
            try await encode(asset: asset, to: output, start: start, duration: duration)

            chunks.append(AudioChunk(url: output, index: index, start: start, duration: duration))
            start += duration
            index += 1
        }

        guard !chunks.isEmpty else {
            throw AudioTranscodeError.noAudioTrack
        }
        return chunks
    }

    static func cleanUp(_ chunks: [AudioChunk]) {
        guard let directory = chunks.first?.url.deletingLastPathComponent() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Encoding

    private static func encode(
        asset: AVURLAsset,
        to outputURL: URL,
        start: TimeInterval,
        duration: TimeInterval
    ) async throws {
        // AVFoundation's reader and writer aren't Sendable, but the pump below
        // hands them to a single serial queue and this function awaits its
        // completion before returning — so only one thread ever touches them,
        // and none of them outlive this call.
        nonisolated(unsafe) let reader: AVAssetReader
        nonisolated(unsafe) let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        } catch {
            throw AudioTranscodeError.encoderSetupFailed(error.localizedDescription)
        }

        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )

        let tracks = try await asset.loadTracks(withMediaType: .audio)

        // The reader decompresses to PCM at the target rate; the writer then
        // encodes that to AAC. Going compressed-to-compressed directly isn't
        // supported, so PCM in the middle is required, not incidental.
        nonisolated(unsafe) let readerOutput = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )

        nonisolated(unsafe) let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ]
        )
        writerInput.expectsMediaDataInRealTime = false

        guard reader.canAdd(readerOutput), writer.canAdd(writerInput) else {
            throw AudioTranscodeError.encoderSetupFailed("The audio format isn't supported.")
        }
        reader.add(readerOutput)
        writer.add(writerInput)

        guard reader.startReading() else {
            throw AudioTranscodeError.encodingFailed(reader.error?.localizedDescription ?? "Reader failed to start.")
        }
        guard writer.startWriting() else {
            throw AudioTranscodeError.encodingFailed(writer.error?.localizedDescription ?? "Writer failed to start.")
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "com.michaelthornton.VoiceRecorder.transcode")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // `requestMediaDataWhenReady` calls back repeatedly as the encoder
            // drains; the continuation is resumed exactly once, on completion or
            // first failure.
            nonisolated(unsafe) var finished = false

            writerInput.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }

                while writerInput.isReadyForMoreMediaData {
                    guard reader.status == .reading else { break }

                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(buffer) {
                            finished = true
                            reader.cancelReading()
                            writerInput.markAsFinished()
                            let message = writer.error?.localizedDescription ?? "Encoder rejected a sample."
                            continuation.resume(throwing: AudioTranscodeError.encodingFailed(message))
                            return
                        }
                    } else {
                        finished = true
                        writerInput.markAsFinished()

                        if reader.status == .failed {
                            let message = reader.error?.localizedDescription ?? "Reading failed."
                            continuation.resume(throwing: AudioTranscodeError.encodingFailed(message))
                            return
                        }

                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                let message = writer.error?.localizedDescription ?? "Writing failed."
                                continuation.resume(throwing: AudioTranscodeError.encodingFailed(message))
                            }
                        }
                        return
                    }
                }
            }
        }
    }
}
