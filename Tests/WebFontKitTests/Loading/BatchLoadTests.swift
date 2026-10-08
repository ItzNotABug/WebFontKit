import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct BatchLoadTests {
    @Test("a batch never throws, reports each family in the order asked, and loads duplicates once")
    func batch() async throws {
        let harness = Harness()
        harness.serveGoogle()
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)

        let results = await fonts.load(["Lobster", "Lobstr", "Inter", "Lobster"])

        #expect(results.map(\.family) == ["Lobster", "Lobstr", "Inter"])
        #expect(results.succeeded == ["Lobster", "Inter"])
        #expect(results.failed.map(\.family) == ["Lobstr"])
        #expect(!results.allSucceeded)
        if case .failure(.notFound)? = results["Lobstr"] {} else { Issue.record("Lobstr: \(String(describing: results["Lobstr"]))") }
        #expect(results["NotAsked"] == nil)
        #expect(harness.server.requests.count { $0.url.absoluteString.contains("family=Lobster:") } == 1)
        #expect(harness.server.requests.filter { harness.isCSS2($0.url) }.allSatisfy { $0.url.query?.hasSuffix("ital,wght@0,400") == true })
    }

    @Test("an empty batch succeeds and starts warm-up once")
    func emptyBatch() async {
        let harness = Harness()
        let fonts = harness.makeFonts()
        let results = await fonts.load([])
        #expect(results.allSucceeded)
        #expect(fonts.startedWarmUps == 1)
    }

    @Test("a family overtaken by remove is absent from the results, and the others are returned")
    func overtakenFamily() async throws {
        let harness = Harness()
        harness.serveGoogle(holdFiles: true)
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)

        let batch = Task { await fonts.load(["Lobster", "Inter"]) }
        try await harness.server.waitForRequests(count: 2) { harness.isFontFile($0) }
        try await fonts.remove("Lobster")
        harness.server.releaseAll()
        let results = await batch.value

        #expect(results["Lobster"] == nil)
        #expect(results.succeeded == ["Inter"])
        #expect(results.failed.isEmpty)
        #expect(!results.allSucceeded)
        #expect(harness.server.requests.count { $0.url.absoluteString.contains("family=Lobster:") } == 1)
    }

    @Test("cancelling a batch returns what finished, without the unfinished families")
    func cancelledBatch() async throws {
        let harness = Harness()
        harness.serveGoogle(holdFiles: true)
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        let batch = Task { await fonts.load(["Lobster"]) }
        try await harness.server.waitForRequests { harness.isFontFile($0) }
        batch.cancel()
        let results = await batch.value
        #expect(results["Lobster"] == nil)
        #expect(!results.allSucceeded)
        harness.server.releaseAll()
    }
}

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
        harness.serveGoogle()
        try harness.storeFont(Fixtures.lobster, family: "Lobster", version: "v1")
        let fonts = harness.makeFonts()
        _ = fonts.postScriptName(family: "Lobster", style: .regular)
        #expect(fonts.startedWarmUps == 0)
        for _ in 0..<2 {
            switch trigger {
            case "events": _ = fonts.events
            case "downloaded": _ = fonts.downloaded
            case "load": try await fonts.load("Lobster")
            case "loadEmpty": try await fonts.load("Lobster", styles: [])
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
        let otherStore = Store(directory: other.store, files: harness.files)
        try otherStore.files.createDirectory(at: otherStore.directory)
        let interURL = otherStore.url(for: StoredFileName.font(family: "Inter", style: .regular, cacheKey: "Inter|400|n", version: "v1"))
        try Fixtures.data(Fixtures.latoRegular).write(to: interURL)

        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        fonts.configure(WebFonts.Configuration(directory: other.url, session: harness.session))
        #expect(fonts.startedWarmUps == 2)
        try await events.wait { $0.filter { if case .warmedUp = $0 { true } else { false } }.count == 2 }
        #expect(fonts.postScriptName(family: "Inter", style: .regular) == "Lato-Regular")

        fonts.configure(WebFonts.Configuration(source: .hosted(at: URL(string: "https://cdn.example.test")!), directory: other.url, session: harness.session))
        #expect(fonts.startedWarmUps == 2)
    }

    @Test("WebFonts.shared exists, and configuring it first never warms the real default directory")
    func shared() {
        let directory = TempDirectory()
        WebFonts.shared.configure(WebFonts.Configuration(storage: .persistent, directory: directory.url))
        #expect(WebFonts.shared.startedWarmUps >= 1)
    }
}
