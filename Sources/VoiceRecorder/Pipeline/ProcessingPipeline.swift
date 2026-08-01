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
    private let summarizer: SummarizationService
    private let settings: SettingsStore

    /// Overrides provider selection in tests. Nil in the app, where the provider
    /// is chosen per-run from current settings.
    private let transcriberOverride: TranscriptionProvider?

    /// Recordings currently being worked on, so the UI can show per-row spinners
    /// and refuse to start a duplicate run.
    private(set) var activeIDs: Set<UUID> = []

    init(
        settings: SettingsStore,
        transcriber: TranscriptionProvider? = nil,
        summarizer: SummarizationService = SummarizationService()
    ) {
        self.settings = settings
        self.transcriberOverride = transcriber
        self.summarizer = summarizer
    }

    func isActive(_ recording: Recording) -> Bool {
        activeIDs.contains(recording.id)
    }

    /// Resolved at the start of each run rather than at init, so toggling the
    /// setting takes effect on the next transcription without restarting.
    private func makeTranscriber() -> TranscriptionProvider {
        if let transcriberOverride { return transcriberOverride }

        if settings.usesSpeakerAwareTranscription {
            return SpeakerAwareTranscriber(
                model: settings.transcriptionModelID,
                apiKey: settings.apiKey
            )
        }
        return OnDeviceTranscriber()
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

    /// Discards the existing transcript and runs the whole pipeline again with
    /// the currently selected engine. Used to upgrade an on-device transcript to
    /// a speaker-aware one, or to fall back the other way.
    func retranscribe(_ recording: Recording, context: ModelContext) async {
        guard !activeIDs.contains(recording.id) else { return }

        recording.transcript = nil
        recording.segmentsData = nil
        recording.transcriptionEngineRaw = nil
        // Segment indices only mean something against the segments they came
        // from; a new transcription renumbers everything, so removals cannot
        // carry over.
        recording.excludedSegmentIndices = []
        recording.summaryNeedsRefresh = false
        save(context)

        await process(recording, context: context)
    }

    /// Re-runs only the summary, reusing the existing transcript.
    func resummarize(_ recording: Recording, template: SummaryTemplate, context: ModelContext) async {
        guard !activeIDs.contains(recording.id), recording.hasTranscript else { return }
        activeIDs.insert(recording.id)
        defer { activeIDs.remove(recording.id) }

        recording.templateID = template.id
        await runSummarization(recording, template: template, context: context)
    }

    /// Re-runs the summary with whatever template the recording already uses.
    /// Called after the user edits the transcript.
    func resummarize(_ recording: Recording, context: ModelContext) async {
        await resummarize(
            recording,
            template: settings.template(withID: recording.templateID),
            context: context
        )
    }

    // MARK: - Stages

    private func runTranscription(_ recording: Recording, context: ModelContext) async -> Bool {
        recording.status = .transcribing
        recording.errorMessage = nil
        save(context)

        let transcriber = makeTranscriber()

        do {
            let result = try await transcriber.transcribe(fileURL: recording.audioURL)
            recording.transcript = result.text
            recording.segments = result.segments
            recording.transcriptionEngineRaw = result.engine.rawValue
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
        // The effective transcript, so anything the user removed is genuinely
        // absent from what the model sees.
        let transcript = recording.effectiveTranscript
        guard !transcript.isEmpty else { return }

        recording.status = .summarizing
        recording.errorMessage = nil
        save(context)

        do {
            let output = try await summarizer.summarize(
                transcript: transcript,
                template: template,
                model: settings.modelID,
                apiKey: settings.apiKey,
                durationDescription: recording.formattedDuration,
                hasSpeakerLabels: recording.hasSpeakerLabels
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
            recording.summaryNeedsRefresh = false
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
