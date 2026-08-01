import SwiftData
import SwiftUI

/// Full transcript, with speaker-attributed or continuous presentation, and an
/// edit mode for removing parts of it.
///
/// Removal operates on individual segments rather than the merged turns shown in
/// reading mode, so the user gets finer control than the display granularity
/// suggests. Nothing is destroyed — removed segments are flagged, can be
/// reviewed and restored, and the audio is untouched.
struct TranscriptView: View {
    @Bindable var recording: Recording

    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(\.modelContext) private var context

    @State private var mode: Mode = .speakers
    @State private var searchText = ""
    @State private var isEditing = false
    @State private var selection: Set<Int> = []
    @State private var showRemoved = false
    @State private var askToResummarize = false

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
                    if recording.removedSegmentCount > 0 {
                        removedNotice
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
        .alert("Regenerate summary?", isPresented: $askToResummarize) {
            Button("Not Now", role: .cancel) {}
            Button("Regenerate") {
                Task { await pipeline.resummarize(recording, context: context) }
            }
        } message: {
            Text("The transcript changed, so the current summary is out of date. Regenerating uses the edited transcript.")
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
                Button("Done") { commitEdits() }
                    .fontWeight(.semibold)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if canEdit {
                        Button {
                            selection = recording.excludedIndexSet
                            showRemoved = true
                            isEditing = true
                        } label: {
                            Label("Remove Parts", systemImage: "scissors")
                        }
                    }
                    if recording.removedSegmentCount > 0 {
                        Button {
                            restoreAll()
                        } label: {
                            Label("Restore All Removed", systemImage: "arrow.uturn.backward")
                        }
                    }
                    Divider()
                    ShareLink(item: shareableText) {
                        Label("Share Transcript", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Edit mode

    private var editingBanner: some View {
        Label(
            "Tap segments to remove them from the transcript. The audio isn't changed, and you can restore them later.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }

    private var editableSegments: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(editableIndices, id: \.self) { index in
                let segment = recording.segments[index]
                let isRemoved = selection.contains(index)

                Button {
                    if isRemoved { selection.remove(index) } else { selection.insert(index) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: isRemoved ? "minus.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isRemoved ? Color.red : Color.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            if let speaker = segment.speaker {
                                Text(speaker)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(color(for: speaker))
                            }
                            Text(segment.text)
                                .font(.callout)
                                .foregroundStyle(isRemoved ? .secondary : .primary)
                                .strikethrough(isRemoved, color: .red.opacity(0.6))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(12)
                    .background(
                        isRemoved ? Color.red.opacity(0.08) : Color.secondary.opacity(0.06),
                        in: .rect(cornerRadius: 10)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var editableActionCount: Int { selection.count }

    private var editingActionBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Text(editableActionCount == 0
                     ? "Nothing removed"
                     : "\(editableActionCount) segment\(editableActionCount == 1 ? "" : "s") removed")
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

    /// In edit mode the search filters which segments are listed, so a long
    /// transcript can be narrowed before selecting.
    private var editableIndices: [Int] {
        let all = Array(recording.segments.indices)
        guard !searchText.isEmpty else { return all }
        return all.filter { recording.segments[$0].text.localizedStandardContains(searchText) }
    }

    private func commitEdits() {
        let changed = selection != recording.excludedIndexSet
        recording.applyExclusions(selection)
        try? context.save()
        isEditing = false

        if changed && recording.hasSummary {
            askToResummarize = true
        }
    }

    private func restoreAll() {
        recording.applyExclusions([])
        try? context.save()
        if recording.hasSummary {
            askToResummarize = true
        }
    }

    // MARK: - Reading mode

    private var removedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "scissors")
            Text("\(recording.removedSegmentCount) segment\(recording.removedSegmentCount == 1 ? "" : "s") removed")
            Spacer()
            Button(showRemoved ? "Hide" : "Show") {
                withAnimation(.snappy) { showRemoved.toggle() }
            }
            .font(.caption.weight(.semibold))
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
                        if turn.removed {
                            Text("removed")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.red)
                        }
                    }

                    Text(highlighted(turn.text))
                        .font(.body)
                        .foregroundStyle(turn.removed ? .secondary : .primary)
                        .strikethrough(turn.removed, color: .red.opacity(0.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Consecutive segments from the same speaker are collapsed into one turn so
    /// the view reads as a conversation. Removed segments never merge with kept
    /// ones — that would make a partly-removed turn impossible to represent.
    private var mergedTurns: [(speaker: String, text: String, removed: Bool)] {
        let excluded = recording.excludedIndexSet
        var turns: [(speaker: String, text: String, removed: Bool)] = []

        for (index, segment) in recording.segments.enumerated() {
            let removed = excluded.contains(index)
            if removed && !showRemoved { continue }

            let speaker = segment.speaker ?? "Unknown"
            if let last = turns.last, last.speaker == speaker, last.removed == removed {
                turns[turns.count - 1].text += " " + segment.text
            } else {
                turns.append((speaker, segment.text, removed))
            }
        }

        guard !searchText.isEmpty else { return turns }
        return turns.filter { $0.text.localizedStandardContains(searchText) }
    }

    private var plainText: some View {
        VStack(alignment: .leading, spacing: 12) {
            if searchText.isEmpty {
                Text(displayedPlainText)
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

    /// Plain mode shows the edited transcript, or the full original when the
    /// user has asked to see removed content.
    private var displayedPlainText: String {
        showRemoved
            ? TranscriptComposer.compose(recording.segments)
            : recording.effectiveTranscript
    }

    private var matchingParagraphs: [String] {
        displayedPlainText
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

    /// Stable per-speaker colour. Keyed on the full roster rather than the
    /// filtered one so colours don't shift when segments are removed.
    private func color(for speaker: String) -> Color {
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .green, .indigo, .brown]
        var roster: [String] = []
        for name in recording.segments.compactMap(\.speaker) where !roster.contains(name) {
            roster.append(name)
        }
        guard let index = roster.firstIndex(of: speaker) else { return .secondary }
        return palette[index % palette.count]
    }

    private var shareableText: String {
        recording.effectiveTranscript
    }
}
