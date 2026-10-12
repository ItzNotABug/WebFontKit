import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct LoadPathTests {
    @Test("a stale marker is deleted, logged, and the face loads normally", arguments: ["missing", "unknown"])
    func staleMarker(kind: String) async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let marker = harness.store.url(for: StoredFileName.marker(family: "Lobster", style: .regular))
        if kind == "missing" {
            try Data().write(to: marker)
        } else {
            try harness.store.writeMarker(family: "Lobster", style: .regular, postScriptName: "NoSuchFont-Regular")
        }
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)

        try await fonts.loadOrThrow("Lobster")

        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(harness.logSink.entries.contains { $0.message.contains(marker.lastPathComponent) })
        #expect(harness.css2Requests == 1)
        #expect(harness.fileRequests == 1)
        try await events.wait { $0.contains(.loaded(family: "Lobster", styles: [.regular])) }
        #expect(events.loadEvents == [.loading(family: "Lobster", styles: [.regular]), .loaded(family: "Lobster", styles: [.regular])])
    }

    @Test("a valid marker answers the load with no request and no event")
    func validMarker() async throws {
        let harness = Harness()
        try harness.store.writeMarker(family: "Lobster", style: .regular, postScriptName: "Helvetica")
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        try await fonts.loadOrThrow("Lobster")
        #expect(harness.server.requests.isEmpty)
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Helvetica")
        #expect(fonts.downloaded.isEmpty)
        try await harness.sentinel(fonts, events, after: "Lobster")
        #expect(events.loadEvents.isEmpty)
    }

    @Test("a font another instance stored after warm-up is registered from disk with no request, silently")
    func storeLookup() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        try harness.storeFont(Fixtures.lobster, family: "Lobster", version: "v1")
        try await fonts.loadOrThrow("Lobster")
        #expect(harness.server.requests.isEmpty)
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
        try await harness.sentinel(fonts, events, after: "Lobster")
        #expect(events.loadEvents.isEmpty)
    }

    @Test("remove overtakes a held commit: CancellationError, the registration undone, nothing left", arguments: [false, true])
    func removeOvertakesCommit(all: Bool) async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        harness.registrar.holdRegister()

        let load = Task { try await fonts.loadOrThrow("Lobster") }
        let held = try await harness.registrar.heldRegisterArrivals.wait { $0.count == 1 }
        let file = try #require(held.first?.first)
        harness.registrar.scriptRegister(file, code: 0)
        if all { try await fonts.removeAll() } else { try await fonts.remove("Lobster") }
        harness.registrar.releaseRegister()

        await #expect(throws: CancellationError.self) { try await load.value }
        #expect(harness.registrar.calls(.unregister).contains { $0.urls == [file] })
        #expect(harness.registrar.registeredURLs.isEmpty)
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == nil)
        #expect(fonts.downloaded.isEmpty)
        #expect(harness.leftovers.isEmpty)
        try await events.wait { $0.contains(.removed(family: "Lobster")) }
        #expect(events.loadEvents == [.loading(family: "Lobster", styles: [.regular]), .removed(family: "Lobster")])
    }

    @Test("a commit whose file remove deleted fails at register, and still throws CancellationError")
    func removeOvertakesFailingCommit() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        harness.registrar.holdRegister()
        let load = Task { try await fonts.loadOrThrow("Lobster") }
        try await harness.registrar.heldRegisterArrivals.wait { $0.count == 1 }
        try await fonts.remove("Lobster")
        harness.registrar.releaseRegister()
        await #expect(throws: CancellationError.self) { try await load.value }
        #expect(harness.registrar.registeredURLs.isEmpty)
        #expect(harness.leftovers.isEmpty)
    }

    @Test("a load started after remove returns makes its own requests and stores once")
    func loadAfterRemove() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        harness.registrar.holdRegister()
        let first = Task { try await fonts.loadOrThrow("Lobster") }
        try await harness.registrar.heldRegisterArrivals.wait { $0.count == 1 }
        try await fonts.remove("Lobster")
        let second = Task { try await fonts.loadOrThrow("Lobster") }
        try await harness.server.waitForRequests(count: 2) { harness.isFontFile($0) }
        harness.registrar.releaseRegister()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await second.value
        #expect(harness.css2Requests == 2)
        #expect(harness.directory.fileNames().filter { $0.hasSuffix(".wfkfont") }.count == 1)
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
        #expect(fonts.downloaded.count == 1)
    }

    @Test("one file for two spellings: both load, one registration, removing the registered one keeps the other drawing")
    func oneFileTwoSpellings() async throws {
        let harness = Harness()
        harness.server.respondToOthers { _ in .font(Fixtures.data(Fixtures.lobster)) }
        let fonts = harness.makeFonts(source: TestRemoteSource(key: "Lobster-v32"))
        try await harness.warmUp(fonts)

        try await fonts.loadOrThrow("Lobster")
        try await fonts.loadOrThrow("lobster")

        #expect(harness.registrar.calls(.register).count == 1)
        #expect(fonts.registry.entry(for: FaceKey(family: "lobster", style: .regular))?.registeredHere == false)
        #expect(fonts.downloaded.count == 2)

        try await fonts.remove("Lobster")
        #expect(fonts.postScriptName(family: "lobster", style: .regular) == "Lobster-Regular")
        #expect(fonts.registry.entry(for: FaceKey(family: "lobster", style: .regular))?.registeredHere == true)
    }

    @Test("two commits of one PostScript name at once register it exactly once", arguments: [true, false])
    func twoCommitsAtOnce(styles: Bool) async throws {
        let harness = Harness()
        harness.server.respondToOthers { _ in .font(Fixtures.data(Fixtures.lobster)) }
        let fonts = harness.makeFonts(source: TestRemoteSource(key: "Lobster-v32"))
        try await harness.warmUp(fonts)

        if styles {
            try await fonts.loadOrThrow("Lobster", styles: [.regular, .bold])
        } else {
            async let upper: Void = fonts.loadOrThrow("Lobster")
            async let lower: Void = fonts.loadOrThrow("lobster")
            _ = try await (upper, lower)
        }

        let registrations = harness.registrar.calls(.register).filter { !$0.urls.isEmpty }
        #expect(registrations.count == 1)
        #expect(fonts.downloaded.count == 2)
        #expect(fonts.downloaded.allSatisfy { $0.postScriptName == "Lobster-Regular" })
    }

    @Test("a changed cache key replaces the stored face, unregistering the old file first")
    func replacement() async throws {
        let harness = Harness()
        let source = VersionedSource(version: "v32")
        harness.server.respondToOthers { request in
            .font(Fixtures.data(request.url!.lastPathComponent.contains("v20") ? Fixtures.lobsterV20 : Fixtures.lobster))
        }
        let fonts = harness.makeFonts(source: source)
        try await harness.warmUp(fonts)
        try await fonts.loadOrThrow("Lobster")
        let old = try #require(fonts.registry.entry(for: FaceKey(family: "Lobster", style: .regular))?.fileURL)

        source.version.withLock { $0 = "v20" }
        try await fonts.loadOrThrow("Lobster")

        let new = try #require(fonts.registry.entry(for: FaceKey(family: "Lobster", style: .regular))?.fileURL)
        #expect(new != old)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(harness.registrar.registeredURLs == [new])
        let calls = harness.registrar.calls.filter { [.register, .unregister].contains($0.method) && !$0.urls.isEmpty }.suffix(2)
        #expect(calls.map(\.method) == [.unregister, .register])
    }
}
