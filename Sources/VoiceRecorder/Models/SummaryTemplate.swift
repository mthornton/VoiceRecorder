import Foundation

/// A summarization style: a name plus the instructions handed to the model.
///
/// The four built-ins are fixed. `custom` carries a user-editable prompt stored
/// in `SettingsStore`, which is why `prompt` is a `var` rather than a `let`.
struct SummaryTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let systemImage: String
    var prompt: String

    static let meeting = SummaryTemplate(
        id: "meeting",
        name: "Meeting",
        systemImage: "person.2.fill",
        prompt: """
        This is a recording of a meeting. Summarize it for someone who missed it.
        Lead with the decisions that were made and who owns what. Be concrete about
        commitments — names, dates, and numbers matter more than atmosphere. If the
        meeting reached no decision on something that was discussed at length, say so
        explicitly rather than implying closure.
        """
    )

    static let lecture = SummaryTemplate(
        id: "lecture",
        name: "Lecture",
        systemImage: "graduationcap.fill",
        prompt: """
        This is a recording of a lecture or talk. Summarize the substance for
        someone studying it later. Preserve the structure of the argument, define
        the key concepts in the speaker's own framing, and keep any examples that
        carry explanatory weight. Prioritize understanding over coverage.
        """
    )

    static let interview = SummaryTemplate(
        id: "interview",
        name: "Interview",
        systemImage: "mic.fill",
        prompt: """
        This is a recording of an interview or conversation. Summarize what the
        subject actually said. Keep their reasoning and any striking or quotable
        phrasing intact rather than flattening it into paraphrase. Note where they
        hedged, contradicted themselves, or declined to answer.
        """
    )

    static let quickMemo = SummaryTemplate(
        id: "quickMemo",
        name: "Quick Memo",
        systemImage: "note.text",
        prompt: """
        This is a short voice memo, probably a note to self. Be terse. Capture the
        point in a sentence or two and pull out anything that looks like a task.
        Do not pad it out to seem thorough.
        """
    )

    static let customID = "custom"

    static let defaultCustomPrompt = """
    Summarize this recording clearly and concisely, focusing on what matters most
    to someone who was not present.
    """

    static let builtIns: [SummaryTemplate] = [meeting, lecture, interview, quickMemo]

    static func custom(prompt: String) -> SummaryTemplate {
        SummaryTemplate(
            id: customID,
            name: "Custom",
            systemImage: "slider.horizontal.3",
            prompt: prompt.isEmpty ? defaultCustomPrompt : prompt
        )
    }

    /// Resolves an id back to a template, folding in the user's custom prompt.
    /// Falls back to Meeting so a stale id on an old recording can't strand it.
    static func template(withID id: String, customPrompt: String) -> SummaryTemplate {
        if id == customID { return custom(prompt: customPrompt) }
        return builtIns.first { $0.id == id } ?? meeting
    }

    static func all(customPrompt: String) -> [SummaryTemplate] {
        builtIns + [custom(prompt: customPrompt)]
    }
}
