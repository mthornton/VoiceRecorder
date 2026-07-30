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

struct TranscriptionResult: Sendable {
    var text: String
    var segments: [TranscriptSegment]
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

/// The seam that keeps a cloud transcription provider a drop-in addition.
///
/// v1 ships exactly one conformance, `OnDeviceTranscriber`. A cloud provider
/// (and with it, speaker labels) is deliberately out of scope — but everything
/// downstream of this protocol is already written against the abstraction.
protocol TranscriptionProvider: Sendable {
    var displayName: String { get }
    var supportsSpeakerLabels: Bool { get }

    func transcribe(fileURL: URL) async throws -> TranscriptionResult
}
