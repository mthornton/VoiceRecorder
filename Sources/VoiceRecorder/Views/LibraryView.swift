import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(\.modelContext) private var context

    @Query(sort: \Recording.createdAt, order: .reverse)
    private var recordings: [Recording]

    @State private var search = ""

    var body: some View {
        NavigationStack {
            Group {
                if recordings.isEmpty {
                    ContentUnavailableView(
                        "No Recordings",
                        systemImage: "waveform",
                        description: Text("Recordings you make will appear here, transcribed and summarized.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    list
                }
            }
            .navigationTitle("Library")
            .searchable(text: $search, prompt: "Search transcripts and summaries")
        }
    }

    private var list: some View {
        List {
            ForEach(filtered) { recording in
                NavigationLink {
                    RecordingDetailView(recording: recording)
                } label: {
                    RecordingRow(recording: recording, isWorking: pipeline.isActive(recording))
                }
            }
            .onDelete(perform: delete)
        }
        .listStyle(.plain)
    }

    /// Filtering happens in memory rather than in a `#Predicate`. For a personal
    /// library this is cheap, and it searches the transcript and summary bodies
    /// with the same case- and diacritic-insensitive matching the user expects
    /// from the title — which is fiddly to express as a SwiftData predicate over
    /// optional strings.
    private var filtered: [Recording] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recordings }

        return recordings.filter { recording in
            recording.title.localizedStandardContains(query)
                // Effective, not raw: text the user removed shouldn't surface a
                // recording in search results.
                || recording.effectiveTranscript.localizedStandardContains(query)
                || (recording.summaryMarkdown ?? "").localizedStandardContains(query)
                || recording.keyPoints.contains { $0.localizedStandardContains(query) }
                || recording.actionItems.contains { $0.localizedStandardContains(query) }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let recording = filtered[index]
            // Delete the audio too, or the container quietly accumulates
            // orphaned files that nothing ever references again.
            AudioStorage.delete(fileName: recording.audioFileName)
            context.delete(recording)
        }
        try? context.save()
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let isWorking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(recording.formattedDuration)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            statusLine
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        if isWorking || recording.status.isWorking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(recording.status.label)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if recording.status.isFailure {
            Label(recording.status.label, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if recording.status == .transcribed {
            Label("Transcribed · no summary", systemImage: "text.alignleft")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let summary = recording.summaryMarkdown, !summary.isEmpty {
            Text(summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}
