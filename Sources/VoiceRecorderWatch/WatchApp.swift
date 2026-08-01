import SwiftUI

@main
struct VoiceRecorderWatchApp: App {
    @State private var recorder = WatchRecorder()
    @State private var transfer = WatchTransferService()

    var body: some Scene {
        WindowGroup {
            WatchRecordView()
                .environment(recorder)
                .environment(transfer)
        }
    }
}
