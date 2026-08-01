import Foundation
import SwiftData

/// Where a recording sits in the capture → transcribe → summarize pipeline.
///
/// The failure cases are deliberately recoverable: audio and any transcript we
/// already produced survive them, so the UI can offer a retry that resumes from
/// the failed stage instead of starting over.
enum RecordingStatus: String, Codable, CaseIterable {
    case recording
    case recorded
    case transcribing
    case transcribed
    case summarizing
    case complete
    case transcriptionFailed
    case summarizationFailed

    var isWorking: Bool {
        self == .transcribing || self == .summarizing
    }

    var isFailure: Bool {
        self == .transcriptionFailed || self == .summarizationFailed
    }

    var label: String {
        switch self {
        case .recording: return "Recording"
        case .recorded: return "Waiting to transcribe"
        case .transcribing: return "Transcribing"
        case .transcribed: return "Transcribed"
        case .summarizing: return "Summarizing"
        case .complete: return "Complete"
        case .transcriptionFailed: return "Transcription failed"
        case .summarizationFailed: return "Summary failed"
        }
    }
}

@Model
final class Recording {
    /// SwiftData needs a stable identity that survives across launches; the
    /// audio file on disk is named from this.
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()
    var duration: TimeInterval = 0

    /// Stored as a bare filename, not a URL. The app container's path changes
    /// between installs and OS upgrades, so an absolute URL persisted today can
    /// dangle tomorrow. `audioURL` resolves it against the current container.
    var audioFileName: String = ""

    private var statusRaw: String = RecordingStatus.recorded.rawValue
    var status: RecordingStatus {
        get { RecordingStatus(rawValue: statusRaw) ?? .recorded }
        set { statusRaw = newValue.rawValue }
    }

    var transcript: String?

    /// Speaker-attributed turns, JSON-encoded. Stored alongside `transcript`
    /// rather than replacing it: the flat text is what search and summarization
    /// consume, while the segments drive the speaker view.
    var segmentsData: Data?

    /// Which engine produced `transcript`. Optional because it's unknown for
    /// recordings made before engines were tracked, and because the current
    /// setting is not evidence of what actually ran.
    var transcriptionEngineRaw: String?

    /// Positions in `segments` the user has removed.
    ///
    /// Exclusion is reversible by design: the segment text stays on disk so it
    /// can be restored, and the audio is never modified. Indices are stable
    /// because `segments` is written once by transcription and not mutated
    /// afterwards — re-transcribing clears this along with the transcript.
    var excludedSegmentIndices: [Int] = []

    /// Set when exclusions change after a summary already exists, so the UI can
    /// say the summary no longer reflects the transcript rather than presenting
    /// a stale one as current.
    var summaryNeedsRefresh: Bool = false

    var summaryMarkdown: String?
    var keyPoints: [String] = []
    var actionItems: [String] = []

    /// Which template and model produced the current summary, so the detail
    /// view can show what it used and regenerate with something else.
    var templateID: String = SummaryTemplate.meeting.id
    var modelID: String?

    var errorMessage: String?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        audioFileName: String,
        status: RecordingStatus = .recorded,
        templateID: String = SummaryTemplate.meeting.id
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.statusRaw = status.rawValue
        self.templateID = templateID
    }
}

extension Recording {
    var audioURL: URL {
        AudioStorage.recordingsDirectory.appendingPathComponent(audioFileName)
    }

    var hasTranscript: Bool {
        !(transcript ?? "").isEmpty
    }

    var transcriptionEngine: TranscriptionEngine? {
        transcriptionEngineRaw.flatMap(TranscriptionEngine.init(rawValue:))
    }

    var segments: [TranscriptSegment] {
        get {
            guard let segmentsData else { return [] }
            return (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? []
        }
        set {
            segmentsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    /// True only when the engine that ran could actually distinguish speakers
    /// *and* produced more than one. A two-hour monologue transcribed by the
    /// speaker-aware engine has no speakers worth showing.
    var hasSpeakerLabels: Bool {
        distinctSpeakers.count > 1
    }

    /// Speakers still present after removals — a speaker whose every segment was
    /// removed shouldn't linger in the legend.
    var distinctSpeakers: [String] {
        var seen: [String] = []
        for speaker in includedSegments.compactMap(\.speaker) where !seen.contains(speaker) {
            seen.append(speaker)
        }
        return seen
    }

    // MARK: - Removal

    var excludedIndexSet: Set<Int> {
        Set(excludedSegmentIndices)
    }

    var hasExclusions: Bool {
        !excludedSegmentIndices.isEmpty
    }

    /// Segments the user has kept, in original order.
    var includedSegments: [TranscriptSegment] {
        let excluded = excludedIndexSet
        return segments.enumerated()
            .filter { !excluded.contains($0.offset) }
            .map(\.element)
    }

    var removedSegmentCount: Int {
        // Guards against a stale index surviving a shorter re-transcription.
        excludedIndexSet.filter { $0 < segments.count }.count
    }

    /// The transcript as it currently stands, with removals applied. This is
    /// what summarization, search, and export all consume — `transcript` is the
    /// untouched original and is only used to rebuild from.
    var effectiveTranscript: String {
        guard hasExclusions else { return transcript ?? "" }
        let composed = TranscriptComposer.compose(includedSegments)
        // If segments are somehow unavailable, fall back to the original rather
        // than silently handing an empty transcript to the summarizer.
        return composed.isEmpty ? (transcript ?? "") : composed
    }

    /// Applies a new exclusion set, flagging the summary as stale only if one
    /// exists and the selection actually changed.
    func applyExclusions(_ indices: Set<Int>) {
        let normalized = indices.filter { $0 >= 0 && $0 < segments.count }.sorted()
        guard normalized != excludedSegmentIndices.sorted() else { return }

        excludedSegmentIndices = normalized
        if hasSummary {
            summaryNeedsRefresh = true
        }
    }

    var hasSummary: Bool {
        !(summaryMarkdown ?? "").isEmpty
    }

    var formattedDuration: String {
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Plain-text rendering used for the share sheet.
    func exportText() -> String {
        var parts: [String] = ["# \(title)", ""]
        parts.append(createdAt.formatted(date: .long, time: .shortened))
        parts.append("Duration: \(formattedDuration)")
        parts.append("")

        if let summary = summaryMarkdown, !summary.isEmpty {
            parts.append("## Summary")
            parts.append(summary)
            parts.append("")
        }
        if !keyPoints.isEmpty {
            parts.append("## Key Points")
            parts.append(contentsOf: keyPoints.map { "- \($0)" })
            parts.append("")
        }
        if !actionItems.isEmpty {
            parts.append("## Action Items")
            parts.append(contentsOf: actionItems.map { "- [ ] \($0)" })
            parts.append("")
        }
        let body = effectiveTranscript
        if !body.isEmpty {
            parts.append("## Transcript")
            if removedSegmentCount > 0 {
                // Say so rather than exporting an edited transcript that reads
                // as a complete record of what was said.
                parts.append("_\(removedSegmentCount) segment\(removedSegmentCount == 1 ? "" : "s") removed by the user._")
                parts.append("")
            }
            parts.append(body)
        }
        return parts.joined(separator: "\n")
    }
}
