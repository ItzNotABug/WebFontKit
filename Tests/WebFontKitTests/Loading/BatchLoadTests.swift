import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct BatchLoadTests {
    @Test("a batch never throws, reports each family in the order asked, and loads duplicates once")
    func batch() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)

        let results = await fonts.load(["Lobster", "Lobstr", "Inter", "Lobster"])

        #expect(results.map(\.family) == ["Lobster", "Lobstr", "Inter"])
        #expect(results.succeeded == ["Lobster", "Inter"])
        #expect(results.failed.map(\.family) == ["Lobstr"])
        #expect(!results.allSucceeded)
        if case .failure(.notFound)? = results["Lobstr"] {} else { Issue.record("Lobstr: \(String(describing: results["Lobstr"]))") }
        #expect(results["NotAsked"] == nil)
        #expect(harness.server.requests.count { $0.url.absoluteString.contains("family=Lobster:") } == 1)
        #expect(harness.server.requests.filter { harness.isCSS2($0.url) }.allSatisfy { $0.url.query?.hasSuffix("ital,wght@0,400") == true })
    }

    @Test("an empty batch succeeds and starts warm-up once")
    func emptyBatch() async {
        let harness = Harness()
        let fonts = harness.makeFonts()
        let results = await fonts.load([])
        #expect(results.allSucceeded)
        #expect(fonts.startedWarmUps == 1)
    }

    @Test("a family overtaken by remove is absent from the results, and the others are returned")
    func overtakenFamily() async throws {
        let harness = Harness()
        harness.server.serveGoogle(holdFiles: true)
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)

        let batch = Task { await fonts.load(["Lobster", "Inter"]) }
        try await harness.server.waitForRequests(count: 2) { harness.isFontFile($0) }
        try await fonts.remove("Lobster")
        harness.server.releaseAll()
        let results = await batch.value

        #expect(results["Lobster"] == nil)
        #expect(results.succeeded == ["Inter"])
        #expect(results.failed.isEmpty)
        #expect(!results.allSucceeded)
        #expect(harness.server.requests.count { $0.url.absoluteString.contains("family=Lobster:") } == 1)
    }

    @Test("cancelling a batch returns what finished, without the unfinished families")
    func cancelledBatch() async throws {
        let harness = Harness()
        harness.server.serveGoogle(holdFiles: true)
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        let batch = Task { await fonts.load(["Lobster"]) }
        try await harness.server.waitForRequests { harness.isFontFile($0) }
        batch.cancel()
        let results = await batch.value
        #expect(results["Lobster"] == nil)
        #expect(!results.allSucceeded)
        harness.server.releaseAll()
        await fonts.quiesce(family: "Lobster")
        #expect(harness.leftovers.isEmpty)
    }
}
