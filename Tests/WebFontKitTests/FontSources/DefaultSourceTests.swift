import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct DefaultSourceTests {
    private let userAgent = "WebFontKit/" + WebFontKit.libraryVersion

    @Test("resolve makes one CSS2 request for all of a family's styles")
    func resolveOneRequest() async throws {
        let harness = Harness()
        let styles: [FontStyle] = [.boldItalic, .regular, .italic, .bold]
        let css2 = CSS2.url(family: "Inter", styles: styles).absoluteString
        harness.server.respond(to: css2, with: .css(Fixtures.css2Text("inter-four-styles")))

        let urls = try await CSS2.resolve(family: "Inter", styles: styles, session: harness.session, logSink: harness.logSink)

        #expect(Set(urls.keys) == Set(styles))
        #expect(harness.server.requests.map(\.url.absoluteString) == [css2])
        #expect(css2.hasSuffix("family=Inter:ital,wght@0,400;0,700;1,400;1,700"))
    }

    @Test("a partial answer resolves only the styles Google has")
    func resolvePartial() async throws {
        let harness = Harness()
        harness.server.respond(
            to: CSS2.url(family: "Lobster", styles: [.regular, .bold]).absoluteString,
            with: .css(Fixtures.css2Text("lobster"))
        )
        let urls = try await CSS2.resolve(family: "Lobster", styles: [.regular, .bold], session: harness.session, logSink: harness.logSink)
        #expect(Array(urls.keys) == [.regular])
    }

    @Test("every request carries the library's User-Agent, even over a session with a browser's")
    func ownUserAgent() async throws {
        let base = URLSessionConfiguration.ephemeral
        base.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (iPhone) Mobile Safari"]
        let harness = Harness(base: base)
        harness.serveLobster()

        _ = try await DefaultFontSource.default.fetch(FontRequest(family: "Lobster"), session: harness.session, logSink: harness.logSink)

        #expect(harness.server.requests.count == 2)
        for request in harness.server.requests {
            #expect(request.headers["User-Agent"] == userAgent)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        }
    }

    @Test("fetch makes the one-style CSS2 request, then the file request, and returns the bytes")
    func fetchHelper() async throws {
        let harness = Harness()
        harness.serveLobster()

        let data = try await DefaultFontSource.default.fetch(FontRequest(family: "Lobster"), session: harness.session, logSink: harness.logSink)

        #expect(data == Fixtures.data(Fixtures.lobster))
        #expect(harness.server.requests.map(\.url.absoluteString) == [Harness.lobsterCSS2, Harness.lobsterFile])
        #expect(Harness.lobsterCSS2.hasSuffix("family=Lobster:ital,wght@0,400"))
        #expect(harness.server.requests.allSatisfy { !$0.isDownloadTask })
        #expect(harness.directory.fileNames(in: harness.directory.url) == ["WebFontKit"])
        #expect(harness.leftovers.isEmpty)
    }

    @Test("fetch's in-memory download cancels a file over the cap while the stub holds the rest")
    func fetchHelperCap() async throws {
        let harness = Harness()
        let megabyte = 1024 * 1024
        var file = StubResponse.font(Harness.markedBody(count: 3 * megabyte, marker: UUID().uuidString), hold: .afterBytes(2 * megabyte))
        file.chunkSize = 256 * 1024
        harness.serveLobster(file: file)

        let urls = try await CSS2.resolve(family: "Lobster", styles: [.regular], session: harness.session, logSink: harness.logSink)
        let request = CSS2.request(for: try #require(urls[.regular]))
        await #expect(throws: WebFontError.invalidFont) {
            try await Downloader.data(for: request, session: harness.session, cap: megabyte)
        }
        try await harness.server.waitForCancel(of: Harness.lobsterFile)
        harness.server.releaseAll()
        #expect(harness.leftovers.isEmpty)
    }

    @Test("the public fetch refuses a file that declares more than the library's cap")
    func fetchDeclaredOverCap() async throws {
        let harness = Harness()
        var file = StubResponse.font(Fixtures.data(Fixtures.lobster))
        file.headers["Content-Length"] = String(Downloader.sizeCap + 1)
        harness.serveLobster(file: file)

        await #expect(throws: WebFontError.invalidFont) {
            try await DefaultFontSource.default.fetch(FontRequest(family: "Lobster"), session: harness.session, logSink: harness.logSink)
        }
    }

    @Test("a style missing from the answer is .notFound for fetch")
    func fetchMissingStyle() async throws {
        let harness = Harness()
        harness.server.respond(
            to: CSS2.url(family: "Lobster", styles: [.bold]).absoluteString,
            with: .css(Fixtures.css2Text("lobster"))
        )
        await #expect(throws: WebFontError.notFound) {
            try await DefaultFontSource.default.fetch(FontRequest(family: "Lobster", style: .bold), session: harness.session, logSink: harness.logSink)
        }
    }

    @Test("a 400 titled \"Font family not found\" is .notFound, after exactly one request")
    func notFound() async throws {
        let harness = Harness()
        harness.server.respondToOthers { _ in
            StubResponse(statusCode: 400, headers: ["Content-Type": "text/html"], body: Fixtures.css2("not-found"))
        }
        await #expect(throws: WebFontError.notFound) {
            try await CSS2.resolve(family: "Molle", styles: [.regular], session: harness.session, logSink: harness.logSink)
        }
        #expect(harness.server.requests.count == 1)
        #expect(harness.logSink.entries.isEmpty)
    }

    @Test("a 400 titled \"Invalid selector\" is .server(400) and one fault naming the family")
    func invalidSelector() async throws {
        let harness = Harness()
        harness.server.respondToOthers { _ in
            StubResponse(statusCode: 400, headers: ["Content-Type": "text/html"], body: Fixtures.css2("invalid-selector"))
        }
        await #expect(throws: WebFontError.server(statusCode: 400)) {
            try await CSS2.resolve(family: "Inter", styles: [.regular], session: harness.session, logSink: harness.logSink)
        }
        let faults = harness.logSink.entries(level: .fault)
        #expect(faults.count == 1)
        #expect(faults.first?.message.contains("Inter") == true)
        #expect(harness.logSink.entriesLoggedUnderLock.isEmpty)
    }

    @Test(
        "other statuses map to .notFound or .server",
        arguments: [
            (400, WebFontError.notFound), (404, .notFound), (403, .server(statusCode: 403)),
            (429, .server(statusCode: 429)), (500, .server(statusCode: 500)), (503, .server(statusCode: 503)),
        ]
    )
    func statuses(status: Int, expected: WebFontError) async throws {
        let harness = Harness()
        harness.server.respondToOthers { _ in StubResponse(statusCode: status, body: Data("nope".utf8)) }
        await #expect(throws: expected) {
            try await CSS2.resolve(family: "Lobster", styles: [.regular], session: harness.session, logSink: harness.logSink)
        }
    }

    @Test(
        "unusable CSS is .invalidFont and no file is requested",
        arguments: [
            ("text/css", "lobster-woff2"),
            ("text/css", "lobster-http"),
            ("text/html; charset=utf-8", "captive-portal"),
        ]
    )
    func unusableCSS(contentType: String, kind: String) async throws {
        let harness = Harness()
        let css: String
        switch kind {
        case "lobster-woff2": css = Fixtures.css2Text("lobster").replacingOccurrences(of: "truetype", with: "woff2")
        case "lobster-http": css = Fixtures.css2Text("lobster").replacingOccurrences(of: "https://", with: "http://")
        default: css = "<html><body>Sign in to Wi-Fi</body></html>"
        }
        harness.server.respond(to: Harness.lobsterCSS2, with: StubResponse(headers: ["Content-Type": contentType], body: Data(css.utf8)))

        await #expect(throws: WebFontError.invalidFont) {
            try await DefaultFontSource.default.fetch(FontRequest(family: "Lobster"), session: harness.session, logSink: harness.logSink)
        }
        #expect(harness.server.requests.map(\.url.absoluteString) == [Harness.lobsterCSS2])
    }

    @Test("the cache key is version-free and stable")
    func cacheKey() {
        let source: any FontSource = .default
        let before = source.cacheKey(for: FontRequest(family: "Inter", style: .boldItalic))
        #expect(before == "Inter|700|i")
        #expect(source.cacheKey(for: FontRequest(family: "Inter", style: .boldItalic)) == before)
    }

    @Test("the default source is a FontSource but not a RemoteFontSource")
    func notRemote() {
        let source: any FontSource = .default
        #expect(source is DefaultFontSource)
        #expect(!(source is any RemoteFontSource))
    }

    @Test("a resolved file is downloaded with the library's headers and keeps its version")
    func resolvedFile() async throws {
        let harness = Harness()
        harness.serveLobster()
        let face = try await harness.fetcher.fetchResolved(URL(string: Harness.lobsterFile)!)
        #expect(face.postScriptName == "Lobster-Regular")
        #expect(face.glyphCount == 1142)
        #expect(face.version == "v32")
        let request = try #require(harness.server.requests.first)
        #expect(request.headers["User-Agent"] == userAgent)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(!request.isDownloadTask)
    }
}
