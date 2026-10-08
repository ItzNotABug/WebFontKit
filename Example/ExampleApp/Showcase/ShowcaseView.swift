import SwiftUI
import WebFontKit

/// The demo: try any family, browse a gallery, see what is stored, and watch events.
struct ShowcaseView: View {
    enum Tab: Int, CaseIterable {
        case play, gallery, library, activity

        /// `-ExampleTab <n>` opens a tab directly, for screenshots.
        static var atLaunch: Tab {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-ExampleTab"), index + 1 < arguments.count,
                  let raw = Int(arguments[index + 1]) else { return .play }
            return Tab(rawValue: raw) ?? .play
        }
    }

    @State private var library = FontLibrary()
    @State private var events = EventLog()
    @State private var tab = Tab.atLaunch

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { TryView() }
                .tabItem { Label("Try", systemImage: "textformat.size") }.tag(Tab.play)
            GalleryView()
                .tabItem { Label("Gallery", systemImage: "square.grid.2x2.fill") }.tag(Tab.gallery)
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "internaldrive.fill") }.tag(Tab.library)
            NavigationStack { EventsView() }
                .tabItem { Label("Activity", systemImage: "waveform.path.ecg") }.tag(Tab.activity)
        }
        .tint(Theme.accent)
        .environment(library)
        .environment(events)
        // Both live as long as the window: each `events` access is its own stream.
        .task { await library.listen() }
        .task { await events.listen() }
    }
}
