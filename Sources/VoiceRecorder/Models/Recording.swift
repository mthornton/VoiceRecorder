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
        if let transcript, !transcript.isEmpty {
            parts.append("## Transcript")
            parts.append(transcript)
        }
        return parts.joined(separator: "\n")
    }
}
