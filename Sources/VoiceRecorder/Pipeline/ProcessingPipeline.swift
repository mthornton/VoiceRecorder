import Foundation
import Observation
import SwiftData

/// Drives a recording through transcription and summarization.
///
/// The two stages are separate and separately retryable on purpose: a failed
/// summary must never cost the user a transcript that took real time to produce,
/// and re-summarizing with a different template or model reuses the cached
/// transcript rather than transcribing again.
@MainActor
@Observable
final class ProcessingPipeline {
    private let transcriber: TranscriptionProvider
    private let summarizer: SummarizationService
    private let settings: SettingsStore

    /// Recordings currently being worked on, so the UI can show per-row spinners
    /// and refuse to start a duplicate run.
    private(set) var activeIDs: Set<UUID> = []

    init(
        settings: SettingsStore,
        transcriber: TranscriptionProvider = OnDeviceTranscriber(),
        summarizer: SummarizationService = SummarizationService()
    ) {
        self.settings = settings
        self.transcriber = transcriber
        self.summarizer = summarizer
    }

    func isActive(_ recording: Recording) -> Bool {
        activeIDs.contains(recording.id)
    }

    /// Runs whatever stages still need running. Called automatically when a
    /// recording finishes, and from the retry button.
    func process(_ recording: Recording, context: ModelContext) async {
        guard !activeIDs.contains(recording.id) else { return }
        activeIDs.insert(recording.id)
        defer { activeIDs.remove(recording.id) }

        if !recording.hasTranscript {
            guard await runTranscription(recording, context: context) else { return }
        }

        // Summarization is automatic, but only when there's a key to use.
        // Without one the recording legitimately rests at `.transcribed` — it is
        // not a failure state, and the detail view says so.
        guard settings.hasAPIKey else { return }

        await runSummarization(
            recording,
            template: settings.template(withID: recording.templateID),
            context: context
        )
    }

    /// Re-runs only the summary, reusing the existing transcript.
    func resummarize(_ recording: Recording, template: SummaryTemplate, context: ModelContext) async {
        guard !activeIDs.contains(recording.id), recording.hasTranscript else { return }
        activeIDs.insert(recording.id)
        defer { activeIDs.remove(recording.id) }

        recording.templateID = template.id
        await runSummarization(recording, template: template, context: context)
    }

    // MARK: - Stages

    private func runTranscription(_ recording: Recording, context: ModelContext) async -> Bool {
        recording.status = .transcribing
        recording.errorMessage = nil
        save(context)

        do {
            let result = try await transcriber.transcribe(fileURL: recording.audioURL)
            recording.transcript = result.text
            recording.status = .transcribed
            recording.errorMessage = nil
            save(context)
            return true
        } catch {
            recording.status = .transcriptionFailed
            recording.errorMessage = error.localizedDescription
            save(context)
            return false
        }
    }

    private func runSummarization(
        _ recording: Recording,
        template: SummaryTemplate,
        context: ModelContext
    ) async {
        guard let transcript = recording.transcript, !transcript.isEmpty else { return }

        recording.status = .summarizing
        recording.errorMessage = nil
        save(context)

        do {
            let output = try await summarizer.summarize(
                transcript: transcript,
                template: template,
                model: settings.modelID,
                apiKey: settings.apiKey,
                durationDescription: recording.formattedDuration
            )

            recording.summaryMarkdown = output.summary
            recording.keyPoints = output.keyPoints
            recording.actionItems = output.actionItems
            recording.modelID = settings.modelID

            // Only overwrite the placeholder title. If the user renamed the
            // recording by hand, that choice outranks the model's suggestion.
            if let generated = output.title, !generated.isEmpty, recording.title.hasPrefix("New Recording") {
                recording.title = generated
            }

            recording.status = .complete
            recording.errorMessage = nil
            save(context)
        } catch {
            recording.status = .summarizationFailed
            recording.errorMessage = error.localizedDescription
            save(context)
        }
    }

    private func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            // A save failure here isn't worth tearing down the run — the
            // in-memory model is still correct and the next save may succeed.
            print("[VoiceRecorder] SwiftData save failed: \(error)")
        }
    }
}
