import Foundation

/// Transcribes with speaker attribution by sending the audio to an
/// audio-capable model through OpenRouter.
///
/// This is inference, not acoustic diarization: the model distinguishes speakers
/// from voice characteristics and conversational cues rather than clustering
/// voice embeddings the way a dedicated STT service does. It handles a few
/// clearly-alternating speakers well and degrades with crosstalk, similar
/// voices, or large groups. That tradeoff buys a single API key and roughly a
/// cent per hour instead of a second account at ~25x the cost.
///
/// Unlike `OnDeviceTranscriber`, this uploads the recording itself.
struct SpeakerAwareTranscriber: TranscriptionProvider {
    let displayName = "Speaker-aware (OpenRouter)"
    let supportsSpeakerLabels = true
    let engine = TranscriptionEngine.cloudSpeakerAware

    let model: String
    let apiKey: String
    private let client: OpenRouterClient

    init(model: String, apiKey: String, client: OpenRouterClient = OpenRouterClient()) {
        self.model = model
        self.apiKey = apiKey
        self.client = client
    }

    func transcribe(fileURL: URL) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw OpenRouterError.missingKey }

        let chunks = try await AudioTranscoder.prepareForUpload(sourceURL: fileURL)
        defer { AudioTranscoder.cleanUp(chunks) }

        var allSegments: [TranscriptSegment] = []
        var knownSpeakers: [String] = []

        // Sequential, not concurrent. Each chunk is told which speakers the
        // previous chunks established, so "Speaker 2" means the same person
        // throughout instead of being renumbered at every seam.
        for chunk in chunks {
            let audio = try Data(contentsOf: chunk.url)

            let content = try await client.completeWithAudio(
                model: model,
                systemPrompt: Self.systemPrompt,
                userPrompt: Self.userPrompt(
                    chunk: chunk,
                    totalChunks: chunks.count,
                    knownSpeakers: knownSpeakers
                ),
                audio: audio,
                audioFormat: AudioTranscoder.uploadFormat,
                apiKey: apiKey
            )

            let segments = Self.parseSegments(content, chunkStart: chunk.start, chunkDuration: chunk.duration)
            allSegments.append(contentsOf: segments)

            for speaker in segments.compactMap(\.speaker) where !knownSpeakers.contains(speaker) {
                knownSpeakers.append(speaker)
            }
        }

        let text = TranscriptComposer.compose(allSegments)
        guard !text.isEmpty else {
            throw TranscriptionError.producedNoText
        }

        return TranscriptionResult(text: text, segments: allSegments, engine: engine)
    }

    // MARK: - Prompting

    private static let systemPrompt = """
    You transcribe audio recordings with speaker attribution.

    Transcribe everything spoken, verbatim. Do not summarize, paraphrase, clean
    up grammar, or omit tangents and filler that carry meaning. Add sensible
    punctuation and capitalization.

    Attribute every segment to a speaker. If someone is clearly named or
    introduces themselves, use that name. Otherwise label them "Speaker 1",
    "Speaker 2", and so on in order of first appearance. Start a new segment
    every time the speaker changes.

    If you genuinely cannot tell speakers apart, use a single speaker label for
    the whole passage rather than guessing at turn boundaries — a wrong
    attribution is worse than a missing one.

    Respond with a single JSON object and nothing else — no prose before or
    after, no markdown code fences:

    {"segments":[{"speaker":"Speaker 1","text":"..."}]}

    If there is no intelligible speech, return {"segments":[]}.
    """

    private static func userPrompt(chunk: AudioChunk, totalChunks: Int, knownSpeakers: [String]) -> String {
        var lines: [String] = []

        if totalChunks > 1 {
            lines.append(
                "This is part \(chunk.index + 1) of \(totalChunks) of a longer recording, "
                + "starting at \(timecode(chunk.start)) into the original."
            )
        }

        if !knownSpeakers.isEmpty {
            lines.append(
                "Speakers already identified earlier in this recording: "
                + knownSpeakers.joined(separator: ", ")
                + ". Reuse these exact labels for the same people. Only introduce a new "
                + "label for a voice that has not appeared before."
            )
        }

        if chunk.index > 0 {
            lines.append(
                "This part may begin mid-sentence. Transcribe from the first audible word "
                + "without trying to reconstruct what came before."
            )
        }

        lines.append("Transcribe this audio.")
        return lines.joined(separator: "\n\n")
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Parsing

    /// Segment times are approximate: the model returns ordered turns without
    /// reliable timestamps, so turns are distributed across the chunk's span in
    /// proportion to their length. Good enough to keep ordering and rough
    /// position; not accurate enough to drive seeking, which is why the UI
    /// doesn't offer tap-to-seek on a turn.
    static func parseSegments(
        _ content: String,
        chunkStart: TimeInterval,
        chunkDuration: TimeInterval
    ) -> [TranscriptSegment] {
        guard let object = extractJSONObject(from: content),
              let raw = object["segments"] as? [[String: Any]]
        else { return [] }

        let parsed: [(speaker: String?, text: String)] = raw.compactMap { entry in
            guard let text = (entry["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }

            let speaker = (entry["speaker"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (speaker?.isEmpty == true ? nil : speaker, text)
        }

        guard !parsed.isEmpty else { return [] }

        let totalCharacters = max(parsed.reduce(0) { $0 + $1.text.count }, 1)
        var cursor = chunkStart

        return parsed.map { entry in
            let share = Double(entry.text.count) / Double(totalCharacters)
            let span = chunkDuration * share
            let segment = TranscriptSegment(
                text: entry.text,
                start: cursor,
                end: cursor + span,
                speaker: entry.speaker
            )
            cursor += span
            return segment
        }
    }

    private static func extractJSONObject(from content: String) -> [String: Any]? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: .newlines)
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n")
        }

        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8)
        else { return nil }

        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

}
