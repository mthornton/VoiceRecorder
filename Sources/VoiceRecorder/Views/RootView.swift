import SwiftUI

/// Named `AppTab` rather than `Tab` because SwiftUI's own `Tab` view is used
/// below — a nested `Tab` enum shadows it and breaks the TabView builder.
enum AppTab: Hashable {
    case record, library, settings
}

struct RootView: View {
    @State private var selection = AppTab.record

    var body: some View {
        TabView(selection: $selection) {
            Tab("Record", systemImage: "mic.circle.fill", value: AppTab.record) {
                RecordView(onFinished: { selection = .library })
            }
            Tab("Library", systemImage: "list.bullet", value: AppTab.library) {
                LibraryView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
    }
}
