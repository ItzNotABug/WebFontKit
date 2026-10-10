import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PublicEntryPointGuardTests {
    @Test("configure, load, a batch, remove and removeAll called on the main actor make no seam call on the main thread")
    func mainActorCallers() async throws {
        #expect(pthread_main_np() != 0)
        let harness = Harness()
        harness.server.serveGoogle()
        try harness.storeFont(Fixtures.lobster, family: "Lobster", version: "v1")
        let fonts = harness.makeFonts()

        fonts.configure(WebFonts.Configuration(session: harness.session))
        try await fonts.load("Inter", styles: [.regular, .bold])
        await fonts.load(["Lobster", "Inter"])
        try await fonts.remove("Inter")
        try await fonts.removeAll()

        #expect(!harness.files.calls.isEmpty)
        #expect(harness.files.calls.allSatisfy { !$0.onMainThread })
        #expect(harness.registrar.calls.allSatisfy { !$0.onMainThread })
        #expect(harness.logSink.entriesLoggedUnderLock.isEmpty)
    }

    @Test("the synchronous members can be called from detached tasks while loads run, and start one warm-up")
    func synchronousMembersOffMain() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        let loads = Task.detached { try await fonts.load("Lobster") }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = fonts.downloaded
                    _ = fonts.events
                    _ = fonts.postScriptName(family: "Lobster", style: .regular)
                    fonts.configure(WebFonts.Configuration(session: harness.session))
                }
            }
        }
        try await loads.value

        // Every configure keeps the same store, so only the first use warms up.
        #expect(fonts.startedWarmUps == 1)
        #expect(fonts.postScriptName(family: "Lobster", style: .regular) == "Lobster-Regular")
        #expect(fonts.downloaded.map(\.family) == ["Lobster"])
        #expect(harness.logSink.entriesLoggedUnderLock.isEmpty)
    }
}
