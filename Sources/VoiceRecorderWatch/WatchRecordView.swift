import SwiftUI
import WatchKit

struct WatchRecordView: View {
    @Environment(WatchRecorder.self) private var recorder
    @Environment(WatchTransferService.self) private var transfer

    var body: some View {
        VStack(spacing: 10) {
            Text(timeString)
                .font(.system(size: 34, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            levelMeter
                .frame(height: 6)

            recordButton

            statusLine
                .frame(minHeight: 26)
        }
        .padding(.horizontal, 6)
    }

    private var levelMeter: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(recorder.isRecording ? Color.red : Color.secondary)
                    .frame(width: geometry.size.width * CGFloat(recorder.level))
                    .animation(.linear(duration: 0.1), value: recorder.level)
            }
        }
    }

    private var recordButton: some View {
        Button {
            toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 62, height: 62)
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
    }

    @ViewBuilder
    private var statusLine: some View {
        if case .failed(let message) = recorder.state {
            Text(message)
                .font(.caption2)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        } else if recorder.isRecording {
            Text("Recording on Apple Watch")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            switch transfer.status {
            case .sending(let remaining):
                Label(
                    remaining == 1 ? "Sending to iPhone" : "Sending \(remaining) to iPhone",
                    systemImage: "arrow.up.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            case .sent:
                Label("Sent to iPhone", systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            case .idle:
                // Queued transfers survive the phone being away, so being out of
                // range is worth showing but isn't a reason not to record.
                Text(transfer.isReachable ? "Ready" : "iPhone not in range")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timeString: String {
        let total = Int(recorder.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func toggle() {
        if recorder.isRecording {
            if let finished = recorder.stop() {
                transfer.send(
                    id: finished.id,
                    url: finished.url,
                    duration: finished.duration,
                    startedAt: finished.startedAt
                )
                WKInterfaceDevice.current().play(.success)
            }
        } else {
            Task {
                await recorder.start()
                if recorder.isRecording {
                    WKInterfaceDevice.current().play(.start)
                }
            }
        }
    }
}
