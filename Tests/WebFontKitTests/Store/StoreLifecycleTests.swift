import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

/// The store across a process's life: re-warms, failed deletes, and files another process wrote.
@Suite(.timeLimit(.minutes(1)))
struct StoreLifecycleTests {
    @Test("switching from session to persistent storage keeps the session's registered faces; only launch empties its folder")
    func rewarmKeepsSession() async throws {
        let harness = Harness()
        harness.serveGoogle()
        let fonts = harness.makeFonts(storage: .session)
        try await harness.warmUp(fonts)
        try await fonts.load("Lobster")
        let file = try #require(fonts.registry.entry(for: FaceKey(family: "Lobster", style: .regular))?.fileURL)

        fonts.configure(WebFonts.Configuration(storage: .persistent, session: harness.session))
        await fonts.waitForWarmUp()

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
    }

    @Test("removeAll still reports every family it took out when a delete fails")
    func removeAllFailureStillReports() async throws {
        let harness = Harness()
        harness.serveGoogle()
        let fonts = harness.makeFonts()
        let events = try await harness.warmUp(fonts)
        try await fonts.load("Lobster")
        harness.files.fail(.delete)

        await #expect(throws: WebFontError.storage) { try await fonts.removeAll() }
        try await events.wait { $0.contains(.removed(family: "Lobster")) }
        #expect(fonts.downloaded.isEmpty)
    }

    @Test("a face another process stored under a newer cache key replaces the stale entry instead of being skipped")
    func newerCacheKeyFromAnotherProcess() async throws {
        let harness = Harness()
        let version = Locked("v1")
        let fetches = Locked(0)
        let source = VersionedSource(version: version, fetches: fetches)
        let fonts = harness.makeFonts(source: source)
        try await harness.warmUp(fonts)
        try await fonts.load("Lobster")
        let key = FaceKey(family: "Lobster", style: .regular)
        let old = try #require(fonts.registry.entry(for: key)?.fileURL)

        // Another process with the new version stores its copy and deletes the old one.
        version.withLock { $0 = "v2" }
        let newer = old.deletingLastPathComponent().appendingPathComponent(
            StoredFileName.font(family: "Lobster", style: .regular, cacheKey: source.cacheKey(for: FontRequest(family: "Lobster")), version: nil))
        try FileManager.default.copyItem(at: old, to: newer)
        try FileManager.default.removeItem(at: old)

        try await fonts.load("Lobster")

        #expect(fetches.withLock { $0 } == 1)
        #expect(fonts.registry.entry(for: key)?.fileURL?.lastPathComponent == newer.lastPathComponent)
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
    }
}

/// Serves Lobster under a cache key that changes with `version`, counting fetches.
private struct VersionedSource: FontSource {
    let version: Locked<String>
    let fetches: Locked<Int>

    func fetch(_ font: FontRequest) async throws -> Data {
        fetches.withLock { $0 += 1 }
        return Fixtures.data(Fixtures.lobster)
    }

    func cacheKey(for font: FontRequest) -> String {
        "\(font.family)-\(version.withLock { $0 })"
    }
}
