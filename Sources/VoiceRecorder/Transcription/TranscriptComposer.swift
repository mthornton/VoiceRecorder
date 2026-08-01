import Foundation

/// Builds the flat transcript text from segments.
///
/// Shared by both transcription engines and by `Recording`, which has to rebuild
/// the text whenever the user removes segments. Keeping one implementation means
/// an edited transcript is formatted identically to the original rather than
/// subtly diverging after the first edit.
enum TranscriptComposer {
    static func compose(_ segments: [TranscriptSegment]) -> String {
        let usable = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return "" }

        return usable.contains(where: { $0.speaker != nil })
            ? composeWithSpeakers(usable)
            : composeContinuous(usable)
    }

    /// Speaker-labelled turns, one blank line apart. Consecutive segments from
    /// the same speaker are folded into one turn so the label isn't repeated.
    private static func composeWithSpeakers(_ segments: [TranscriptSegment]) -> String {
        var lines: [String] = []
        var lastSpeaker: String?

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if let speaker = segment.speaker {
                if speaker == lastSpeaker, !lines.isEmpty {
                    lines[lines.count - 1] += " " + text
                } else {
                    lines.append("\(speaker): \(text)")
                    lastSpeaker = speaker
                }
            } else {
                lines.append(text)
                lastSpeaker = nil
            }
        }

        return lines.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// No speaker information — one continuous body of text.
    ///
    /// Segments are trimmed and rejoined with single spaces rather than
    /// concatenated raw. The on-device engine emits leading spaces that would
    /// otherwise collapse into doubled or missing spaces once a segment in the
    /// middle is removed.
    private static func composeContinuous(_ segments: [TranscriptSegment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
