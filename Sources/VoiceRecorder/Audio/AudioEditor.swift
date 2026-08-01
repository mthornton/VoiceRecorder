import AVFoundation
import Foundation

enum AudioEditError: LocalizedError {
    case noAudioTrack
    case nothingWouldRemain
    case compositionFailed(String)
    case encodingFailed(String)
    case replaceFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "The recording has no audio track."
        case .nothingWouldRemain:
            return "That would remove the entire recording. Delete it instead."
        case .compositionFailed(let detail):
            return "Couldn't assemble the edited audio. \(detail)"
        case .encodingFailed(let detail):
            return "Couldn't write the edited audio. \(detail)"
        case .replaceFailed(let detail):
            return "Couldn't replace the original recording. \(detail)"
        }
    }
}

/// Permanently removes time ranges from a recording.
///
/// This is destructive on purpose — the feature exists so sensitive audio stops
/// existing. The edited file replaces the original, and no copy of the removed
/// audio is kept anywhere.
enum AudioEditor {
    /// Extra audio trimmed either side of every removed range.
    ///
    /// Alignment is accurate to well under a second but not to the sample, and
    /// the safe direction to err is *more* removal: clipping a syllable off a
    /// neighbouring word is a far better outcome than leaving the tail of the
    /// thing the user wanted gone.
    static let safetyMargin: TimeInterval = 0.2

    struct Result: Sendable {
        /// Duration of the audio that remains.
        let newDuration: TimeInterval
        /// The ranges actually cut, after padding and merging. Callers need
        /// these to shift surviving timestamps onto the new timeline.
        let removed: [ClosedRange<TimeInterval>]

        var removedDuration: TimeInterval {
            removed.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        }
    }

    /// Cuts `ranges` out of the file at `url`, replacing it in place.
    static func removeRanges(_ ranges: [ClosedRange<TimeInterval>], from url: URL) async throws -> Result {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw AudioEditError.noAudioTrack
        }

        let total = try await asset.load(.duration).seconds
        let removals = normalize(ranges, totalDuration: total)
        guard !removals.isEmpty else {
            return Result(newDuration: total, removed: [])
        }

        let keeps = complement(of: removals, totalDuration: total)
        guard !keeps.isEmpty else { throw AudioEditError.nothingWouldRemain }

        let composition = try await buildComposition(from: asset, keeping: keeps)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("redacted-\(UUID().uuidString).m4a")

        do {
            try await encode(composition, to: temporaryURL)
            try replaceFile(at: url, with: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        return Result(
            newDuration: keeps.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) },
            removed: removals
        )
    }

    /// Maps a timestamp on the original timeline onto the edited one.
    ///
    /// A time that fell inside a removed range collapses to where that range
    /// started, which is where the audio now joins up.
    static func shift(_ time: TimeInterval, removals: [ClosedRange<TimeInterval>]) -> TimeInterval {
        var shifted = time
        for removal in removals {
            if time >= removal.upperBound {
                shifted -= (removal.upperBound - removal.lowerBound)
            } else if time > removal.lowerBound {
                shifted -= (time - removal.lowerBound)
            }
        }
        return max(shifted, 0)
    }

    // MARK: - Range maths

    /// Applies the safety margin, clamps to the file, and merges overlapping or
    /// touching ranges so the composition sees a clean, ordered set.
    static func normalize(
        _ ranges: [ClosedRange<TimeInterval>],
        totalDuration: TimeInterval
    ) -> [ClosedRange<TimeInterval>] {
        let padded = ranges.compactMap { range -> ClosedRange<TimeInterval>? in
            let lower = max(range.lowerBound - safetyMargin, 0)
            let upper = min(range.upperBound + safetyMargin, totalDuration)
            guard upper > lower else { return nil }
            return lower...upper
        }.sorted { $0.lowerBound < $1.lowerBound }

        var merged: [ClosedRange<TimeInterval>] = []
        for range in padded {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The spans left over once the removals are taken out.
    static func complement(
        of removals: [ClosedRange<TimeInterval>],
        totalDuration: TimeInterval
    ) -> [ClosedRange<TimeInterval>] {
        var keeps: [ClosedRange<TimeInterval>] = []
        var cursor: TimeInterval = 0

        for removal in removals {
            if removal.lowerBound > cursor {
                keeps.append(cursor...removal.lowerBound)
            }
            cursor = max(cursor, removal.upperBound)
        }
        if cursor < totalDuration {
            keeps.append(cursor...totalDuration)
        }

        // Discard slivers that would produce empty or unplayable segments.
        return keeps.filter { $0.upperBound - $0.lowerBound > 0.05 }
    }

    // MARK: - Composition and encoding

    private static func buildComposition(
        from asset: AVURLAsset,
        keeping keeps: [ClosedRange<TimeInterval>]
    ) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioEditError.compositionFailed("Could not create an audio track.")
        }

        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioEditError.noAudioTrack
        }

        var cursor = CMTime.zero
        for keep in keeps {
            let start = CMTime(seconds: keep.lowerBound, preferredTimescale: 44_100)
            let duration = CMTime(seconds: keep.upperBound - keep.lowerBound, preferredTimescale: 44_100)
            do {
                try track.insertTimeRange(
                    CMTimeRange(start: start, duration: duration),
                    of: sourceTrack,
                    at: cursor
                )
            } catch {
                throw AudioEditError.compositionFailed(error.localizedDescription)
            }
            cursor = cursor + duration
        }

        return composition
    }

    /// Re-encodes at the capture settings so an edited recording is
    /// indistinguishable in format from one that was never touched.
    private static func encode(_ composition: AVMutableComposition, to outputURL: URL) async throws {
        nonisolated(unsafe) let reader: AVAssetReader
        nonisolated(unsafe) let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: composition)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        } catch {
            throw AudioEditError.encodingFailed(error.localizedDescription)
        }

        let tracks = try await composition.loadTracks(withMediaType: .audio)

        nonisolated(unsafe) let readerOutput = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 44_100.0,
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
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
        )
        writerInput.expectsMediaDataInRealTime = false

        guard reader.canAdd(readerOutput), writer.canAdd(writerInput) else {
            throw AudioEditError.encodingFailed("The audio format isn't supported.")
        }
        reader.add(readerOutput)
        writer.add(writerInput)

        guard reader.startReading() else {
            throw AudioEditError.encodingFailed(reader.error?.localizedDescription ?? "Reader failed to start.")
        }
        guard writer.startWriting() else {
            throw AudioEditError.encodingFailed(writer.error?.localizedDescription ?? "Writer failed to start.")
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "com.michaelthornton.VoiceRecorder.redact")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
                            continuation.resume(throwing: AudioEditError.encodingFailed(message))
                            return
                        }
                    } else {
                        finished = true
                        writerInput.markAsFinished()

                        if reader.status == .failed {
                            let message = reader.error?.localizedDescription ?? "Reading failed."
                            continuation.resume(throwing: AudioEditError.encodingFailed(message))
                            return
                        }

                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                let message = writer.error?.localizedDescription ?? "Writing failed."
                                continuation.resume(throwing: AudioEditError.encodingFailed(message))
                            }
                        }
                        return
                    }
                }
            }
        }
    }

    /// Swaps the edited file in and destroys the original.
    ///
    /// `replaceItemAt` is atomic, so a crash mid-write leaves either the old
    /// file or the new one, never a truncated file — and the original's bytes
    /// are gone once it returns.
    private static func replaceFile(at url: URL, with temporaryURL: URL) throws {
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        } catch {
            throw AudioEditError.replaceFailed(error.localizedDescription)
        }
    }
}
