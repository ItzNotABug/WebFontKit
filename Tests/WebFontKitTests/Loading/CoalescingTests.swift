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
        #expect(throws: WebFontError.notFound) { try results[.bold]?.get() }
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

    @Test("a style that failed is fetched again by the next call while its sibling still downloads")
    func failedStyleRetried() async throws {
        let harness = Harness()
        let source = GatedSource(boldErrors: [.offline])
        let fonts = harness.makeFonts(source: source)
        try await harness.warmUp(fonts)

        let first = Task { await fonts.load("Lobster", styles: [.regular, .bold]) }
        try await source.waitForFailedBold(in: fonts)
        let retry = await fonts.load("Lobster", styles: [.bold])
        #expect(retry.failed.map(\.error) == [.offline])
        #expect(source.fetches.elements.filter { $0 == .bold }.count == 2)
        source.release.open()
        let results = await first.value
        #expect(results.succeeded == [.regular] && results.failed.map(\.style) == [.bold])
        #expect(LoaderLifecycleTests.settled(fonts))
    }

    @Test("a cancelled starter whose other style nobody wants still reports the style that failed")
    func cancelledStarterReportsFailure() async throws {
        let harness = Harness()
        let source = GatedSource(boldErrors: [.offline])
        let fonts = harness.makeFonts(source: source)
        let events = try await harness.warmUp(fonts)

        let starter = Task { await fonts.load("Lobster", styles: [.regular, .bold]) }
        try await source.waitForFailedBold(in: fonts)
        starter.cancel()
        #expect(Array(await starter.value).isEmpty)
        try await harness.sentinel(fonts, events, after: "Lobster")
        #expect(events.loadEvents == [.loading(family: "Lobster", styles: [.regular, .bold]),
                                       .failed(family: "Lobster", styles: [.bold], error: .offline)])
        #expect(LoaderLifecycleTests.settled(fonts))
    }

    @Test("a cancelled starter closes with .loaded and .failed once a joined call commits its other style")
    func cancelledStarterPartial() async throws {
        let harness = Harness()
        let source = GatedSource(boldErrors: [.offline])
        let fonts = harness.makeFonts(source: source)
        let events = try await harness.warmUp(fonts)

        let joins = harness.joins(on: fonts)
        let starter = Task { await fonts.load("Lobster", styles: [.regular, .bold]) }
        try await source.waitForFailedBold(in: fonts)
        let joined = Task { await fonts.load("Lobster") }
        try await joins.wait { $0.count == 1 }
        starter.cancel()
        _ = await starter.value
        source.release.open()
        #expect(await joined.value.allSucceeded)
        try await events.wait { $0.count >= 4 }
        #expect(events.loadEvents == [.loading(family: "Lobster", styles: [.regular, .bold]),
                                       .loaded(family: "Lobster", styles: [.regular]),
                                       .failed(family: "Lobster", styles: [.bold], error: .offline)])
        #expect(LoaderLifecycleTests.settled(fonts))
    }

    @Test("a retry of a failed style under the same key never changes a cancelled starter's close")
    func retryKeepsStartersClose() async throws {
        let harness = Harness()
        let source = GatedSource(boldErrors: [.offline, .notFound])
        let fonts = harness.makeFonts(source: source)
        let events = try await harness.warmUp(fonts)

        let joins = harness.joins(on: fonts)
        let starter = Task { await fonts.load("Lobster", styles: [.regular, .bold]) }
        try await source.waitForFailedBold(in: fonts)
        let joined = Task { await fonts.load("Lobster") }
        try await joins.wait { $0.count == 1 }
        starter.cancel()
        _ = await starter.value
        #expect(await fonts.load("Lobster", styles: [.bold]).failed.map(\.error) == [.notFound])
        source.release.open()
        #expect(await joined.value.allSucceeded)
        try await harness.sentinel(fonts, events, after: "Lobster")
        #expect(events.loadEvents == [.loading(family: "Lobster", styles: [.regular, .bold]),
                                       .loading(family: "Lobster", styles: [.bold]),
                                       .failed(family: "Lobster", styles: [.bold], error: .notFound),
                                       .loaded(family: "Lobster", styles: [.regular]),
                                       .failed(family: "Lobster", styles: [.bold], error: .offline)])
    }

    @Test("a style already loaded is reported loaded beside a missing one")
    func loadedBesideMissing() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        try await fonts.loadOrThrow("Lobster")

        let results = await fonts.load("Lobster", styles: [.regular, .bold])
        #expect(results.succeeded == [.regular] && results.failed.map(\.style) == [.bold])
        try await harness.sentinel(fonts, events, after: "Lobster")
        #expect(events.loadEvents.suffix(3) == [.loading(family: "Lobster", styles: [.regular, .bold]),
                                                 .loaded(family: "Lobster", styles: [.regular]),
                                                 .failed(family: "Lobster", styles: [.bold], error: .notFound)])
    }

    @Test("a shared style's job is dropped when its last waiter is cancelled after the commit")
    func committedJobDroppedOnCancel() async throws {
        let harness = Harness()
        let source = HeldLatoSource()
        let fonts = harness.makeFonts(source: source)
        try await harness.warmUp(fonts)

        let joins = harness.joins(on: fonts)
        let wide = Task { await fonts.load("Lato", styles: [.regular, .bold]) }
        _ = try await source.fetches.wait { $0.count == 2 }
        let narrow = Task { await fonts.load("Lato") }
        try await joins.wait { $0.count == 1 }
        source.latches[.regular]!.open()
        #expect(await narrow.value.allSucceeded)
        wide.cancel()
        _ = await wide.value
        await fonts.quiesce(family: "Lato")
        #expect(LoaderLifecycleTests.settled(fonts))
    }

    @Test("a cancelled starter still reports a style another caller committed, before or after the rest is abandoned",
          arguments: [true, false])
    func abandonedCloseReportsCommitted(commitFirst: Bool) async throws {
        let harness = Harness()
        let source = HeldLatoSource()
        let fonts = harness.makeFonts(source: source)
        let events = try await harness.warmUp(fonts)

        let joins = harness.joins(on: fonts)
        let starter = Task { await fonts.load("Lato", styles: [.regular, .bold]) }
        _ = try await source.fetches.wait { $0.count == 2 }
        let regular = Task { await fonts.load("Lato") }
        let bold = Task { await fonts.load("Lato", styles: [.bold]) }
        try await joins.wait { $0.count == 2 }
        starter.cancel()
        _ = await starter.value
        if commitFirst {
            source.latches[.regular]!.open()
            #expect(await regular.value.allSucceeded)
        }
        bold.cancel()
        _ = await bold.value
        if !commitFirst {
            source.latches[.regular]!.open()
            #expect(await regular.value.allSucceeded)
        }
        try await harness.sentinel(fonts, events, after: "Lato")
        #expect(events.loadEvents == [.loading(family: "Lato", styles: [.regular, .bold]),
                                       .loaded(family: "Lato", styles: [.regular])])
        #expect(LoaderLifecycleTests.settled(fonts))
    }

    @Test("a style whose install failed is fetched again by the next call, while another call still waits on it")
    func failedCommitRetried() async throws {
        let harness = Harness()
        let source = HeldLatoSource()
        let fonts = harness.makeFonts(source: source)
        let events = try await harness.warmUp(fonts)

        let joins = harness.joins(on: fonts)
        let first = Task { await fonts.load("Lato") }
        try await events.wait { $0.contains(.loading(family: "Lato", styles: [.regular])) }
        // Still waits on regular when its install fails: this call waits on bold too.
        let holder = Task { await fonts.load("Lato", styles: [.bold, .regular]) }
        try await joins.wait { $0.count == 1 }
        harness.files.fail(.rename, times: 1)
        source.latches[.regular]!.open()
        #expect(await first.value.failed.map(\.error) == [.storage])

        #expect(await fonts.load("Lato").allSucceeded)
        #expect(source.fetches.elements.filter { $0 == .regular }.count == 2)
        source.latches[.bold]!.open()
        let held = await holder.value
        #expect(held.succeeded == [.bold] && held.failed.map(\.error) == [.storage])
        #expect(LoaderLifecycleTests.settled(fonts))
    }

    @Test("a cancelled starter that joined a style whose install already succeeded still closes")
    func joinedFinishedCommitCloses() async throws {
        let harness = Harness()
        let source = HeldLatoSource()
        let fonts = harness.makeFonts(source: source)
        let events = try await harness.warmUp(fonts)

        let joins = harness.joins(on: fonts)
        let first = Task { await fonts.load("Lato") }
        try await events.wait { $0.contains(.loading(family: "Lato", styles: [.regular])) }
        // Keeps the regular job alive after its commit: this call still waits on bold.
        let holder = Task { await fonts.load("Lato", styles: [.bold, .regular]) }
        try await joins.wait { $0.count == 1 }
        // The starter's store check waits until regular has committed, then finds nothing, so it joins.
        let listing = harness.files.hold(.contentsOfDirectory)
        harness.files.fail(.contentsOfDirectory, times: 1)
        let starter = Task { await fonts.load("Lato", styles: [.regular, .italic]) }
        try await listing.arrived.wait()
        source.latches[.regular]!.open()
        #expect(await first.value.allSucceeded)
        listing.release()
        _ = try await source.fetches.wait { $0.contains(.italic) }
        try await joins.wait { $0.count == 2 }
        starter.cancel()
        _ = await starter.value
        source.latches[.bold]!.open()
        _ = await holder.value
        try await harness.sentinel(fonts, events, after: "Lato")
        // The first call and the cancelled starter each close with it.
        #expect(events.loadEvents.filter { $0 == .loaded(family: "Lato", styles: [.regular]) }.count == 2)
        #expect(LoaderLifecycleTests.settled(fonts))
    }

    @Test("a cancelled starter whose fetched styles were all abandoned sends no close, even beside a loaded style")
    func abandonedStarterSendsNothing() async throws {
        let harness = Harness()
        let source = HeldLatoSource()
        let fonts = harness.makeFonts(source: source)
        let events = try await harness.warmUp(fonts)
        source.latches[.regular]!.open()
        try await fonts.loadOrThrow("Lato")

        let starter = Task { await fonts.load("Lato", styles: [.regular, .bold]) }
        _ = try await source.fetches.wait { $0.contains(.bold) }
        starter.cancel()
        _ = await starter.value
        try await harness.sentinel(fonts, events, after: "Lato")
        #expect(events.loadEvents.suffix(1) == [.loading(family: "Lato", styles: [.regular, .bold])])
        #expect(LoaderLifecycleTests.settled(fonts))
    }

    @Test("a style asked for twice has one entry")
    func duplicateStyleOneEntry() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)

        let results = await fonts.load("Lobster", styles: [.regular, .regular])
        #expect(Array(results).map(\.style) == [.regular])
        #expect(results.allSucceeded)
    }

    @Test("with CSS2 held, a call missing a style shares the download with a complete call", arguments: [true, false])
    func incompleteBesideComplete(incompleteFirst: Bool) async throws {
        let harness = Harness()
        harness.server.serveGoogle(holdCSS: true)
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)

        let joins = harness.joins(on: fonts)
        let incomplete: Task<FontStyleResults, Never>
        let complete: Task<Void, any Error>
        if incompleteFirst {
            incomplete = Task { await fonts.load("Lobster", styles: [.regular, .bold]) }
            try await harness.server.waitForRequests { harness.isCSS2($0) }
            complete = Task { try await fonts.loadOrThrow("Lobster") }
            try await joins.wait { $0.count == 1 }
        } else {
            complete = Task { try await fonts.loadOrThrow("Lobster") }
            try await harness.server.waitForRequests { harness.isCSS2($0) }
            incomplete = Task { await fonts.load("Lobster", styles: [.regular, .bold]) }
            try await joins.wait { $0.count == 1 }
            try await harness.server.waitForRequests(count: 2) { harness.isCSS2($0) }
        }
        harness.server.releaseAll()

        let results = await incomplete.value
        #expect(results.succeeded == [.regular] && results.failed.map(\.error) == [.notFound])
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

