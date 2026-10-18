import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct ConfigurationTests {
    @Test("the defaults are the default source, persistent storage and the library's session")
    func defaults() {
        let configuration = WebFonts.Configuration()
        #expect(configuration.source is DefaultFontSource)
        #expect(configuration.storage == .persistent)
        #expect(configuration.directory == nil)
        #expect(configuration.session == nil)
        #expect(Snapshot(configuration, sourceID: 0, root: nil).session === LibrarySession.shared)
    }

    @Test(
        "each first-use trigger starts warm-up exactly once; the first-frame check starts none",
        arguments: ["events", "downloaded", "load", "loadEmpty", "batch", "batchEmpty", "remove", "removeAll"]
    )
    func firstUse(trigger: String) async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        try harness.storeFont(Fixtures.lobster, family: "Lobster", version: "v1")
        let fonts = harness.makeFonts()
        _ = fonts.postScriptName(family: "Lobster", style: .regular)
        #expect(fonts.startedWarmUps == 0)
        for _ in 0..<2 {
            switch trigger {
            case "events": _ = fonts.events
            case "downloaded": _ = fonts.downloaded
            case "load": try await fonts.loadOrThrow("Lobster")
            case "loadEmpty": try await fonts.loadOrThrow("Lobster", styles: [])
            case "batch": await fonts.load(["Lobster"])
            case "batchEmpty": await fonts.load([])
            case "remove": try await fonts.remove("Inter")
            default: try await fonts.removeAll()
            }
            #expect(fonts.startedWarmUps == 1)
        }
        await fonts.waitForWarmUp()
        #expect(harness.registrar.calls(.register).count >= 1)
    }

    @Test("a directory change re-warms; a source-only change does not")
    func directoryChange() async throws {
        let harness = Harness()
        let other = TempDirectory()
        try harness.storeFont(Fixtures.lobster, family: "Lobster", version: "v1")
        try Fixtures.storeFont(Fixtures.latoRegular, family: "Inter", in: other.store, cacheKey: "Inter|400|n", version: "v1")

        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        fonts.configure(WebFonts.Configuration(directory: other.url, session: harness.session))
        #expect(fonts.startedWarmUps == 2)
        try await events.wait { $0.filter { if case .warmedUp = $0 { true } else { false } }.count == 2 }
        #expect(fonts.postScriptName(family: "Inter", style: .regular) == "Lato-Regular")

        fonts.configure(WebFonts.Configuration(source: .hosted(at: URL(string: "https://cdn.example.test")!), directory: other.url, session: harness.session))
        #expect(fonts.startedWarmUps == 2)
    }

    @Test("configuring WebFonts.shared first warms the configured directory, not the default one")
    func shared() async {
        // The only test that touches WebFonts.shared, so it is configured before any use.
        let directory = TempDirectory()
        WebFonts.shared.configure(WebFonts.Configuration(storage: .persistent, directory: directory.url))
        await WebFonts.shared.waitForWarmUp()
        #expect(WebFonts.shared.startedWarmUps == 1, "only the configured directory was warmed")
        // shared reads the shipped catalogue while it is current.
        #expect((WebFonts.shared.catalog() != nil) == (GoogleFontsCatalog.shipped()?.isCurrent(at: .now) == true))

        let warmed = WebFonts.shared.state.withLock { $0.current.directory }
        #expect(warmed.path == directory.store.path)
        #expect(warmed.path != StoreLocation.directory(isSession: false, configured: nil, root: nil).path)
        // Warm-up creates the store folder, so it ran here while the directory still existed.
        #expect(FileManager.default.fileExists(atPath: directory.store.path))
    }
}
