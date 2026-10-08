import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct EventStreamTests {
    private func loadEvents(_ events: AsyncRecorder<WebFontEvent>) -> [WebFontEvent] {
        events.elements.filter { if case .warmedUp = $0 { false } else { true } }
    }

    /// Proves absence: everything owed for the case arrives before the sentinel's own `.loading`.
    /// The sentinel may still close with `.failed` before its cancel lands, so tests drop its events.
    private func sentinel(_ fonts: WebFonts, _ harness: Harness, _ events: AsyncRecorder<WebFontEvent>, family: String) async throws {
        await fonts.quiesce(family: family)
        let roboto = Task { try await fonts.load("Roboto") }
        try await events.wait { $0.contains(.loading(family: "Roboto", styles: [.regular])) }
        roboto.cancel()
        _ = try? await roboto.value
    }

    @Test("a cancelled starter's joined load still closes with .loaded")
    func joinedSucceeds() async throws {
        let harness = Harness()
        harness.serveGoogle(holdCSS: true)
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)

        let joins = harness.joins(on: fonts)
        let a = Task { try await fonts.load("Lobster") }
        try await events.wait { $0.contains(.loading(family: "Lobster", styles: [.regular])) }
        let b = Task { try await fonts.load("Lobster") }
        try await joins.wait { $0.count == 1 }
        try await harness.server.waitForRequests { harness.isCSS2($0) }
        a.cancel()
        await #expect(throws: CancellationError.self) { try await a.value }
        harness.server.releaseAll()
        try await b.value
        try await events.wait { $0.contains(.loaded(family: "Lobster", styles: [.regular])) }
        #expect(harness.css2Requests == 1)
        #expect(loadEvents(events) == [.loading(family: "Lobster", styles: [.regular]), .loaded(family: "Lobster", styles: [.regular])])
    }

    @Test("a cancelled starter's shared work that fails closes with .failed")
    func joinedFails() async throws {
        let harness = Harness()
        harness.server.respondToOthers { _ in StubResponse(statusCode: 404, hold: .beforeResponse) }
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)

        let joins = harness.joins(on: fonts)
        let a = Task { try await fonts.load("Lobster") }
        try await harness.server.waitForRequests()
        let b = Task { try await fonts.load("Lobster") }
        try await joins.wait { $0.count == 1 }
        a.cancel()
        _ = try? await a.value
        harness.server.releaseAll()
        await #expect(throws: WebFontError.notFound) { try await b.value }
        try await events.wait { $0.count >= 3 }
        #expect(loadEvents(events) == [.loading(family: "Lobster", styles: [.regular]),
                                       .failed(family: "Lobster", styles: [.regular], error: .notFound)])
    }

    @Test("a lone cancelled starter emits only .loading", arguments: [true, false])
    func loneCancelled(holdCSS: Bool) async throws {
        let harness = Harness()
        harness.serveGoogle(holdCSS: holdCSS, holdFiles: !holdCSS)
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)

        let a = Task { try await fonts.load("Lobster") }
        try await harness.server.waitForRequests { holdCSS ? harness.isCSS2($0) : harness.isFontFile($0) }
        a.cancel()
        await #expect(throws: CancellationError.self) { try await a.value }
        let held = harness.server.requests.last!.url.absoluteString
        try await harness.server.waitForCancel(of: held)
        harness.server.releaseAll()
        try await sentinel(fonts, harness, events, family: "Lobster")
        #expect(loadEvents(events).filter { !$0.isSentinel } == [.loading(family: "Lobster", styles: [.regular])])
    }

    @Test("the closing event carries the starter's styles")
    func startersStyles() async throws {
        let harness = Harness()
        harness.serveGoogle(holdCSS: true)
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)

        let joins = harness.joins(on: fonts)
        let a = Task { try await fonts.load("Inter", styles: [.regular, .bold]) }
        try await harness.server.waitForRequests { harness.isCSS2($0) }
        let b = Task { try await fonts.load("Inter", styles: [.regular]) }
        let c = Task { try await fonts.load("Inter", styles: [.bold]) }
        try await joins.wait { $0.count == 2 }
        a.cancel()
        _ = try? await a.value
        harness.server.releaseAll()
        try await b.value
        try await c.value
        try await events.wait { $0.contains(.loaded(family: "Inter", styles: [.regular, .bold])) }
        #expect(loadEvents(events) == [.loading(family: "Inter", styles: [.regular, .bold]),
                                       .loaded(family: "Inter", styles: [.regular, .bold])])
    }

    @Test("remove overtakes a load in flight: CancellationError, nothing stored, .loading then .removed", arguments: [false, true])
    func removeOvertakes(all: Bool) async throws {
        let harness = Harness()
        harness.serveGoogle(holdFiles: true)
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)

        let load = Task { try await fonts.load("Lobster") }
        try await harness.server.waitForRequests { harness.isFontFile($0) }
        if all { try await fonts.removeAll() } else { try await fonts.remove("Lobster") }
        harness.server.releaseAll()
        await #expect(throws: CancellationError.self) { try await load.value }
        await fonts.quiesce(family: "Lobster")

        #expect(loadEvents(events) == [.loading(family: "Lobster", styles: [.regular]), .removed(family: "Lobster")])
        #expect(harness.leftovers.isEmpty)
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == nil)
        #expect(fonts.downloaded.isEmpty)
        #expect(harness.registrar.registeredURLs.isEmpty)

        harness.serveGoogle()
        try await fonts.load("Lobster")
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
    }

    @Test("a remove of another family leaves a held load to finish")
    func removeOtherFamily() async throws {
        let harness = Harness()
        harness.serveGoogle(holdFiles: true)
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        let load = Task { try await fonts.load("Inter") }
        try await harness.server.waitForRequests { harness.isFontFile($0) }
        try await fonts.remove("Lobster")
        harness.server.releaseAll()
        try await load.value
        #expect(fonts.postScriptName(family: "Inter", style: .regular) == "Lato-Regular")
    }

    @Test("remove of a family never held emits one .removed and touches nothing")
    func removeUnknown() async throws {
        let harness = Harness()
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        try await fonts.remove("Never")
        try await events.wait { $0.contains(.removed(family: "Never")) }
        #expect(loadEvents(events) == [.removed(family: "Never")])
        #expect(harness.registrar.calls(.unregister).isEmpty)
        #expect(harness.files.calls(.delete).isEmpty)
    }

    @Test("removeAll emits per family in name order, and nothing for an empty store")
    func removeAllOrder() async throws {
        let harness = Harness()
        harness.serveGoogle()
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        try await fonts.removeAll()
        try await fonts.load("Lobster")
        try await fonts.load("Inter")
        try await fonts.removeAll()
        try await events.wait { $0.contains(.removed(family: "Lobster")) }
        #expect(loadEvents(events).filter { if case .removed = $0 { true } else { false } }
            == [.removed(family: "Inter"), .removed(family: "Lobster")])
    }

    @Test("remove waits for a running warm-up before deleting anything")
    func removeWaitsForWarmUp() async throws {
        let harness = Harness()
        try harness.storeFont(Fixtures.lobster, family: "Lobster")
        harness.registrar.holdRegister()
        let fonts = harness.makeFonts()
        let waiting = AsyncLatch()
        fonts.hooks.onWarmUpWait = { waiting.open() }
        fonts.configure(WebFonts.Configuration(session: harness.session))
        try await harness.registrar.heldRegisterArrivals.wait { $0.count == 1 }

        let remove = Task { try await fonts.remove("Lobster") }
        try await waiting.wait()
        #expect(harness.files.calls(.delete).isEmpty)
        harness.registrar.releaseRegister()
        try await remove.value
        #expect(harness.registrar.registeredURLs.isEmpty)
        #expect(harness.directory.fileNames().isEmpty)
    }

    @Test("the latest .warmedUp is replayed first to a later listener, and every listener gets every event")
    func replayAndListeners() async throws {
        let harness = Harness()
        harness.serveGoogle()
        try harness.storeFont(Fixtures.lobster, family: "Lobster")
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        let first = harness.listen(to: fonts)
        let second = harness.listen(to: fonts)
        try await first.wait { !$0.isEmpty }
        #expect(first.elements.first == .warmedUp(count: 1))
        try await fonts.load("Inter")
        try await first.wait { $0.count == 3 }
        try await second.wait { $0.count == 3 }
        #expect(first.elements == second.elements)
    }

    @Test("a listener that reads nothing keeps the newest 256 events")
    func buffering() async throws {
        let harness = Harness()
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        let stream = fonts.events
        for index in 0..<300 {
            try await fonts.remove("Family\(index)")
        }
        var received: [WebFontEvent] = []
        for await event in stream {
            received.append(event)
            if received.count == 256 { break }
        }
        #expect(received.first == .removed(family: "Family44"))
        #expect(received.last == .removed(family: "Family299"))
    }
}

private extension WebFontEvent {
    var isSentinel: Bool {
        switch self {
        case .loading(let family, _), .loaded(let family, _), .failed(let family, _, _), .removed(let family): family == "Roboto"
        case .warmedUp: false
        }
    }
}
