import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct DownloaderTests {
    private let url = "https://fonts.example.test/body.bin"
    private let megabyte = 1024 * 1024

    private func download(_ harness: Harness, cap: Int = Downloader.sizeCap) async throws -> URL {
        try await Downloader.download(
            URLRequest(url: URL(string: url)!), session: harness.session,
            into: harness.directory.store, fileOperations: harness.files, cap: cap
        )
    }

    @Test("the body goes to disk chunk by chunk, off the main thread")
    func bodyToDisk() async throws {
        let harness = Harness()
        let size = 6 * megabyte
        harness.server.respond(to: url, with: .font(Harness.markedBody(count: size, marker: UUID().uuidString)))

        let partial = try await download(harness)

        #expect(try Data(contentsOf: partial).count == size)
        #expect(partial.pathExtension == "wfkpart")
        #expect(harness.server.requests.allSatisfy { !$0.isDownloadTask })
        let calls = harness.files.calls
        let creates = calls.filter { $0.operation == .createPartial }
        let appendPositions: [Int] = calls.indices.filter { calls[$0].operation == .append }
        let close: Int = try #require(calls.lastIndex { $0.operation == .close })
        let lastAppend: Int = try #require(appendPositions.last)
        #expect(creates.count == 1)
        #expect(creates.first?.url == partial)
        #expect(!appendPositions.isEmpty)
        #expect(lastAppend < close)
        #expect(calls.allSatisfy { !$0.onMainThread })
    }

    @Test("the first half of a body is on disk while the stub still holds the second half")
    func streamsBeforeTheEnd() async throws {
        let harness = Harness()
        let half = 3 * megabyte
        harness.server.respond(to: url, with: .font(Harness.markedBody(count: 2 * half, marker: UUID().uuidString), hold: .afterBytes(half)))

        let task = Task { try await download(harness) }
        let sizes = try await harness.files.appendedBytes.wait { $0.reduce(0, +) >= half }
        let onDiskWhileHeld: Int = sizes.reduce(0, +)
        #expect(onDiskWhileHeld == half)
        harness.server.release(url)

        let partial = try await task.value
        let total: Int = harness.files.appendedBytes.elements.reduce(0, +)
        #expect(total == 2 * half)
        #expect(try Data(contentsOf: partial).count == 2 * half)
    }

    @Test("a body over the cap is cancelled while the stub holds the rest", arguments: [true, false])
    func cap(withContentLength: Bool) async throws {
        let harness = Harness()
        let marker = UUID().uuidString
        let body = Harness.markedBody(count: 3 * megabyte, marker: marker)
        var response = StubResponse.font(body, hold: .afterBytes(2 * megabyte))
        response.chunkSize = 256 * 1024
        if withContentLength {
            response.headers["Content-Length"] = String(body.count)
        }
        harness.server.respond(to: url, with: response)

        await #expect(throws: WebFontError.invalidFont) { try await download(harness, cap: megabyte) }
        try await harness.server.waitForCancel(of: url)
        harness.server.releaseAll()
        #expect(harness.leftovers.isEmpty)
        #expect(Harness.systemTemporaryFiles(startingWith: marker).isEmpty)
    }

    @Test("an uncompressed body declaring a length over the cap fails before any of it arrives")
    func declaredLengthOverCap() async throws {
        let harness = Harness()
        // Held after zero bytes: only the declared length can end this download.
        var response = StubResponse.font(Data(count: 5000), hold: .afterBytes(0))
        response.headers["Content-Length"] = "5000"
        harness.server.respond(to: url, with: response)

        await #expect(throws: WebFontError.invalidFont) { try await download(harness, cap: 1000) }
        harness.server.releaseAll()
        #expect(harness.leftovers.isEmpty)
    }

    @Test("a caller's cancel throws CancellationError and leaves nothing behind")
    func callerCancel() async throws {
        let harness = Harness()
        let marker = UUID().uuidString
        harness.server.respond(to: url, with: .font(Harness.markedBody(count: 4 * megabyte, marker: marker), hold: .afterBytes(megabyte)))

        let task = Task { try await download(harness) }
        try await harness.server.waitForRequests { $0.absoluteString == url }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await harness.server.waitForCancel(of: url)
        harness.server.releaseAll()
        #expect(harness.leftovers.isEmpty)
        #expect(Harness.systemTemporaryFiles(startingWith: marker).isEmpty)
    }

    @Test("a download cancelled before it starts throws CancellationError")
    func cancelledBeforeStart() async throws {
        let harness = Harness()
        harness.server.respond(to: url, with: .font(Data(repeating: 1, count: 1000)))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await download(harness)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(harness.leftovers.isEmpty)
    }

    @Test("a session whose delegate queue is main still stores the file, with every file operation off main", arguments: [false, true])
    func mainDelegateQueue(overCap: Bool) async throws {
        let harness = Harness(delegateQueue: .main)
        let size = overCap ? 3 * megabyte : megabyte
        harness.server.respond(to: url, with: .font(Harness.markedBody(count: size, marker: UUID().uuidString)))

        if overCap {
            await #expect(throws: WebFontError.invalidFont) { try await download(harness, cap: 2 * megabyte) }
            #expect(harness.leftovers.isEmpty)
        } else {
            let partial = try await download(harness)
            #expect(try Data(contentsOf: partial).count == size)
        }
        #expect(harness.files.calls.contains { $0.operation == .createPartial })
        #expect(harness.files.calls.allSatisfy { !$0.onMainThread })
    }

    @Test("no download is written into a URL cache, while a plain request on the same session is")
    func noURLCache() async throws {
        // In memory only: a disk cache writes its database after the test's directory is gone.
        let cache = URLCache(memoryCapacity: 50_000_000, diskCapacity: 0)
        let base = URLSessionConfiguration.ephemeral
        base.urlCache = cache
        base.requestCachePolicy = .useProtocolCachePolicy
        let harness = Harness(base: base)
        let headers = ["Cache-Control": "public, max-age=31536000", "Content-Type": "font/ttf"]
        let control = URL(string: "https://fonts.example.test/control.ttf")!
        harness.server.respond(to: url, with: StubResponse(headers: headers, body: Fixtures.data(Fixtures.lobster)))
        harness.server.respond(to: control, with: StubResponse(headers: headers, body: Fixtures.data(Fixtures.lobster)))

        _ = try await download(harness)
        _ = try await harness.session.data(for: URLRequest(url: control))

        #expect(cache.cachedResponse(for: URLRequest(url: control)) != nil)
        #expect(cache.cachedResponse(for: URLRequest(url: URL(string: url)!)) == nil)
    }

    @Test("the library's session has no cache, a 15 s idle timeout and a 600 s backstop")
    func defaultSession() {
        let configuration = LibrarySession.shared.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 600)
    }

    @Test("an empty 2xx body leaves an empty partial, which validation rejects and deletes")
    func emptyBody() async throws {
        let harness = Harness()
        harness.server.respond(to: Harness.lobsterFile, with: .font(Fixtures.data("Corrupt/Empty.ttf")))
        await #expect(throws: WebFontError.invalidFont) {
            try await harness.fetcher.fetchResolved(URL(string: Harness.lobsterFile)!)
        }
        #expect(harness.files.calls.contains { $0.operation == .createPartial })
        #expect(harness.leftovers.isEmpty)
    }

    @Test("in memory, the body is returned and nothing touches the disk")
    func memoryMode() async throws {
        let harness = Harness()
        harness.server.respond(to: url, with: .font(Fixtures.data(Fixtures.lobster)))
        let data = try await Downloader.data(for: URLRequest(url: URL(string: url)!), session: harness.session)
        #expect(data == Fixtures.data(Fixtures.lobster))
        #expect(harness.files.calls.isEmpty)
    }

    @Test("reading any status returns the error page, so its title can be read")
    func anyStatus() async throws {
        let harness = Harness()
        harness.server.respond(to: url, with: .html(statusCode: 400, "<title>400: Invalid selector</title>"))
        let response = try await Downloader.response(for: URLRequest(url: URL(string: url)!), session: harness.session, cap: 1000)
        #expect(response.statusCode == 400)
        #expect(response.contentType == "text/html; charset=utf-8")
        #expect(CSS2.title(ofPage: response.body) == "400: Invalid selector")
    }
}

