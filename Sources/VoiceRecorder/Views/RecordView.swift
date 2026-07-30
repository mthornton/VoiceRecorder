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

    private func placeholderTitle() -> String {
        "New Recording \(Date().formatted(date: .abbreviated, time: .shortened))"
    }
}
