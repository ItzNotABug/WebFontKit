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

        try await fonts.load("Lobster")

        #expect(harness.css2Requests == 0)
        #expect(harness.server.requests.map(\.url.absoluteString) == [Self.lobsterURL])
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
    }

    @Test("a catalogued URL Google no longer serves falls back to CSS2 and still loads")
    func goneURLFallsBack() async throws {
        let harness = Harness()
        harness.server.respond(to: Self.lobsterURL, with: StubResponse(statusCode: 404))
        harness.server.serveGoogle()
        let fonts = harness.makeFonts(catalog: GoogleFontsCatalogTests.catalog)
        try await harness.warmUp(fonts)

        try await fonts.load("Lobster")

        #expect(harness.css2Requests == 1)
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
        #expect(harness.logSink.entries.contains { $0.message.contains("catalogued URL") })
    }

    @Test("a call with any style the catalogue lacks asks CSS2 for all of them, as without a catalogue")
    func missingStyleUsesCSS2() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts(catalog: GoogleFontsCatalogTests.catalog)
        try await harness.warmUp(fonts)

        await #expect(throws: WebFontError.notFound) { try await fonts.load("Lobster", styles: [.regular, .bold]) }
        #expect(harness.css2Requests == 1)
        #expect(harness.fileRequests == 0)
    }

    @Test("a family the catalogue doesn't know is looked up as usual")
    func unknownFamily() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let withoutLobster = try #require(GoogleFontsCatalog(data: Fixtures.data("catalog/without-lobster.catalog")))
        let fonts = harness.makeFonts(catalog: withoutLobster)
        try await harness.warmUp(fonts)

        try await fonts.load("Lobster")

        #expect(harness.css2Requests == 1)
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
    }
}
