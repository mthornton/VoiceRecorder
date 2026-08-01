import Foundation

struct SummaryOutput: Sendable {
    var title: String?
    var summary: String
    var keyPoints: [String]
    var actionItems: [String]
}

/// Turns a transcript into a title, summary, key points, and action items with
/// one OpenRouter call.
struct SummarizationService: Sendable {
    private let client: OpenRouterClient

    init(client: OpenRouterClient = OpenRouterClient()) {
        self.client = client
    }

    func summarize(
        transcript: String,
        template: SummaryTemplate,
        model: String,
        apiKey: String,
        durationDescription: String,
        hasSpeakerLabels: Bool = false
    ) async throws -> SummaryOutput {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenRouterError.emptyResponse
        }

        // Speaker attribution changes what the model can legitimately claim: with
        // labels it can say who committed to what, without them it must not.
        let speakerGuidance = hasSpeakerLabels
            ? """
            Turns are prefixed with speaker labels. Attribute statements and
            commitments to the right speaker. The labels themselves come from
            automatic attribution and can occasionally be wrong, so don't build
            conclusions on a single borderline turn.
            """
            : """
            The transcript has no speaker labels. Infer speaker changes from
            context where it helps, but do not assert who said what.
            """

        let system = """
        You summarize transcribed audio recordings.

        \(template.prompt)

        The transcript comes from automatic speech recognition, so expect
        mis-heard words and imperfect punctuation. \(speakerGuidance)

        Never invent content that isn't supported by the transcript. If the audio
        is too short or too garbled to summarize meaningfully, say that plainly
        instead of padding.

        Respond with a single JSON object and nothing else — no prose before or
        after, no markdown code fences. Use exactly these keys:

        {
          "title": "a short, specific title, at most 8 words",
          "summary": "the summary, as markdown paragraphs",
          "keyPoints": ["..."],
          "actionItems": ["..."]
        }

        keyPoints and actionItems must be arrays of plain strings with no
        bullet characters. Use an empty array when there is nothing to list —
        do not invent action items just to fill the field.
        """

        let user = """
        Recording length: \(durationDescription)

        Transcript:
        \(trimmed)
        """

        let content = try await client.complete(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user),
            ],
            apiKey: apiKey
        )

        return Self.parse(content)
    }

    // MARK: - Parsing

    /// Deliberately tolerant. Models wrap JSON in code fences, prepend "Here's
    /// your summary:", or ignore the format entirely. Rather than fail the whole
    /// summarization over presentation, fall back to treating the response as
    /// plain markdown — the user still gets something useful.
    static func parse(_ content: String) -> SummaryOutput {
        if let object = extractJSONObject(from: content) {
            let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let summary, !summary.isEmpty {
                return SummaryOutput(
                    title: (title?.isEmpty ?? true) ? nil : title,
                    summary: summary,
                    keyPoints: stringArray(object["keyPoints"]),
                    actionItems: stringArray(object["actionItems"])
                )
            }
        }

        return SummaryOutput(
            title: nil,
            summary: stripCodeFences(content).trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: [],
            actionItems: []
        )
    }

    private static func extractJSONObject(from content: String) -> [String: Any]? {
        let cleaned = stripCodeFences(content)

        // Scan from the first "{" to the last "}" so leading chatter and
        // trailing commentary don't break decoding.
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start < end else { return nil }

        let slice = String(cleaned[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func stripCodeFences(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func stringArray(_ value: Any?) -> [String] {
        guard let raw = value as? [Any] else { return [] }
        return raw.compactMap { element in
            guard let text = element as? String else { return nil }
            let trimmed = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                // Models add bullets despite being told not to.
                .trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