/// Regular waits for `release`; the nth bold fetch fails with `boldErrors[n]`, the last one repeating.
private struct GatedSource: FontSource {
    let boldErrors: [WebFontError]
    let release = AsyncLatch()
    let fetches = AsyncRecorder<FontStyle>()

    func fetch(_ font: FontRequest) async throws -> Data {
        fetches.append(font.style)
        guard font.style == .regular else {
            let attempt = fetches.elements.filter { $0 == font.style }.count - 1
            throw boldErrors[min(attempt, boldErrors.count - 1)]
        }
        try await release.wait()
        return Fixtures.data(Fixtures.lobster)
    }

    /// Returns once bold's first fetch has failed and its job is dropped; no hook fires there.
    func waitForFailedBold(in fonts: WebFonts) async throws {
        _ = try await fetches.wait { $0.contains(.bold) }
        while fonts.state.withLock({ $0.jobs.keys.contains { $0.style == .bold } }) {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Each style waits for its own latch, then returns its Lato face.
private struct HeldLatoSource: FontSource {
    let latches: [FontStyle: AsyncLatch] = [.regular: AsyncLatch(), .bold: AsyncLatch(), .italic: AsyncLatch()]
    let fetches = AsyncRecorder<FontStyle>()

    func fetch(_ font: FontRequest) async throws -> Data {
        fetches.append(font.style)
        try await latches[font.style]!.wait()
        let faces = [FontStyle.regular: Fixtures.latoRegular, .bold: Fixtures.latoBold, .italic: Fixtures.latoItalic]
        return Fixtures.data(faces[font.style]!)
    }
}
