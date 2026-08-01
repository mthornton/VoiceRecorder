import Foundation
import Observation
import SwiftData
import WatchConnectivity

/// Receives recordings transferred from the watch and feeds them into the
/// normal processing pipeline.
///
/// iOS launches the app in the background to deliver a `WCSession` file
/// transfer, so a recording made on a walk lands and starts transcribing without
/// the user opening anything.
@MainActor
@Observable
final class PhoneConnectivityService: NSObject {
    private(set) var lastReceivedAt: Date?
    private(set) var lastError: String?

    private let container: ModelContainer
    private let pipeline: ProcessingPipeline

    init(container: ModelContainer, pipeline: ProcessingPipeline) {
        self.container = container
        self.pipeline = pipeline
        super.init()
        activate()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Creates the `Recording` for an arriving file and starts processing it.
    ///
    /// `audioFileName` refers to a file already moved into place by the delegate
    /// — see the note there about why that can't wait.
    fileprivate func ingest(
        id: UUID,
        audioFileName: String,
        duration: TimeInterval,
        startedAt: Date,
        source: RecordingSource
    ) {
        let context = container.mainContext

        // The watch generated the id, so a transfer the system retried and
        // delivered twice is recognisable rather than becoming a duplicate.
        let existing = try? context.fetch(
            FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        )
        guard existing?.isEmpty ?? true else {
            AudioStorage.delete(fileName: audioFileName)
            return
        }

        let recording = Recording(
            id: id,
            title: "New Recording \(startedAt.formatted(date: .abbreviated, time: .shortened))",
            createdAt: startedAt,
            duration: duration,
            audioFileName: audioFileName,
            status: .recorded
        )
        recording.sourceRaw = source.rawValue

        context.insert(recording)
        try? context.save()

        lastReceivedAt = Date()
        lastError = nil

        Task { await pipeline.process(recording, context: context) }
    }
}

extension PhoneConnectivityService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            Task { @MainActor in self.lastError = error.localizedDescription }
        }
    }

    // Required on iOS so the session can be handed to a newly paired watch.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The inbox file is deleted as soon as this method returns, so it has to
        // be moved synchronously here — hopping to the main actor first would
        // race against that deletion and lose the recording.
        let metadata = file.metadata ?? [:]

        let id = (metadata[WatchTransfer.MetadataKey.id] as? String)
            .flatMap(UUID.init(uuidString:)) ?? UUID()
        let fileName = AudioStorage.fileName(for: id)
        let destination = AudioStorage.url(forFileName: fileName)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
        } catch {
            Task { @MainActor in
                self.lastError = "Couldn't save the recording from your watch. \(error.localizedDescription)"
            }
            return
        }

        let startedAt = (metadata[WatchTransfer.MetadataKey.startedAt] as? TimeInterval)
            .map(Date.init(timeIntervalSince1970:)) ?? Date()
        let duration = metadata[WatchTransfer.MetadataKey.duration] as? TimeInterval ?? 0
        let source = (metadata[WatchTransfer.MetadataKey.source] as? String)
            .flatMap(RecordingSource.init(rawValue:)) ?? .watch

        Task { @MainActor in
            self.ingest(
                id: id,
                audioFileName: fileName,
                duration: duration,
                startedAt: startedAt,
                source: source
            )
        }
    }
}
