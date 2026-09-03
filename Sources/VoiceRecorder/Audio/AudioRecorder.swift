import AVFoundation
import Foundation
import Observation

/// Wraps `AVAudioRecorder` for the record screen.
///
/// `AVAudioRecorder` writes to its destination file progressively, so a crash or
/// force-quit mid-recording leaves a valid, playable `.m4a` rather than nothing.
/// That's the main reason this uses `AVAudioRecorder` rather than tapping the
/// engine and assembling a file at the end.
///
/// ## Why there is so much failure plumbing
///
/// With `UIBackgroundModes: audio` iOS imposes no time limit on recording while
/// locked — but the session can still die underneath us: `mediaserverd`
/// restarts, an input device disappears, the encoder hits a full disk. Every one
/// of those stops the recorder without stopping this object, and the original
/// implementation simply froze: the metering timer no-opped, `state` still said
/// `.recording`, and the UI kept insisting all was well while capturing nothing.
/// Whatever the cause, the recorder must notice, save what it has, and say so.
@MainActor
@Observable
final class AudioRecorder: NSObject {
    enum State: Equatable {
        case idle
        case recording
        case paused
        case failed(String)
    }

    /// A recording that ended without the user asking it to.
    ///
    /// Carries the audio captured before the failure so the caller can save it —
    /// a truncated recording of a meeting is far better than none.
    struct UnexpectedStop: Equatable {
        let reason: String
        let duration: TimeInterval
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0

    /// Recent normalized power values (0...1), newest last. Drives the waveform.
    private(set) var levels: [Float] = []

    /// Set when recording ended on its own. The caller observes this, salvages
    /// the audio, and calls `acknowledgeUnexpectedStop()`.
    private(set) var unexpectedStop: UnexpectedStop?

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

    override init() {
        super.init()
        observeSessionNotifications()
    }

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        }

        // mediaserverd can restart at any time. Every audio object becomes
        // invalid when it does, and Apple requires apps to observe this and
        // rebuild — without it, recording dies with no signal at all.
        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleFatalSessionLoss(
                    reason: "The system's audio service restarted, which stopped the recording."
                )
            }
        }

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
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
            recorder.delegate = self
            guard recorder.record() else {
                state = .failed("Could not start recording.")
                return nil
            }

            self.recorder = recorder
            self.currentFileName = fileName
            self.elapsed = 0
            self.levels = []
            self.unexpectedStop = nil
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
        // Safe only from paused: record() after stop() restarts the file from
        // zero and would overwrite everything captured so far.
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
        teardown()
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

    func acknowledgeUnexpectedStop() {
        unexpectedStop = nil
        if case .failed = state { state = .idle }
    }

    private func teardown() {
        stopTimer()
        recorder?.delegate = nil
        recorder = nil
        currentFileName = nil
        state = .idle
        elapsed = 0
        levels = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Unexpected termination

    /// Ends the recording because something outside our control stopped it,
    /// preserving whatever was captured.
    private func reportUnexpectedStop(reason: String) {
        guard isActive else { return }

        let captured = recorder.map { $0.currentTime > 0 ? $0.currentTime : elapsed } ?? elapsed
        // Harmless if the recorder is already dead, and it's the only chance of
        // the file being finalized properly if it isn't.
        recorder?.stop()

        stopTimer()
        recorder?.delegate = nil
        recorder = nil
        state = .failed(reason)
        levels = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        unexpectedStop = UnexpectedStop(reason: reason, duration: captured)
    }

    private func handleFatalSessionLoss(reason: String) {
        guard isActive else { return }
        reportUnexpectedStop(reason: reason)
    }

    private func handleRouteChange(_ note: Notification) {
        guard isActive,
              let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }

        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .override, .categoryChange:
            // Losing or gaining an input (AirPods disconnecting, a headset going
            // in) can take the session down with it. Try to keep going; the
            // watchdog below reports it if the recorder didn't survive.
            try? AVAudioSession.sharedInstance().setActive(true)
            if state == .recording, recorder?.isRecording == false {
                reportUnexpectedStop(
                    reason: "The audio input changed — probably headphones or a Bluetooth device — and recording stopped."
                )
            }
        default:
            break
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
        guard let recorder else { return }

        // The watchdog. Whatever killed the recording — including causes not
        // enumerated above — this notices within 50ms instead of freezing the
        // timer and leaving the UI claiming to still be recording.
        guard recorder.isRecording else {
            if state == .recording {
                reportUnexpectedStop(reason: "Recording stopped unexpectedly.")
            }
            return
        }

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

            // Previously this gave up silently when the system didn't set
            // .shouldResume, leaving a paused recording nobody was told about.
            // We hold the audio background mode, so try regardless and report if
            // it genuinely can't continue.
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                resume()
            } catch {
                reportUnexpectedStop(
                    reason: "Another app took over audio and recording couldn't resume."
                )
            }
        @unknown default:
            break
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioRecorder: AVAudioRecorderDelegate {
    /// Fires when the recorder finishes on its own. If we didn't ask for it,
    /// something went wrong — a full disk being the usual cause.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        MainActor.assumeIsolated {
            guard isActive else { return }
            reportUnexpectedStop(
                reason: flag
                    ? "Recording ended unexpectedly."
                    : "Recording failed to finish writing — the device may be out of storage."
            )
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let detail = error?.localizedDescription
        MainActor.assumeIsolated {
            guard isActive else { return }
            reportUnexpectedStop(
                reason: detail.map { "Audio encoding failed: \($0)" }
                    ?? "Audio encoding failed and recording stopped."
            )
        }
    }
}
