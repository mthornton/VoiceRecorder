import SwiftData
import SwiftUI

struct RecordingDetailView: View {
    @Bindable var recording: Recording

    @Environment(SettingsStore.self) private var settings
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(\.modelContext) private var context

    @State private var player = AudioPlayer()
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var showTranscript = false

    private var isWorking: Bool {
        pipeline.isActive(recording) || recording.status.isWorking
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                PlayerControls(player: player)
                statusSection
                summarySection
                transcriptSection
            }
            .padding()
        }
        .navigationTitle(recording.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear { player.load(url: recording.audioURL) }
        .onDisappear { player.stop() }
        .alert("Rename Recording", isPresented: $isRenaming) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    recording.title = trimmed
                    try? context.save()
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recording.title)
                .font(.title2.bold())

            HStack(spacing: 6) {
                Text(recording.createdAt.formatted(date: .long, time: .shortened))
                Text("·")
                Text(recording.formattedDuration)
                if let size = AudioStorage.fileSize(forFileName: recording.audioFileName) {
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if isWorking {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.status.label)
                        .font(.subheadline.weight(.medium))
                    if recording.status == .transcribing {
                        Text("Running on this device. The first run may download a speech model.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))

        } else if recording.status.isFailure {
            VStack(alignment: .leading, spacing: 10) {
                Label(recording.status.label, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                if let message = recording.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Try Again") { retry() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.orange.opacity(0.1), in: .rect(cornerRadius: 12))

        } else if recording.status == .transcribed && !settings.hasAPIKey {
            // Not a failure — the app works fine without a key, and the summary
            // is the only thing gated on having one.
            VStack(alignment: .leading, spacing: 10) {
                Label("No summary yet", systemImage: "key.horizontal")
                    .font(.subheadline.weight(.semibold))
                Text("Add an OpenRouter API key in Settings to generate summaries. The transcript below is already saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if recording.hasSummary {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("Summary", systemImage: "sparkles")
                MarkdownText(recording.summaryMarkdown ?? "")

                if !recording.keyPoints.isEmpty {
                    sectionHeader("Key Points", systemImage: "list.bullet")
                    BulletList(items: recording.keyPoints, symbol: "circle.fill")
                }

                if !recording.actionItems.isEmpty {
                    sectionHeader("Action Items", systemImage: "checkmark.circle")
                    BulletList(items: recording.actionItems, symbol: "square")
                }

                footerAttribution
            }
        }
    }

    @ViewBuilder
    private var footerAttribution: some View {
        let template = settings.template(withID: recording.templateID)
        HStack(spacing: 4) {
            Image(systemName: template.systemImage)
            Text(template.name)
            if let model = recording.modelID {
                Text("·")
                Text(CuratedModel.name(forID: model))
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if recording.hasTranscript {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.snappy) { showTranscript.toggle() }
                } label: {
                    HStack {
                        sectionHeader("Transcript", systemImage: "text.alignleft")
                        Spacer()
                        Image(systemName: showTranscript ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if showTranscript {
                    Text(recording.transcript ?? "")
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    draftTitle = recording.title
                    isRenaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                if recording.hasTranscript {
                    Menu {
                        ForEach(settings.availableTemplates) { template in
                            Button {
                                resummarize(with: template)
                            } label: {
                                Label(template.name, systemImage: template.systemImage)
                            }
                        }
                    } label: {
                        Label("Regenerate Summary", systemImage: "arrow.clockwise")
                    }
                    .disabled(isWorking || !settings.hasAPIKey)
                }

                Divider()

                ShareLink(item: recording.exportText()) {
                    Label("Share Text", systemImage: "doc.text")
                }
                ShareLink(item: recording.audioURL) {
                    Label("Share Audio", systemImage: "waveform")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Actions

    private func retry() {
        Task { await pipeline.process(recording, context: context) }
    }

    private func resummarize(with template: SummaryTemplate) {
        Task { await pipeline.resummarize(recording, template: template, context: context) }
    }
}

// MARK: - Supporting views

private struct PlayerControls: View {
    @Bindable var player: AudioPlayer

    var body: some View {
        VStack(spacing: 8) {
            if let error = player.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.01)
            )

            HStack {
                Text(timeString(player.currentTime))
                Spacer()
                Text("-" + timeString(max(player.duration - player.currentTime, 0)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 36) {
                Button { player.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15").font(.title2)
                }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                }
                Button { player.skip(by: 15) } label: {
                    Image(systemName: "goforward.15").font(.title2)
                }
            }
            .buttonStyle(.plain)
            .disabled(player.duration == 0)
        }
        .padding()
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 16))
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Renders the model's markdown a paragraph at a time.
///
/// SwiftUI's `Text` handles inline markdown (bold, italic, links) but collapses
/// multi-paragraph strings onto one line, so paragraphs are split here and
/// rendered individually.
private struct MarkdownText: View {
    let markdown: String

    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(LocalizedStringKey(paragraph))
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var paragraphs: [String] {
        markdown
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct BulletList: View {
    let items: [String]
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: symbol == "square" ? 12 : 6))
                        .foregroundStyle(.tint)
                    Text(item)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
