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
                + "Cutting on a guess could leave the sensitive part in the recording.\n\n"
                + "You can switch to the on-device transcript, which has exact timings. "
                + "You'll lose the speaker labels."
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

    /// The on-device transcription produced during a failed alignment attempt.
    ///
    /// Kept so a refusal isn't a dead end: the user can adopt this transcript,
    /// which has exact timings, and redact from it. Re-running transcription to
    /// offer that would waste the minutes we already spent.
    private(set) var fallbackTranscript: TranscriptionResult?

    private let transcriber: TranscriptionProvider

    init(transcriber: TranscriptionProvider = OnDeviceTranscriber()) {
        self.transcriber = transcriber
    }

    var isWorking: Bool { phase != .idle }

    var canOfferFallback: Bool { fallbackTranscript != nil }

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
        fallbackTranscript = nil

        // Estimated timings must never drive a cut — see SegmentTimingSource.
        var working = segments
        if recording.needsAlignmentBeforeRedaction {
            phase = .aligning

            let reference = try await transcriber.transcribe(fileURL: recording.audioURL)
            guard let aligned = TranscriptAligner.align(
                segments: segments,
                reference: reference.segments
            ) else {
                // Hold onto the on-device transcript so the UI can offer it as a
                // way forward instead of leaving the user stuck.
                fallbackTranscript = reference
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

    // MARK: - Fallback

    /// Replaces the recording's transcript with the on-device one captured
    /// during a failed alignment.
    ///
    /// Speaker labels are lost, which is a real cost — but the on-device timings
    /// are exact, so redaction becomes possible. For a feature whose whole point
    /// is removing sensitive audio, being able to cut accurately beats knowing
    /// who said it.
    func adoptFallbackTranscript(_ recording: Recording, context: ModelContext) {
        guard let fallback = fallbackTranscript else { return }

        recording.transcript = fallback.text
        recording.segments = fallback.segments
        recording.transcriptionEngineRaw = fallback.engine.rawValue
        recording.timingSourceRaw = SegmentTimingSource.exact.rawValue
        if recording.hasSummary {
            recording.summaryNeedsRefresh = true
        }

        fallbackTranscript = nil
        try? context.save()
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
