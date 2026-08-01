import AVFoundation
import Foundation

/// The contract between the watch app and the phone app for a transferred
/// recording.
///
/// Compiled into both targets so the two sides can't drift — a typo'd metadata
/// key would otherwise surface as a recording that silently arrives without its
/// duration or timestamp.
enum WatchTransfer {
    enum MetadataKey {
        /// UUID string. The phone reuses it as the `Recording` id so a retried
        /// or duplicated transfer can be recognized rather than creating a
        /// second copy of the same recording.
        static let id = "recordingID"
        /// Seconds since 1970, captured when recording started on the watch.
        static let startedAt = "startedAt"
        /// Seconds. Sent explicitly rather than re-derived, since the watch
        /// already knows it exactly.
        static let duration = "duration"
        /// Which device captured the audio.
        static let source = "source"
    }

}

/// The one definition of how audio is captured, used by both the phone and the
/// watch.
///
/// Shared rather than duplicated so the two really are identical: everything
/// downstream — transcription, upload chunking, redaction's re-encode — was
/// written against these values, and a watch recording that quietly differed in
/// sample rate or channel count would misbehave in ways that only show up much
/// later in the pipeline.
enum RecordingFormat {
    static let fileExtension = "m4a"

    static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]
}

/// Which device's microphone captured a recording.
enum RecordingSource: String, Codable, Sendable, CaseIterable {
    case phone
    case watch

    var label: String {
        switch self {
        case .phone: return "iPhone"
        case .watch: return "Apple Watch"
        }
    }

    var systemImage: String {
        switch self {
        case .phone: return "iphone"
        case .watch: return "applewatch"
        }
    }
}
