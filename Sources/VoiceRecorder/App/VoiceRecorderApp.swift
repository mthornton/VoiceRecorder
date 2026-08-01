import SwiftData
import SwiftUI

@main
struct VoiceRecorderApp: App {
    @State private var settings: SettingsStore
    @State private var pipeline: ProcessingPipeline
    @State private var redaction = RedactionService()
    @State private var connectivity: PhoneConnectivityService

    private let container: ModelContainer

    init() {
        let settings = SettingsStore()
        let pipeline = ProcessingPipeline(settings: settings)
        _settings = State(initialValue: settings)
        _pipeline = State(initialValue: pipeline)

        let container: ModelContainer
        do {
            container = try ModelContainer(for: Recording.self)
        } catch {
            // Nothing sensible to fall back to — a broken store means the app
            // can't function, and a silent in-memory container would quietly
            // lose the user's recordings.
            fatalError("Could not create the recordings store: \(error)")
        }
        self.container = container

        // Activated during init rather than in a view's task, because iOS
        // launches the app in the background purely to deliver a watch
        // transfer — there may be no view on screen to trigger it.
        _connectivity = State(
            initialValue: PhoneConnectivityService(container: container, pipeline: pipeline)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(pipeline)
                .environment(redaction)
                .environment(connectivity)
        }
        .modelContainer(container)
    }
}
