import AVFoundation
import SwiftData
import SwiftUI

struct RecordView: View {
    var onFinished: () -> Void

    @Environment(SettingsStore.self) private var settings
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(\.modelContext) private var context

    @State private var recorder = AudioRecorder()
    @State private var templateID: String = SummaryTemplate.meeting.id
    @State private var pendingID: UUID?
    @State private var pendingFileName: String?
    @State private var interruptionNotice: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Text(timeString)
                    .font(.system(size: 64, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                WaveformView(levels: recorder.levels)
                    .frame(height: 90)
                    .padding(.horizontal)

                if case .failed(let message) = recorder.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                templatePicker
                    .disabled(recorder.isActive)
                    .opacity(recorder.isActive ? 0.4 : 1)

                controls
                    .padding(.bottom, 24)
            }
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if !recorder.isActive {
                    templateID = settings.defaultTemplateID
                }
            }
            .onChange(of: recorder.unexpectedStop) { _, stop in
                if let stop { salvage(stop) }
            }
            .alert(
                "Recording stopped",
                isPresented: Binding(
                    get: { interruptionNotice != nil },
                    set: { if !$0 { interruptionNotice = nil } }
                )
            ) {
                Button("OK", role: .cancel) { interruptionNotice = nil }
            } message: {
                Text(interruptionNotice ?? "")
            }
        }
    }

    // MARK: - Pieces

    private var templatePicker: some View {
        VStack(spacing: 8) {
            Text("Summarize as")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Summarize as", selection: $templateID) {
                ForEach(settings.availableTemplates) { template in
                    Label(template.name, systemImage: template.systemImage)
                        .tag(template.id)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var controls: some View {
        // The side buttons are hidden rather than removed when idle, so the
        // record button doesn't jump when recording starts. They need matching
        // fixed widths or the differing label sizes push the centre button
        // off-axis.
        HStack(spacing: 24) {
            Button {
                recorder.cancel()
                pendingID = nil
                pendingFileName = nil
            } label: {
                Text("Cancel")
                    .font(.body)
                    .frame(width: 72)
            }
            .disabled(!recorder.isActive)
            .opacity(recorder.isActive ? 1 : 0)

            Button {
                primaryAction()
            } label: {
                ZStack {
                    Circle()
                        .fill(recorder.state == .recording ? Color.red : Color.accentColor)
                        .frame(width: 84, height: 84)
                    Image(systemName: recorder.state == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.state == .recording ? "Stop recording" : "Start recording")

            Button {
                recorder.state == .paused ? recorder.resume() : recorder.pause()
            } label: {
                Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill")
                    .font(.title2)
                    .frame(width: 72)
            }
            .disabled(!recorder.isActive)
            .opacity(recorder.isActive ? 1 : 0)
        }
    }

    private var timeString: String {
        let total = Int(recorder.elapsed)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Actions

    private func primaryAction() {
        if recorder.isActive {
            finish()
        } else {
            Task {
                if let started = await recorder.start() {
                    pendingID = started.id
                    pendingFileName = started.fileName
                }
            }
        }
    }

    private func finish() {
        guard let id = pendingID, let fileName = pendingFileName else {
            recorder.cancel()
            return
        }

        let duration = recorder.stop() ?? 0
        pendingID = nil
        pendingFileName = nil

        // Sub-second taps are almost always a misfire; keeping them would just
        // litter the library with empty rows that fail transcription.
        guard duration >= 1 else {
            AudioStorage.delete(fileName: fileName)
            return
        }

        let recording = Recording(
            id: id,
            title: placeholderTitle(),
            duration: duration,
            audioFileName: fileName,
            status: .recorded,
            templateID: templateID
        )
        context.insert(recording)
        try? context.save()

        // Deliberately not a `.task` modifier: processing must outlive this
        // view, since we navigate away to the library immediately.
        Task {
            await pipeline.process(recording, context: context)
        }

        onFinished()
    }

    /// Saves the audio captured before an unexpected stop and explains what
    /// happened.
    ///
    /// Losing a partly-recorded meeting because the audio session died is far
    /// worse than keeping a truncated one, so this salvages rather than
    /// discards — but it verifies the file is actually readable first, since a
    /// media-services crash can leave one that was never finalized.
    private func salvage(_ stop: AudioRecorder.UnexpectedStop) {
        defer { recorder.acknowledgeUnexpectedStop() }

        guard let id = pendingID, let fileName = pendingFileName else {
            interruptionNotice = stop.reason
            return
        }
        pendingID = nil
        pendingFileName = nil

        let url = AudioStorage.url(forFileName: fileName)
        let recovered = playableDuration(at: url) ?? stop.duration

        guard recovered >= 1 else {
            AudioStorage.delete(fileName: fileName)
            interruptionNotice = stop.reason + "\n\nNothing usable had been captured yet."
            return
        }

        let recording = Recording(
            id: id,
            title: placeholderTitle(),
            duration: recovered,
            audioFileName: fileName,
            status: .recorded,
            templateID: templateID
        )
        context.insert(recording)
        try? context.save()

        Task { await pipeline.process(recording, context: context) }

        interruptionNotice = stop.reason
            + "\n\nThe \(format(recovered)) recorded before that has been saved and is being transcribed."
        onFinished()
    }

    /// Reads the duration back off disk. Returns nil when the file can't be
    /// decoded, which is the signal that it was never finalized.
    ///
    /// `AVAudioPlayer` rather than `AVURLAsset` because it answers synchronously
    /// and refuses to construct at all on an unplayable file — which is the
    /// question being asked here, not just how long it claims to be.
    private func playableDuration(at url: URL) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path),
              let player = try? AVAudioPlayer(contentsOf: url),
              player.duration > 0
        else { return nil }
        return player.duration
    }

    private func format(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        if total < 60 { return "\(total)s" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func placeholderTitle() -> String {
        "New Recording \(Date().formatted(date: .abbreviated, time: .shortened))"
    }
}
