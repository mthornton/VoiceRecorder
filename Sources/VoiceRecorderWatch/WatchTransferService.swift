import Foundation
import Observation
import WatchConnectivity

/// Sends finished watch recordings to the phone.
///
/// `transferFile` is the right primitive here rather than `sendMessage`: it
/// survives the phone being out of range or its app not running, queues on disk,
/// retries on the system's schedule, and wakes the iOS app in the background to
/// deliver. The user can record on a walk with the phone at home and the audio
/// arrives when they're back in range.
@MainActor
@Observable
final class WatchTransferService: NSObject {
    enum Status: Equatable {
        case idle
        case sending(remaining: Int)
        case sent
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var isReachable = false

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    override init() {
        super.init()
        activate()
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Queues a recording for delivery. The file is handed to the system, which
    /// owns retrying it from here on.
    func send(id: UUID, url: URL, duration: TimeInterval, startedAt: Date) {
        guard let session else {
            status = .failed("This watch can't talk to the iPhone.")
            return
        }

        let metadata: [String: Any] = [
            WatchTransfer.MetadataKey.id: id.uuidString,
            WatchTransfer.MetadataKey.startedAt: startedAt.timeIntervalSince1970,
            WatchTransfer.MetadataKey.duration: duration,
            WatchTransfer.MetadataKey.source: RecordingSource.watch.rawValue,
        ]

        session.transferFile(url, metadata: metadata)
        refreshPendingCount()
    }

    private func refreshPendingCount() {
        guard let session else { return }
        let remaining = session.outstandingFileTransfers.count
        status = remaining > 0 ? .sending(remaining: remaining) : .sent
    }

    var pendingCount: Int {
        session?.outstandingFileTransfers.count ?? 0
    }
}

extension WatchTransferService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            if let error {
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let url = fileTransfer.file.fileURL
        Task { @MainActor in
            if let error {
                self.status = .failed(error.localizedDescription)
                // Deliberately keep the file: the system may retry, and losing
                // audio that never reached the phone would be unrecoverable.
                return
            }

            // Delivered — the phone now owns this recording, so the watch copy
            // goes. Watch storage is small and this is the only safe moment to
            // reclaim it.
            try? FileManager.default.removeItem(at: url)
            self.refreshPendingCount()
        }
    }
}
