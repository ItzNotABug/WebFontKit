import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct CatalogLoadTests {
    static let lobsterURL = "https://fonts.gstatic.com/s/lobster/v32/neILzCirqoswsqX9_oU.ttf"

    @Test("a catalogued family downloads straight from its catalogued URL, with no CSS2 request")
    func skipsTheLookup() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts(catalog: GoogleFontsCatalogTests.catalog)
        try await harness.warmUp(fonts)

        try await fonts.loadOrThrow("Lobster")

        #expect(harness.css2Requests == 0)
        #expect(harness.server.requests.map(\.url.absoluteString) == [Self.lobsterURL])
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
    }

    @Test("a catalogued file Google reports gone falls back to CSS2 and still loads", arguments: [400, 404, 403, 410])
    func goneURLFallsBack(status: Int) async throws {
        let harness = Harness()
        harness.server.respond(to: Self.lobsterURL, with: StubResponse(statusCode: status))
        harness.server.serveGoogle()
        let fonts = harness.makeFonts(catalog: GoogleFontsCatalogTests.catalog)
        try await harness.warmUp(fonts)

        try await fonts.loadOrThrow("Lobster")

        #expect(harness.css2Requests == 1)
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
        #expect(harness.logSink.entries.contains { $0.message.contains("catalogued URL") })
    }

    @Test("after a dead catalogued file, the family skips the catalogue")
    func deadFamilySkipsCatalogue() async throws {
        let harness = Harness()
        let latoRegular = try #require(GoogleFontsCatalogTests.catalog.urls(family: "Lato", styles: [.regular])?[.regular])
        let latoBold = try #require(GoogleFontsCatalogTests.catalog.urls(family: "Lato", styles: [.bold])?[.bold])
        harness.server.respond(to: latoRegular, with: StubResponse(statusCode: 404))
        harness.server.serveGoogle()
        let fonts = harness.makeFonts(catalog: GoogleFontsCatalogTests.catalog)
        try await harness.warmUp(fonts)

        _ = try? await fonts.loadOrThrow("Lato", styles: [.regular])
        let lookups = harness.css2Requests
        _ = try? await fonts.loadOrThrow("Lato", styles: [.bold])

        #expect(harness.css2Requests == lookups + 1, "bold was looked up")
        #expect(!harness.server.requests.contains { $0.url == latoBold }, "bold's catalogued URL was never tried")
    }

    @Test("a server error fails as usual, with no CSS2 lookup, and leaves the catalogue on for the family")
    func transientErrorKeepsCatalogue() async throws {
        let harness = Harness()
        let latoRegular = try #require(GoogleFontsCatalogTests.catalog.urls(family: "Lato", styles: [.regular])?[.regular])
        let latoBold = try #require(GoogleFontsCatalogTests.catalog.urls(family: "Lato", styles: [.bold])?[.bold])
        harness.server.respond(to: latoRegular, with: StubResponse(statusCode: 503))
        harness.server.serveGoogle()
        let fonts = harness.makeFonts(catalog: GoogleFontsCatalogTests.catalog)
        try await harness.warmUp(fonts)

        await #expect(throws: WebFontError.server(statusCode: 503)) {
            try await fonts.loadOrThrow("Lato", styles: [.regular])
        }
        #expect(harness.css2Requests == 0)
        _ = try? await fonts.loadOrThrow("Lato", styles: [.bold])

        #expect(harness.server.requests.contains { $0.url == latoBold }, "bold still came from the catalogue")
    }

    @Test("configure forgets which families' catalogued files were gone")
    func configureForgetsMisses() async throws {
        let harness = Harness()
        let latoRegular = try #require(GoogleFontsCatalogTests.catalog.urls(family: "Lato", styles: [.regular])?[.regular])
        let latoBold = try #require(GoogleFontsCatalogTests.catalog.urls(family: "Lato", styles: [.bold])?[.bold])
        harness.server.respond(to: latoRegular, with: StubResponse(statusCode: 404))
        harness.server.serveGoogle()
        let fonts = harness.makeFonts(catalog: GoogleFontsCatalogTests.catalog)
        try await harness.warmUp(fonts)
        _ = try? await fonts.loadOrThrow("Lato", styles: [.regular])

        fonts.configure(WebFonts.Configuration(directory: harness.directory.url, session: harness.session))
        _ = try? await fonts.loadOrThrow("Lato", styles: [.bold])

        #expect(harness.server.requests.contains { $0.url == latoBold })
    }

    @Test("a gone file seen by a fetch from before configure doesn't turn the catalogue off afterwards")
    func staleFetchKeepsCatalogue() async throws {
        let harness = Harness()
        let latoRegular = try #require(GoogleFontsCatalogTests.catalog.urls(family: "Lato", styles: [.regular])?[.regular])
        let latoBold = try #require(GoogleFontsCatalogTests.catalog.urls(family: "Lato", styles: [.bold])?[.bold])
        var gone = StubResponse(statusCode: 404)
        gone.hold = .beforeResponse
        harness.server.respond(to: latoRegular, with: gone)
        harness.server.serveGoogle()
        let fonts = harness.makeFonts(catalog: GoogleFontsCatalogTests.catalog)
        try await harness.warmUp(fonts)

        let old = Task { try? await fonts.loadOrThrow("Lato", styles: [.regular]) }
        _ = try await harness.server.waitForRequests { $0 == latoRegular }
        fonts.configure(WebFonts.Configuration(directory: harness.directory.url, session: harness.session))
        harness.server.release(latoRegular.absoluteString)
        _ = await old.value
        _ = try? await fonts.loadOrThrow("Lato", styles: [.bold])

        #expect(harness.server.requests.contains { $0.url == latoBold })
    }

    @Test("the catalogue is read on the first Google lookup, not when WebFonts is created")
    func readLazily() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let reads = Locked(0)
        let fonts = WebFonts(
            configuration: WebFonts.Configuration(session: harness.session), registrar: harness.registrar,
            fileOperations: harness.files, root: harness.directory.url, logSink: harness.logSink,
            catalog: { reads.withLock { $0 += 1 }; return GoogleFontsCatalogTests.catalog }
        )
        try await harness.warmUp(fonts)
        #expect(reads.withLock { $0 } == 0)

        try await fonts.loadOrThrow("Lobster")
        #expect(reads.withLock { $0 } == 1)
    }

    @Test("a call with any style the catalogue lacks asks CSS2 for all of them, as without a catalogue")
    func missingStyleUsesCSS2() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts(catalog: GoogleFontsCatalogTests.catalog)
        try await harness.warmUp(fonts)

        let results = await fonts.load("Lobster", styles: [.regular, .bold])
        #expect(results.succeeded == [.regular] && results.failed.map(\.error) == [.notFound])
        #expect(harness.css2Requests == 1)
        #expect(harness.fileRequests == 1)
    }

    @Test("a family the catalogue doesn't know is looked up as usual")
    func unknownFamily() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let withoutLobster = try #require(GoogleFontsCatalog(data: Fixtures.data("catalog/without-lobster.catalog")))
        let fonts = harness.makeFonts(catalog: withoutLobster)
        try await harness.warmUp(fonts)

        try await fonts.loadOrThrow("Lobster")

        #expect(harness.css2Requests == 1)
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
    }
}
