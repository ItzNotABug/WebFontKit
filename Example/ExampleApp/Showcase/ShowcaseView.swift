import SwiftUI
import WebFontKit

/// The demo: try any family, browse a gallery, see what is stored, and watch events.
struct ShowcaseView: View {
    enum Screen: Int {
        case tryIt, gallery, library, activity

        /// `-ExampleTab <n>` opens a tab directly, for screenshots.
        static var atLaunch: Screen {
            Screen(rawValue: UserDefaults.standard.integer(forKey: "ExampleTab")) ?? .tryIt
        }
    }

    @State private var library = FontLibrary()
    @State private var events = EventLog()
    @State private var screen = Screen.atLaunch
    @State private var tryModel = TryModel()

    var body: some View {
        TabView(selection: $screen) {
            NavigationStack { TryView(model: tryModel) }
                .tabItem { Label("Try", systemImage: "textformat.size") }.tag(Screen.tryIt)
            GalleryView()
                .tabItem { Label("Gallery", systemImage: "square.grid.2x2") }.tag(Screen.gallery)
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "internaldrive") }.tag(Screen.library)
            NavigationStack { EventsView() }
                .tabItem { Label("Activity", systemImage: "waveform.path.ecg") }.tag(Screen.activity)
        }
        .tint(Theme.accent)
        .environment(library)
        .environment(events)
        // Both live as long as the window: each `events` access is its own stream.
        .task { await library.listen() }
        .task { await events.listen() }
    }
}
