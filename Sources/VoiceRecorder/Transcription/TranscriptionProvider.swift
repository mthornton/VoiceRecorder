import Foundation

/// One labelled span of a transcript.
///
/// `speaker` is always nil for the on-device provider — Apple's engine returns a
/// single undifferentiated stream. It exists so a cloud provider with
/// diarization can populate it later without changing this protocol or the
/// storage layer.
struct TranscriptSegment: Sendable, Codable, Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String?
}

/// Which engine produced a transcript.
///
/// Recorded per-recording rather than read from current settings, because the
/// setting can change after the fact and the UI must not claim a transcript has
/// speaker labels when the engine that produced it couldn't generate them.
enum TranscriptionEngine: String, Codable, Sendable, CaseIterable {
    case onDevice
    case cloudSpeakerAware

    var label: String {
        switch self {
        case .onDevice: return "On-device"
        case .cloudSpeakerAware: return "Speaker-aware"
        }
    }

    var producesSpeakerLabels: Bool {
        self == .cloudSpeakerAware
    }
}

struct TranscriptionResult: Sendable {
    var text: String
    var segments: [TranscriptSegment]
    var engine: TranscriptionEngine
}

enum TranscriptionError: LocalizedError {
    case unavailableOnThisDevice
    case unsupportedLocale(String)
    case modelDownloadFailed(String)
    case audioUnreadable(String)
    case producedNoText

    var errorDescription: String? {
        switch self {
        case .unavailableOnThisDevice:
            return "On-device transcription isn't available on this device."
        case .unsupportedLocale(let locale):
            return "On-device transcription doesn't support \(locale)."
        case .modelDownloadFailed(let detail):
            return "Couldn't download the speech model. \(detail)"
        case .audioUnreadable(let detail):
            return "Couldn't read the recording. \(detail)"
        case .producedNoText:
            return "No speech was detected in this recording."
        }
    }
}

/// The seam that keeps transcription engines interchangeable.
///
/// Two conformances: `OnDeviceTranscriber` (free, private, no speaker labels)
/// and `SpeakerAwareTranscriber` (uploads audio, returns speaker-attributed
/// turns). `ProcessingPipeline` picks between them from settings.
protocol TranscriptionProvider: Sendable {
    var displayName: String { get }
    var supportsSpeakerLabels: Bool { get }
    var engine: TranscriptionEngine { get }

    func transcribe(fileURL: URL) async throws -> TranscriptionResult
}
