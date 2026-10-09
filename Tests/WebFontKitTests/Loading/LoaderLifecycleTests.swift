import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

/// Work that must end, jobs that must be dropped, and errors that must be the real ones,
/// whatever order a call's parking and its work's progress come in.
@Suite(.timeLimit(.minutes(1)))
struct LoaderLifecycleTests {
    /// Nothing left in the loader: no job, call, resolve or owed close.
    static func settled(_ fonts: WebFonts) -> Bool {
        fonts.state.withLock { $0.jobs.isEmpty && $0.calls.isEmpty && $0.resolves.isEmpty && $0.closes.isEmpty }
    }

    @Test("a source that throws CancellationError without being cancelled ends the load")
    func uncancelledSourceCancellation() async throws {
        let harness = Harness()
        let fonts = harness.makeFonts(source: TestDataSource { _ in throw CancellationError() })
        try await harness.warmUp(fonts)

        await #expect(throws: WebFontError.network(.cancelled)) { try await fonts.load("Lobster") }
        #expect(Self.settled(fonts))
    }

    @Test("a URLError.cancelled the caller did not ask for ends the load as .network(.cancelled)")
    func uncancelledURLCancellation() async throws {
        let harness = Harness()
        let base = URL(string: "https://cdn.example.test/fonts")!
        harness.server.respond(to: "https://cdn.example.test/fonts/Lobster.ttf", with: .failure(.cancelled))
        let fonts = harness.makeFonts(source: .hosted(at: base))
        try await harness.warmUp(fonts)

        await #expect(throws: WebFontError.network(.cancelled)) { try await fonts.load("Lobster") }
        #expect(Self.settled(fonts))
    }

    @Test("work failing before its caller parks reports the real error, not .notFound")
    func failureBeforePark() async throws {
        let harness = Harness()
        let fonts = harness.makeFonts(source: TestDataSource { _ in throw WebFontError.offline })
        try await harness.warmUp(fonts)
        // The fetch task is attached before the call parks, so this waits for it to fail.
        fonts.hooks.beforePark = { await fonts.quiesce(family: "Lobster") }

        await #expect(throws: WebFontError.offline) { try await fonts.load("Lobster") }
        #expect(Self.settled(fonts))
    }

    @Test("a call that will fail on a missing style starts no download, even when CSS2 answers before it parks")
    func noDownloadBeforeDecided() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        // CSS2 has answered by the time the call parks; any download started would have run by then.
        fonts.hooks.beforePark = { await fonts.quiesce(family: "Lobster") }

        await #expect(throws: WebFontError.notFound) { try await fonts.load("Lobster", styles: [.regular, .bold]) }
        #expect(harness.fileRequests == 0)
        #expect(harness.leftovers.isEmpty)
        #expect(Self.settled(fonts))
    }

    @Test("a call cancelled before it parks stops the work only it wanted")
    func cancelledBeforePark() async throws {
        let harness = Harness()
        let fetches = AsyncRecorder<String>()
        let fonts = harness.makeFonts(source: SlowSource(events: fetches))
        try await harness.warmUp(fonts)
        fonts.hooks.beforePark = {
            _ = try? await fetches.wait { $0.contains("started") }
            withUnsafeCurrentTask { $0?.cancel() }
        }

        let load = Task { try await fonts.load("Lobster") }
        await #expect(throws: CancellationError.self) { try await load.value }
        _ = try await fetches.wait { $0.contains("cancelled") }
        await fonts.quiesce(family: "Lobster")
        #expect(Self.settled(fonts))
    }

    enum LastToLeave: String, Sendable, CaseIterable {
        /// The bold commit finishes while `both` still waits on its regular file.
        case waiter
        /// `both` withdraws from the bold job while its commit is held at register.
        case commit
    }

    @Test(
        "a shared job is dropped after its commit, whichever leaves last: the commit or its last waiter",
        arguments: LastToLeave.allCases
    )
    func sharedJobDropped(last: LastToLeave) async throws {
        let harness = Harness()
        harness.server.serveGoogle(holdFiles: true)
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        let joins = harness.joins(on: fonts)
        let regularFile = "https://fonts.gstatic.com/s/inter/v1/400n.ttf"
        let boldFile = "https://fonts.gstatic.com/s/inter/v1/700n.ttf"

        let both = Task { try await fonts.load("Inter", styles: [.regular, .bold]) }
        _ = try await harness.server.waitForRequests(count: 2) { harness.isFontFile($0) }
        let bold = Task { try await fonts.load("Inter", styles: [.bold]) }
        _ = try await joins.wait { !$0.isEmpty }

        switch last {
        case .waiter:
            harness.server.release(boldFile)
            try await bold.value
            #expect(fonts.state.withLock { $0.jobs.values.contains { $0.outcome == .added && !$0.waiters.isEmpty } })
            harness.server.release(regularFile)
            try await both.value
        case .commit:
            harness.registrar.holdRegister()
            harness.server.release(boldFile)
            _ = try await harness.registrar.heldRegisterArrivals.wait { $0.count == 1 }
            both.cancel()
            await #expect(throws: CancellationError.self) { try await both.value }
            #expect(fonts.state.withLock { $0.jobs.values.contains { $0.commit != nil && $0.waiters.isEmpty } })
            harness.registrar.releaseRegister()
            try await bold.value
            harness.server.releaseAll()
            await fonts.quiesce(family: "Inter")
        }

        #expect(Self.settled(fonts))
        #expect(fonts.postScriptName(family: "Inter", style: .bold) == "Lato-Bold")
    }

    @Test("a cancelled starter owes no close once remove overtakes the commit it left to a joiner")
    func overtakenCloseSettles() async throws {
        let harness = Harness()
        harness.server.serveGoogle(holdFiles: true)
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        let joins = harness.joins(on: fonts)

        let starter = Task { try await fonts.load("Lobster") }
        try await harness.server.waitForRequests { harness.isFontFile($0) }
        let joiner = Task { try await fonts.load("Lobster") }
        _ = try await joins.wait { !$0.isEmpty }
        starter.cancel()
        await #expect(throws: CancellationError.self) { try await starter.value }

        harness.registrar.holdRegister()
        harness.server.releaseAll()
        _ = try await harness.registrar.heldRegisterArrivals.wait { !$0.isEmpty }
        let removal = Task { try await fonts.remove("Lobster") }
        try await events.wait { $0.contains(.removed(family: "Lobster")) }
        harness.registrar.releaseRegister()
        await #expect(throws: CancellationError.self) { try await joiner.value }
        try await removal.value
        try await harness.sentinel(fonts, events, after: "Lobster")

        #expect(Self.settled(fonts))
        #expect(!events.elements.contains(.loaded(family: "Lobster", styles: [.regular])))
    }
}

/// A source that takes 30 seconds unless cancelled, and records both.
private struct SlowSource: FontSource {
    let events: AsyncRecorder<String>

    func fetch(_ font: FontRequest) async throws -> Data {
        events.append("started")
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            events.append("cancelled")
            throw error
        }
        return Data()
    }
}
