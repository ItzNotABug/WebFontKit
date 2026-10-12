import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct CoalescingTests {
    @Test("fifty concurrent loads make one CSS2 request and one font request, and emit one pair of events")
    func fiftyCallers() async throws {
        let harness = Harness()
        harness.server.serveGoogle(holdCSS: true)
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        let joins = harness.joins(on: fonts)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 { group.addTask { try await fonts.loadOrThrow("Lobster") } }
            try await joins.wait { $0.count == 49 }
            try await harness.server.waitForRequests { harness.isCSS2($0) }
            harness.server.releaseAll()
            try await group.waitForAll()
        }

        #expect(harness.css2Requests == 1)
        #expect(harness.fileRequests == 1)
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
        try await events.wait { $0.contains(.loaded(family: "Lobster", styles: [.regular])) }
        #expect(events.loadEvents == [.loading(family: "Lobster", styles: [.regular]), .loaded(family: "Lobster", styles: [.regular])])
        #expect(harness.logSink.entriesLoggedUnderLock.isEmpty)
    }

    @Test("fifty concurrent loads from a hosted source make one request")
    func fiftyHosted() async throws {
        let harness = Harness()
        let base = URL(string: "https://cdn.example.test/fonts")!
        harness.server.respond(to: "https://cdn.example.test/fonts/Lobster.ttf", with: .font(Fixtures.data(Fixtures.lobster), hold: .beforeResponse))
        let fonts = harness.makeFonts(source: .hosted(at: base))
        try await harness.warmUp(fonts)
        let joins = harness.joins(on: fonts)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 { group.addTask { try await fonts.loadOrThrow("Lobster") } }
            try await joins.wait { $0.count == 49 }
            try await harness.server.waitForRequests()
            harness.server.releaseAll()
            try await group.waitForAll()
        }
        #expect(harness.server.requests.count == 1)
    }

    @Test("a multi-style call missing a style still loads the others, requesting no file for the missing one")
    func partialStyles() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)

        let results = await fonts.load("Lobster", styles: [.bold, .regular])
        #expect(results.succeeded == [.regular])
        #expect(results.failed.map(\.style) == [.bold])
        #expect(results.failed.map(\.error) == [.notFound])
        if case .failure(.notFound)? = results[.bold] {} else { Issue.record("bold: \(String(describing: results[.bold]))") }
        #expect(!results.allSucceeded)
        #expect(harness.fileRequests == 1)
        #expect(fonts.downloaded.map(\.style) == [.regular])
        #expect(harness.leftovers.allSatisfy { !$0.hasSuffix(".wfkpart") })
        try await events.wait { $0.count >= 4 }
        #expect(events.loadEvents == [.loading(family: "Lobster", styles: [.bold, .regular]),
                                       .loaded(family: "Lobster", styles: [.regular]),
                                       .failed(family: "Lobster", styles: [.bold], error: .notFound)])
    }

    @Test("a custom source that lacks a style still stores and registers the style it has")
    func partialStylesCustom() async throws {
        let harness = Harness()
        let source = TestDataSource { font in
            guard font.style == .regular else { throw WebFontError.notFound }
            return Fixtures.data(Fixtures.lobster)
        }
        let fonts = harness.makeFonts(source: source)
        try await harness.warmUp(fonts)

        let results = await fonts.load("Lobster", styles: [.regular, .bold])
        #expect(results.succeeded == [.regular])
        #expect(results.failed.map(\.error) == [.notFound])
        #expect(harness.leftovers.count == 1 && harness.leftovers.allSatisfy { $0.hasSuffix(".wfkfont") })
        #expect(harness.registrar.registeredURLs.count == 1)
    }

    @Test("styles failing differently close with one .failed per error, after .loaded for the rest")
    func failedEventPerError() async throws {
        let harness = Harness()
        let source = TestDataSource { font in
            switch font.style {
            case .regular: Fixtures.data(Fixtures.lobster)
            case .bold, .boldItalic: throw WebFontError.notFound
            default: throw WebFontError.offline
            }
        }
        let fonts = harness.makeFonts(source: source)
        let events = try await harness.warmUp(fonts)

        let results = await fonts.load("Lobster", styles: [.bold, .italic, .regular, .boldItalic])
        #expect(results.succeeded == [.regular])
        #expect(results.failed.map(\.style) == [.bold, .italic, .boldItalic])
        #expect(results.failed.map(\.error) == [.notFound, .offline, .notFound])
        try await events.wait { $0.count >= 5 }
        #expect(events.loadEvents == [.loading(family: "Lobster", styles: [.bold, .italic, .regular, .boldItalic]),
                                       .loaded(family: "Lobster", styles: [.regular]),
                                       .failed(family: "Lobster", styles: [.bold, .boldItalic], error: .notFound),
                                       .failed(family: "Lobster", styles: [.italic], error: .offline)])
    }

    @Test("a cancelled load returns no entry for the styles it did not finish")
    func cancelledLoadHasNoEntries() async throws {
        let harness = Harness()
        harness.server.serveGoogle(holdCSS: true)
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)

        let load = Task { await fonts.load("Lobster", styles: [.regular, .bold]) }
        try await harness.server.waitForRequests { harness.isCSS2($0) }
        load.cancel()
        let results = await load.value
        #expect(Array(results).isEmpty)
        #expect(!results.allSucceeded)
        harness.server.releaseAll()
    }

    @Test("with the CSS2 answer held, an incomplete call fails while a complete one succeeds", arguments: [true, false])
    func incompleteBesideComplete(incompleteFirst: Bool) async throws {
        let harness = Harness()
        harness.server.serveGoogle(holdCSS: true)
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)

        let joins = harness.joins(on: fonts)
        let incomplete: Task<Void, any Error>
        let complete: Task<Void, any Error>
        if incompleteFirst {
            incomplete = Task { try await fonts.loadOrThrow("Lobster", styles: [.regular, .bold]) }
            try await harness.server.waitForRequests { harness.isCSS2($0) }
            complete = Task { try await fonts.loadOrThrow("Lobster") }
            try await joins.wait { $0.count == 1 }
        } else {
            complete = Task { try await fonts.loadOrThrow("Lobster") }
            try await harness.server.waitForRequests { harness.isCSS2($0) }
            incomplete = Task { try await fonts.loadOrThrow("Lobster", styles: [.regular, .bold]) }
            try await joins.wait { $0.count == 1 }
            try await harness.server.waitForRequests(count: 2) { harness.isCSS2($0) }
        }
        harness.server.releaseAll()

        await #expect(throws: WebFontError.notFound) { try await incomplete.value }
        try await complete.value
        #expect(harness.directory.fileNames().filter { $0.hasSuffix(".wfkfont") }.count == 1)
        #expect(harness.registrar.calls(.register).count == 1)
    }

    @Test("cancelling one of three waiters keeps the download; cancelling all three cancels it")
    func cancellation() async throws {
        let harness = Harness()
        harness.server.serveGoogle(holdFiles: true)
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)

        let tasks = (0..<3).map { _ in Task { try await fonts.loadOrThrow("Lobster") } }
        try await harness.server.waitForRequests { harness.isFontFile($0) }
        tasks[0].cancel()
        await #expect(throws: CancellationError.self) { try await tasks[0].value }
        harness.server.releaseAll()
        try await tasks[1].value
        try await tasks[2].value

        try await fonts.remove("Lobster")
        let again = (0..<3).map { _ in Task { try await fonts.loadOrThrow("Lobster") } }
        try await harness.server.waitForRequests(count: 2) { harness.isFontFile($0) }
        again.forEach { $0.cancel() }
        for task in again { await #expect(throws: CancellationError.self) { try await task.value } }
        try await harness.server.waitForCancel(of: harness.server.requests.last { harness.isFontFile($0.url) }!.url.absoluteString)
        harness.server.releaseAll()
        await fonts.quiesce(family: "Lobster")
        #expect(harness.leftovers.isEmpty)
    }

    @Test("a failed shared download fails every waiter, and the next call retries")
    func failureShared() async throws {
        let harness = Harness()
        harness.server.respondToOthers { _ in StubResponse(statusCode: 503) }
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)

        let first = Task { try await fonts.loadOrThrow("Lobster") }
        let second = Task { try await fonts.loadOrThrow("Lobster") }
        await #expect(throws: WebFontError.server(statusCode: 503)) { try await first.value }
        await #expect(throws: WebFontError.server(statusCode: 503)) { try await second.value }
        let before = harness.css2Requests
        harness.server.serveGoogle()
        try await fonts.loadOrThrow("Lobster")
        #expect(harness.css2Requests == before + 1)
    }

    @Test("a load that misses the registry waits for warm-up and loads from disk with no request")
    func waitsForWarmUp() async throws {
        let harness = Harness()
        try harness.storeFont(Fixtures.lobster, family: "Lobster", version: "v32")
        harness.registrar.holdRegister()
        let fonts = harness.makeFonts()
        let waited = AsyncLatch()
        fonts.hooks.onWarmUpWait = { waited.open() }
        let load = Task { try await fonts.loadOrThrow("Lobster") }
        try await harness.registrar.heldRegisterArrivals.wait { $0.count == 1 }
        try await waited.wait()
        harness.registrar.releaseRegister()
        try await load.value
        #expect(harness.server.requests.isEmpty)
        #expect(harness.registrar.calls(.register).count == 1)
    }

    @Test("an empty style set does nothing, but counts as first use")
    func emptyStyles() async throws {
        let harness = Harness()
        let fonts = harness.makeFonts()
        try await fonts.loadOrThrow("Lobster", styles: [])
        #expect(fonts.startedWarmUps == 1)
        try await fonts.loadOrThrow("Lobster", styles: [])
        #expect(fonts.startedWarmUps == 1)
        #expect(harness.server.requests.isEmpty)
    }

    @Test("duplicate styles make one request for one tuple, and one pair of events")
    func duplicateStyles() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        try await fonts.loadOrThrow("Lobster", styles: [.regular, .regular])
        try await events.wait { $0.contains(.loaded(family: "Lobster", styles: [.regular])) }
        #expect(harness.server.requests.first { harness.isCSS2($0.url) }?.url.query == "family=Lobster:ital,wght@0,400")
        #expect(events.loadEvents == [.loading(family: "Lobster", styles: [.regular]), .loaded(family: "Lobster", styles: [.regular])])
    }

    @Test("an invalid family name is .notFound with no request, and emits loading then failed", arguments: ["", " Lobster", "Lob  ster", "Lob/ster", "Lobster "])
    func invalidNames(name: String) async throws {
        let harness = Harness()
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        await #expect(throws: WebFontError.notFound) { try await fonts.loadOrThrow(name) }
        #expect(harness.server.requests.isEmpty)
        try await events.wait { $0.contains(.failed(family: name, styles: [.regular], error: .notFound)) }
    }

    @Test("a registered face returns at once, with no request and no event")
    func registryHit() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        try await fonts.loadOrThrow("Lobster")
        try await events.wait { $0.contains(.loaded(family: "Lobster", styles: [.regular])) }
        try await fonts.loadOrThrow("Lobster")
        try await harness.sentinel(fonts, events, after: "Lobster")
        #expect(harness.css2Requests(for: "Lobster") == 1)
        #expect(events.loadEvents == [.loading(family: "Lobster", styles: [.regular]), .loaded(family: "Lobster", styles: [.regular])])
    }

    @Test("a removed font is downloaded again by the next load")
    func removedThenLoaded() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        try await fonts.loadOrThrow("Lobster")
        try await fonts.remove("Lobster")
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == nil)
        try await fonts.loadOrThrow("Lobster")
        #expect(harness.css2Requests == 2)
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
    }

    @Test("works end to end without configure, on an injected root")
    func noConfigure() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        try await fonts.loadOrThrow("Lobster")
        #expect(fonts.downloaded.map(\.postScriptName) == ["Lobster-Regular"])
        #expect(harness.directory.fileNames().contains { $0.hasPrefix("Lobster@400n@") && $0.hasSuffix("@v1.wfkfont") })
    }
}
