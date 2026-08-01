import AVFoundation
import Foundation
import Speech

/// Transcribes a finished audio file with Apple's on-device `SpeechAnalyzer`
/// (iOS 26+). Nothing leaves the device, there's no per-minute cost, and unlike
/// the older `SFSpeechRecognizer` it's built for long-form audio, so an hour-long
/// recording doesn't need manual chunking.
final class OnDeviceTranscriber: TranscriptionProvider {
    let displayName = "On-device (Apple)"

    /// Apple's engine returns one undifferentiated stream — no diarization.
    let supportsSpeakerLabels = false

    let engine = TranscriptionEngine.onDevice

    func transcribe(fileURL: URL) async throws -> TranscriptionResult {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailableOnThisDevice
        }

        let locale = try await resolveLocale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)

        try await ensureModelInstalled(for: transcriber, locale: locale)

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw TranscriptionError.audioUnreadable(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Results stream in while the analyzer consumes the file, so collection
        // has to run concurrently with analysis — draining afterwards would
        // deadlock against the analyzer waiting for the consumer.
        let collector = Task { () -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                segments.append(
                    TranscriptSegment(
                        text: text,
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        speaker: nil
                    )
                )
            }
            return segments
        }

        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw TranscriptionError.audioUnreadable(error.localizedDescription)
        }

        let segments = try await collector.value
        let text = TranscriptComposer.compose(segments)

        guard !text.isEmpty else {
            throw TranscriptionError.producedNoText
        }

        return TranscriptionResult(text: text, segments: segments, engine: engine)
    }

    // MARK: - Locale

    /// Maps the user's current locale onto one the transcriber actually supports
    /// (e.g. en_AU → en_US), falling back to any installed English before giving up.
    private func resolveLocale() async throws -> Locale {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return match
        }

        let supported = await SpeechTranscriber.supportedLocales
        if let english = supported.first(where: { $0.language.languageCode?.identifier == "en" }) {
            return english
        }
        if let first = supported.first {
            return first
        }

        throw TranscriptionError.unsupportedLocale(Locale.current.identifier)
    }

    // MARK: - Model assets

    /// The speech model for a locale is downloaded on demand, not bundled. The
    /// first transcription on a fresh device therefore pulls a few hundred MB.
    private func ensureModelInstalled(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])

        switch status {
        case .installed:
            return
        case .unsupported:
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        case .supported, .downloading:
            break
        @unknown default:
            break
        }

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.modelDownloadFailed(error.localizedDescription)
        }

        // Reserving keeps the locale's assets from being reclaimed. It can fail
        // if the user already has the maximum number of locales reserved, which
        // is harmless here — the model is installed either way.
        _ = try? await AssetInventory.reserve(locale: locale)
    }
}
