import AVFoundation
import Foundation
import Observation

/// Playback for the detail view, with scrubbing.
@MainActor
@Observable
final class AudioPlayer {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var delegate: PlayerDelegate?
    private var loadedURL: URL?

    /// Discards any cached player and loads the file again.
    ///
    /// Needed after redaction: the URL is unchanged but the file behind it has
    /// been rewritten, so `load` alone would keep playing the stale duration.
    func reload(url: URL) {
        stop()
        load(url: url)
    }

    func load(url: URL) {
        guard loadedURL != url else { return }
        stop()

        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "The audio file is missing."
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            let delegate = PlayerDelegate { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleFinish()
                }
            }
            player.delegate = delegate

            self.player = player
            self.delegate = delegate
            self.duration = player.duration
            self.currentTime = 0
            self.loadedURL = url
            self.errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            guard player.play() else {
                errorMessage = "Could not play this recording."
                return
            }
            isPlaying = true
            startTimer()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(time, 0), player.duration)
        currentTime = player.currentTime
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func stop() {
        player?.stop()
        stopTimer()
        player = nil
        delegate = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func handleFinish() {
        isPlaying = false
        currentTime = 0
        player?.currentTime = 0
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// `AVAudioPlayer` still wants an NSObject delegate, so this bridges to a closure.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
