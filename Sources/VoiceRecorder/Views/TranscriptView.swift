import SwiftData
import SwiftUI

/// Full transcript, with speaker-attributed or continuous presentation, and an
/// edit mode for permanently removing parts of it.
///
/// Removal here is redaction, not hiding: selected segments are deleted from the
/// transcript *and* cut out of the audio file. It exists so sensitive content
/// stops existing, so there is no undo and the UI says so before acting.
struct TranscriptView: View {
    @Bindable var recording: Recording

    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(RedactionService.self) private var redaction
    @Environment(\.modelContext) private var context

    @State private var mode: Mode = .speakers
    @State private var searchText = ""
    @State private var isEditing = false
    @State private var selection: Set<Int> = []
    @State private var confirmRedaction = false
    @State private var askToResummarize = false
    @State private var errorMessage: String?

    enum Mode: String, CaseIterable, Identifiable {
        case speakers = "Speakers"
        case plain = "Plain Text"

        var id: String { rawValue }
    }

    private var speakers: [String] { recording.distinctSpeakers }
    private var canShowSpeakers: Bool { recording.hasSpeakerLabels }
    private var canEdit: Bool { !recording.segments.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isEditing {
                    editingBanner
                } else {
                    if canShowSpeakers {
                        Picker("View", selection: $mode) {
                            ForEach(Mode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        speakerLegend
                    }
                    if recording.hasRedactions {
                        redactionNotice
                    }
                }

                if isEditing {
                    editableSegments
                } else if canShowSpeakers && mode == .speakers {
                    speakerTurns
                } else {
                    plainText
                }

                if !isEditing {
                    provenanceFooter
                }
            }
            .padding()
            .padding(.bottom, isEditing ? 80 : 0)
        }
        .navigationTitle(isEditing ? "Select to Remove" : "Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: isEditing ? "Find segments" : "Find in transcript")
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if isEditing { editingActionBar }
        }
        .overlay { if redaction.isWorking { workingOverlay } }
        .alert("Remove permanently?", isPresented: $confirmRedaction) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { performRedaction() }
        } message: {
            Text(confirmationMessage)
        }
        .alert("Regenerate summary?", isPresented: $askToResummarize) {
            Button("Not Now", role: .cancel) {}
            Button("Regenerate") {
                Task { await pipeline.resummarize(recording, context: context) }
            }
        } message: {
            Text("The transcript changed, so the current summary is out of date. Regenerating uses the edited transcript.")
        }
        .alert(
            "Couldn't remove that",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            if redaction.canOfferFallback {
                Button("Use On-device Transcript") {
                    redaction.adoptFallbackTranscript(recording, context: context)
                    errorMessage = nil
                }
            }
            Button("Cancel", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    selection = []
                    isEditing = false
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Remove") { confirmRedaction = true }
                    .fontWeight(.semibold)
                    .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if canEdit {
                        Button(role: .destructive) {
                            selection = []
                            isEditing = true
                        } label: {
                            Label("Remove Parts", systemImage: "scissors")
                        }
                    }
                    Divider()
                    ShareLink(item: recording.transcript ?? "") {
                        Label("Share Transcript", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(redaction.isWorking)
            }
        }
    }

    // MARK: - Edit mode

    private var editingBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Selected segments are deleted from the transcript and cut out of the audio. This can't be undone.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)

            if recording.needsAlignmentBeforeRedaction {
                // Worth saying up front: this transcript's timings are estimates,
                // so the app has to re-listen to the audio before it can cut
                // accurately, and that takes a while on a long recording.
                Text("This recording needs a pass to locate the words in the audio first, so removal will take a minute or two.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 12))
    }

    private var editableSegments: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(editableIndices, id: \.self) { index in
                let segment = recording.segments[index]
                let isSelected = selection.contains(index)

                Button {
                    if isSelected { selection.remove(index) } else { selection.insert(index) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: isSelected ? "minus.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.red : Color.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            if let speaker = segment.speaker {
                                Text(speaker)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(color(for: speaker))
                            }
                            Text(segment.text)
                                .font(.callout)
                                .foregroundStyle(isSelected ? .secondary : .primary)
                                .strikethrough(isSelected, color: .red.opacity(0.6))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(12)
                    .background(
                        isSelected ? Color.red.opacity(0.08) : Color.secondary.opacity(0.06),
                        in: .rect(cornerRadius: 10)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var editingActionBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Text(selection.isEmpty
                     ? "Select segments to remove"
                     : "\(selection.count) selected · about \(formatted(selectedDuration)) of audio")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Clear") { selection = [] }
                    .disabled(selection.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    private var editableIndices: [Int] {
        let all = Array(recording.segments.indices)
        guard !searchText.isEmpty else { return all }
        return all.filter { recording.segments[$0].text.localizedStandardContains(searchText) }
    }

    /// Approximate by nature: on an unaligned transcript these are the estimated
    /// spans, which is why it's presented as "about" rather than a promise.
    private var selectedDuration: TimeInterval {
        selection
            .filter { $0 < recording.segments.count }
            .reduce(0) { total, index in
                let segment = recording.segments[index]
                return total + max(segment.end - segment.start, 0)
            }
    }

    private var confirmationMessage: String {
        let count = selection.count
        return """
        \(count) segment\(count == 1 ? "" : "s") — about \(formatted(selectedDuration)) of audio — will be \
        deleted from the transcript and cut out of the recording.

        The audio file is overwritten. There is no undo and no backup copy.
        """
    }

    private var workingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(redaction.phase.message ?? "Working…")
                    .font(.subheadline)
                Text("Don't close the app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
        }
    }

    private func performRedaction() {
        let indices = selection
        isEditing = false
        selection = []

        Task {
            do {
                try await redaction.redact(recording, indices: indices, context: context)
                if recording.hasSummary {
                    askToResummarize = true
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        if total < 60 { return "\(total)s" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Reading mode

    private var redactionNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "scissors")
            Text("\(recording.redactedSegmentCount) segment\(recording.redactedSegmentCount == 1 ? "" : "s") "
                 + "(\(recording.formattedRedactedDuration)) permanently removed")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    private var speakerLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(speakers, id: \.self) { speaker in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(for: speaker))
                            .frame(width: 8, height: 8)
                        Text(speaker)
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(color(for: speaker).opacity(0.12), in: .capsule)
                }
            }
        }
    }

    private var speakerTurns: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(mergedTurns.enumerated()), id: \.offset) { _, turn in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(for: turn.speaker))
                            .frame(width: 8, height: 8)
                        Text(turn.speaker)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(color(for: turn.speaker))
                    }

                    Text(highlighted(turn.text))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var mergedTurns: [(speaker: String, text: String)] {
        var turns: [(speaker: String, text: String)] = []

        for segment in recording.segments {
            let speaker = segment.speaker ?? "Unknown"
            if let last = turns.last, last.speaker == speaker {
                turns[turns.count - 1].text += " " + segment.text
            } else {
                turns.append((speaker, segment.text))
            }
        }

        guard !searchText.isEmpty else { return turns }
        return turns.filter { $0.text.localizedStandardContains(searchText) }
    }

    private var plainText: some View {
        VStack(alignment: .leading, spacing: 12) {
            if searchText.isEmpty {
                Text(recording.transcript ?? "")
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let matches = matchingParagraphs
                if matches.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(matches.enumerated()), id: \.offset) { _, paragraph in
                        Text(highlighted(paragraph))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var matchingParagraphs: [String] {
        (recording.transcript ?? "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.localizedStandardContains(searchText) }
    }

    // MARK: - Shared

    @ViewBuilder
    private var provenanceFooter: some View {
        if let engine = recording.transcriptionEngine {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Text(engine == .cloudSpeakerAware
                     ? "Transcribed with speaker attribution. Speaker labels are inferred and can be wrong — check the audio before relying on who said what."
                     : "Transcribed on this device. Speaker labels aren't available from the on-device engine.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !searchText.isEmpty else { return attributed }

        var cursor = attributed.startIndex
        while cursor < attributed.endIndex,
              let range = attributed[cursor...].range(of: searchText, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow.opacity(0.35)
            cursor = range.upperBound
        }
        return attributed
    }

    private func color(for speaker: String) -> Color {
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .green, .indigo, .brown]
        guard let index = speakers.firstIndex(of: speaker) else { return .secondary }
        return palette[index % palette.count]
    }
}
