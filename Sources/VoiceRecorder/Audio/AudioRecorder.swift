import AVFoundation
import Foundation
import Observation

/// Wraps `AVAudioRecorder` for the record screen.
///
/// `AVAudioRecorder` writes to its destination file progressively, so a crash or
/// force-quit mid-recording leaves a valid, playable `.m4a` rather than nothing.
/// That's the main reason this uses `AVAudioRecorder` rather than tapping the
/// engine and assembling a file at the end.
@MainActor
@Observable
final class AudioRecorder {
    enum State: Equatable {
        case idle
        case recording
        case paused
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0

    /// Recent normalized power values (0...1), newest last. Drives the waveform.
    private(set) var levels: [Float] = []

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var currentFileName: String?

    /// True when the system interrupted us (call, Siri) and we expect to resume.
    private var interrupted = false

    private let maxLevels = 60

    var isActive: Bool {
        state == .recording || state == .paused
    }

    // MARK: - Permission

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static var permissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    static var permissionDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    // MARK: - Lifecycle

    init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleInterruption(note)
            }
        }
    }

    /// Begins recording into a new file. Returns the file name and the id it was
    /// derived from so the caller can build the `Recording` model.
    @discardableResult
    func start() async -> (id: UUID, fileName: String)? {
        guard await Self.requestPermission() else {
            state = .failed("Microphone access denied. Enable it in Settings › Privacy › Microphone.")
            return nil
        }

        let id = UUID()
        let fileName = AudioStorage.fileName(for: id)
        let url = AudioStorage.url(forFileName: fileName)

        do {
            let session = AVAudioSession.sharedInstance()
            // .playAndRecord (not .record) so playback in the detail view doesn't
            // need a category swap, and .defaultToSpeaker so playback isn't stuck
            // on the quiet earpiece.
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)

            // Shared with the watch so both devices produce identical files.
            let recorder = try AVAudioRecorder(url: url, settings: RecordingFormat.settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                state = .failed("Could not start recording.")
                return nil
            }

            self.recorder = recorder
            self.currentFileName = fileName
            self.elapsed = 0
            self.levels = []
            self.state = .recording
            startTimer()
            return (id, fileName)
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }

    func pause() {
        guard state == .recording, let recorder else { return }
        recorder.pause()
        state = .paused
        stopTimer()
    }

    func resume() {
        guard state == .paused, let recorder else { return }
        guard recorder.record() else {
            state = .failed("Could not resume recording.")
            return
        }
        state = .recording
        startTimer()
    }

    /// Stops and finalizes the file. Returns the duration captured, or nil if
    /// nothing was recording.
    @discardableResult
    func stop() -> TimeInterval? {
        guard let recorder else { return nil }
        let duration = recorder.currentTime > 0 ? recorder.currentTime : elapsed
        recorder.stop()
        stopTimer()
        self.recorder = nil
        self.currentFileName = nil
        self.state = .idle
        self.elapsed = 0
        self.levels = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return duration
    }

    /// Stops and discards. Used when the user cancels or permission vanishes.
    func cancel() {
        let fileName = currentFileName
        _ = stop()
        if let fileName {
            AudioStorage.delete(fileName: fileName)
        }
    }

    // MARK: - Metering

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        // .common so the timer keeps firing while the user scrolls.
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

        // averagePower is dBFS, roughly -160 (silence) to 0 (peak). Anything
        // below -50 dB is inaudible in practice, so clamp there and rescale to
        // 0...1 — otherwise the waveform is a flat line pinned near zero.
        let db = recorder.averagePower(forChannel: 0)
        let floor: Float = -50
        let normalized = db < floor ? 0 : (db + (-floor)) / (-floor)

        levels.append(min(max(normalized, 0), 1))
        if levels.count > maxLevels {
            levels.removeFirst(levels.count - maxLevels)
        }
    }

    // MARK: - Interruptions

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            if state == .recording {
                interrupted = true
                pause()
            }
        case .ended:
            guard interrupted else { return }
            interrupted = false
            // The system tells us whether resuming is appropriate. If it doesn't
            // say "shouldResume", we stay paused and let the user decide rather
            // than fighting whatever took the session.
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                resume()
            }
        @unknown default:
            break
        }
    }
}
