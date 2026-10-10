import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct CustomSourceTests {
    @Test("a remote source's request reaches the wire with its headers, and its own fetch is never called")
    func remoteHeaders() async throws {
        let harness = Harness()
        let source = TestRemoteSource()
        let font = FontRequest(family: "Lobster")
        harness.server.respond(to: source.url(for: font), with: .font(Fixtures.data(Fixtures.lobster)))

        let face = try await harness.fetcher.fetchCustom(font, from: source)

        #expect(face.postScriptName == "Lobster-Regular")
        #expect(face.version == nil)
        let request = try #require(harness.server.requests.first)
        #expect(harness.server.requests.count == 1)
        #expect(request.headers["Authorization"] == "Bearer token")
        #expect(request.headers["X-Custom"] == "1")
        #expect(!request.isDownloadTask)
        #expect(source.fetchCalls.elements.isEmpty)
        #expect(harness.leftovers == [face.partialURL.lastPathComponent])
    }

    @Test("a non-https request is refused before anything is requested")
    func remoteNotHTTPS() async throws {
        let harness = Harness()
        let source = TestRemoteSource(base: URL(string: "http://fonts.example.test")!)
        await #expect(throws: WebFontError.invalidFont) {
            try await harness.fetcher.fetchCustom(FontRequest(family: "Lobster"), from: source)
        }
        await #expect(throws: WebFontError.invalidFont) {
            try await source.fetch(request: FontRequest(family: "Lobster"), session: harness.session)
        }
        #expect(harness.server.requests.isEmpty)
    }

    @Test("the remote source's default fetch sends the request unchanged and returns the body")
    func remoteFetchHelper() async throws {
        let harness = Harness()
        let source = OnlyRequestSource()
        let font = FontRequest(family: "Lobster")
        harness.server.respond(to: source.url, with: .font(Fixtures.data(Fixtures.lobster)))

        let data = try await source.fetch(request: font, session: harness.session)

        #expect(data == Fixtures.data(Fixtures.lobster))
        let request = try #require(harness.server.requests.first)
        #expect(harness.server.requests.count == 1)
        #expect(request.url == source.url)
        #expect(request.headers["Authorization"] == "Bearer abc")
        #expect(request.headers["User-Agent"] == "MyApp/2")
        #expect(harness.leftovers.isEmpty)
    }

    @Test("a remote source's download over the fetcher's cap is cancelled while the stub holds the rest, leaving nothing")
    func remoteDownloadCap() async throws {
        let harness = Harness()
        let source = OnlyRequestSource()
        let megabyte = 1024 * 1024
        var response = StubResponse.font(Harness.markedBody(count: 3 * megabyte, marker: UUID().uuidString), hold: .afterBytes(2 * megabyte))
        response.chunkSize = 256 * 1024
        harness.server.respond(to: source.url, with: response)
        let fetcher = harness.fetcher(sizeCap: megabyte)

        await #expect(throws: WebFontError.invalidFont) {
            try await fetcher.fetchCustom(FontRequest(family: "Lobster"), from: source)
        }
        try await harness.server.waitForCancel(of: source.url.absoluteString)
        harness.server.releaseAll()
        #expect(harness.leftovers.isEmpty)
    }

    @Test("a source's bytes over the fetcher's cap are .invalidFont and never written; bytes at the cap are accepted")
    func dataSourceCap() async throws {
        let harness = Harness()
        let bytes = Fixtures.data(Fixtures.lobster)
        let source = TestDataSource { _ in bytes }

        await #expect(throws: WebFontError.invalidFont) {
            try await harness.fetcher(sizeCap: bytes.count - 1).fetchCustom(FontRequest(family: "Lobster"), from: source)
        }
        #expect(harness.files.calls(.write).isEmpty)
        #expect(harness.leftovers.isEmpty)

        let face = try await harness.fetcher(sizeCap: bytes.count).fetchCustom(FontRequest(family: "Lobster"), from: source)
        #expect(face.postScriptName == "Lobster-Regular")
    }

    @Test("a source that fetches for itself never touches the session, and its bytes are judged by CoreText")
    func dataSource() async throws {
        let harness = Harness()
        let source = TestDataSource { _ in Fixtures.data(Fixtures.lobsterWoff2) }
        let face = try await harness.fetcher.fetchCustom(FontRequest(family: "Lobster"), from: source)
        #expect(face.postScriptName == "Lobster-Regular")
        #expect(face.glyphCount == 333)
        #expect(harness.server.requests.isEmpty)
    }

    @Test("a custom cache key is used through any FontSource")
    func customCacheKey() {
        let source: any FontSource = TestRemoteSource(key: "Lobster-v32")
        #expect(source.cacheKey(for: FontRequest(family: "Lobster")) == "Lobster-v32")
        let plain: any FontSource = TestDataSource { _ in Data() }
        #expect(plain.cacheKey(for: FontRequest(family: "Lobster", style: .italic)) == "Lobster|400|i")
    }

    @Test(
        "what a source throws: WebFontError passes through, URLError is mapped",
        arguments: [
            (WebFontError.notFound as any Error & Sendable, WebFontError.notFound),
            (WebFontError.server(statusCode: 503), .server(statusCode: 503)),
            (URLError(.notConnectedToInternet), .offline),
            (URLError(.timedOut), .network(.timedOut)),
        ]
    )
    func sourceErrors(thrown: any Error & Sendable, expected: WebFontError) async throws {
        let harness = Harness()
        let source = TestDataSource { _ in throw thrown }
        await #expect(throws: expected) {
            try await harness.fetcher.fetchCustom(FontRequest(family: "Lobster"), from: source)
        }
        #expect(harness.logSink.entries.isEmpty)
    }

    @Test("any other error becomes .network(.unknown) and is logged with the original error")
    func otherErrors() async throws {
        let harness = Harness()
        let source = TestDataSource { _ in throw TestSourceError() }
        await #expect(throws: WebFontError.network(.unknown)) {
            try await harness.fetcher.fetchCustom(FontRequest(family: "Lobster"), from: source)
        }
        let errors = harness.logSink.entries(level: .error)
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("TestSourceError: the source broke") == true)
        #expect(errors.first?.message.contains("Lobster") == true)
        #expect(harness.logSink.entriesLoggedUnderLock.isEmpty)
    }

    @Test("a remote source's request(for:) errors are mapped the same way")
    func remoteRequestErrors() async throws {
        let harness = Harness()
        await #expect(throws: WebFontError.network(.unknown)) {
            try await harness.fetcher.fetchCustom(FontRequest(family: "Lobster"), from: ThrowingRequestSource())
        }
        #expect(harness.logSink.entries(level: .error).count == 1)
    }

    @Test("cancellation from a source is never mapped")
    func cancellationPassesThrough() async {
        let harness = Harness()
        let source = TestDataSource { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await harness.fetcher.fetchCustom(FontRequest(family: "Lobster"), from: source)
        }
    }

    @Test("bytes CoreText rejects are .invalidFont, and the partial is gone")
    func rejectedBytes() async throws {
        let harness = Harness()
        let source = TestDataSource { _ in Fixtures.data("Corrupt/NotFound.ttf") }
        await #expect(throws: WebFontError.invalidFont) {
            try await harness.fetcher.fetchCustom(FontRequest(family: "Lobster"), from: source)
        }
        #expect(harness.leftovers.isEmpty)
    }

    @Test("a failed write of a source's bytes is .storage, and nothing is left")
    func failedWrite() async throws {
        let harness = Harness()
        harness.files.fail(.write)
        let source = TestDataSource { _ in Fixtures.data(Fixtures.lobster) }
        await #expect(throws: WebFontError.storage) {
            try await harness.fetcher.fetchCustom(FontRequest(family: "Lobster"), from: source)
        }
        #expect(harness.leftovers.isEmpty)
    }
}

/// A remote source that implements only `request(for:)`.
private struct OnlyRequestSource: RemoteFontSource {
    let url = URL(string: "https://fonts.example.test/only/Lobster.ttf")!

    func request(for font: FontRequest) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer abc", forHTTPHeaderField: "Authorization")
        request.setValue("MyApp/2", forHTTPHeaderField: "User-Agent")
        return request
    }
}

private struct ThrowingRequestSource: RemoteFontSource {
    func request(for font: FontRequest) async throws -> URLRequest {
        throw TestSourceError()
    }
}
