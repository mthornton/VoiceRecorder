import Foundation
import Observation
import SwiftData

enum RedactionError: LocalizedError {
    case noSegments
    case alignmentFailed
    case nothingSelected

    var errorDescription: String? {
        switch self {
        case .noSegments:
            return "This recording has no transcript segments to remove."
        case .alignmentFailed:
            return "Couldn't work out exactly where those words are in the audio, so nothing was removed. "
                + "Re-transcribing the recording may fix it."
        case .nothingSelected:
            return "No segments were selected."
        }
    }
}

/// Permanently removes selected segments from both the transcript and the audio.
///
/// The point of this feature is that sensitive content stops existing, so it is
/// deliberately destructive: the audio file is rewritten in place, the segment
/// text is deleted, and nothing is retained that would allow recovery. Only the
/// counts of what was removed survive, so the UI can disclose that the recording
/// is no longer complete.
@MainActor
@Observable
final class RedactionService {
    enum Phase: Equatable {
        case idle
        case aligning
        case cuttingAudio

        var message: String? {
            switch self {
            case .idle: return nil
            case .aligning: return "Locating those words in the audio…"
            case .cuttingAudio: return "Removing audio…"
            }
        }
    }

    private(set) var phase: Phase = .idle

    private let transcriber: TranscriptionProvider

    init(transcriber: TranscriptionProvider = OnDeviceTranscriber()) {
        self.transcriber = transcriber
    }

    var isWorking: Bool { phase != .idle }

    /// Removes `indices` from the recording, cutting the corresponding audio.
    func redact(
        _ recording: Recording,
        indices: Set<Int>,
        context: ModelContext
    ) async throws {
        guard !indices.isEmpty else { throw RedactionError.nothingSelected }

        let segments = recording.segments
        guard !segments.isEmpty else { throw RedactionError.noSegments }

        let selected = indices.filter { $0 >= 0 && $0 < segments.count }
        guard !selected.isEmpty else { throw RedactionError.nothingSelected }

        defer { phase = .idle }

        // Estimated timings must never drive a cut — see SegmentTimingSource.
        var working = segments
        if recording.needsAlignmentBeforeRedaction {
            phase = .aligning
            guard let aligned = try await alignedSegments(for: recording, segments: segments) else {
                throw RedactionError.alignmentFailed
            }
            working = aligned
            recording.segments = aligned
            recording.timingSourceRaw = SegmentTimingSource.aligned.rawValue
            try? context.save()
        }

        let ranges = selected
            .sorted()
            .map { working[$0].start...max(working[$0].end, working[$0].start) }

        phase = .cuttingAudio
        let result = try await AudioEditor.removeRanges(ranges, from: recording.audioURL)

        apply(result, removing: selected, to: recording, segments: working)
        try? context.save()
    }

    // MARK: - Alignment

    /// Transcribes the audio again with the on-device engine purely to obtain
    /// real time ranges, then maps the speaker segments onto them.
    private func alignedSegments(
        for recording: Recording,
        segments: [TranscriptSegment]
    ) async throws -> [TranscriptSegment]? {
        let reference = try await transcriber.transcribe(fileURL: recording.audioURL)
        return TranscriptAligner.align(segments: segments, reference: reference.segments)
    }

    // MARK: - Applying the edit

    /// Rewrites the model onto the shortened timeline.
    private func apply(
        _ result: AudioEditor.Result,
        removing selected: Set<Int>,
        to recording: Recording,
        segments: [TranscriptSegment]
    ) {
        // Surviving segments keep their text but move earlier, by however much
        // audio was cut ahead of them.
        var survivors: [TranscriptSegment] = []
        for (index, segment) in segments.enumerated() where !selected.contains(index) {
            var moved = segment
            moved.start = AudioEditor.shift(segment.start, removals: result.removed)
            moved.end = max(AudioEditor.shift(segment.end, removals: result.removed), moved.start)
            survivors.append(moved)
        }

        recording.segments = survivors
        recording.transcript = TranscriptComposer.compose(survivors)
        recording.duration = result.newDuration

        recording.redactedSegmentCount += selected.count
        recording.redactedDuration += result.removedDuration

        if recording.hasSummary {
            recording.summaryNeedsRefresh = true
        }
    }
}
