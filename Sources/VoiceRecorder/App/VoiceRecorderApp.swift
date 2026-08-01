import SwiftData
import SwiftUI

@main
struct VoiceRecorderApp: App {
    @State private var settings: SettingsStore
    @State private var pipeline: ProcessingPipeline
    @State private var redaction = RedactionService()

    private let container: ModelContainer

    init() {
        let settings = SettingsStore()
        _settings = State(initialValue: settings)
        _pipeline = State(initialValue: ProcessingPipeline(settings: settings))

        do {
            container = try ModelContainer(for: Recording.self)
        } catch {
            // Nothing sensible to fall back to — a broken store means the app
            // can't function, and a silent in-memory container would quietly
            // lose the user's recordings.
            fatalError("Could not create the recordings store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(pipeline)
                .environment(redaction)
        }
        .modelContainer(container)
    }
}
