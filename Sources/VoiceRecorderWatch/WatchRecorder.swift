import AVFoundation
import Foundation
import Observation

/// Records audio using the watch's own microphone.
///
/// The watch never transcribes — `Speech.framework` doesn't exist on watchOS —
/// so this only has to capture a clean file and hand it to
/// `WatchTransferService` for delivery to the phone.
@MainActor
@Observable
final class WatchRecorder {
    enum State: Equatable {
        case idle
        case recording
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var currentID: UUID?
    private var startedAt: Date?

    var isRecording: Bool { state == .recording }

    /// Watch recordings live in a temporary directory: once the file reaches the
    /// phone it is deleted, and the phone is the only place a recording is meant
    /// to persist. Keeping copies on a device with a few GB of storage would be
    /// a poor trade.
    private static var recordingsDirectory: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchRecordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func start() async {
        guard state != .recording else { return }

        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed("Microphone access denied.")
            return
        }

        let id = UUID()
        let url = Self.recordingsDirectory
            .appendingPathComponent("\(id.uuidString).\(RecordingFormat.fileExtension)")

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let recorder = try AVAudioRecorder(url: url, settings: RecordingFormat.settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                state = .failed("Couldn't start recording.")
                return
            }

            self.recorder = recorder
            self.currentID = id
            self.startedAt = Date()
            self.elapsed = 0
            self.state = .recording
            startTimer()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Finishes the recording and returns everything the phone needs to
    /// reconstruct it. Returns nil if nothing usable was captured.
    func stop() -> (id: UUID, url: URL, duration: TimeInterval, startedAt: Date)? {
        guard let recorder, let id = currentID, let startedAt else { return nil }

        let duration = recorder.currentTime > 0 ? recorder.currentTime : elapsed
        let url = recorder.url
        recorder.stop()
        stopTimer()

        self.recorder = nil
        self.currentID = nil
        self.startedAt = nil
        self.state = .idle
        self.elapsed = 0
        self.level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // A stray tap isn't worth a transfer, and an empty file would just fail
        // transcription on the other end.
        guard duration >= 1 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        return (id, url, duration, startedAt)
    }

    func cancel() {
        guard let recorder else { return }
        let url = recorder.url
        _ = stop()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Metering

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime

        // Same dBFS-to-0...1 mapping as the phone: below -50 dB is inaudible in
        // practice, so clamp there rather than showing a flat line near zero.
        let db = recorder.averagePower(forChannel: 0)
        let floor: Float = -50
        level = db < floor ? 0 : min(max((db + (-floor)) / (-floor), 0), 1)
    }
}
