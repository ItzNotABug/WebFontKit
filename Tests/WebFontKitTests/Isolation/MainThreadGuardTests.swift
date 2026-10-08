import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MainThreadGuardTests {
    @Test("resolve, download and validation started from the main actor make no seam call on the main thread")
    func phaseOneEntryPoints() async throws {
        #expect(pthread_main_np() != 0)
        let harness = Harness()
        harness.serveLobster()

        let urls = try await CSS2.resolve(family: "Lobster", styles: [.regular], session: harness.session, logSink: harness.logSink)
        let face = try await harness.fetcher.fetchResolved(try #require(urls[.regular]))
        let custom = try await harness.fetcher.fetchCustom(
            FontRequest(family: "Lobster"), from: TestDataSource { _ in Fixtures.data(Fixtures.lobster) }
        )

        #expect(face.postScriptName == "Lobster-Regular")
        #expect(custom.postScriptName == "Lobster-Regular")
        #expect(!harness.files.calls.isEmpty)
        #expect(harness.files.calls.allSatisfy { !$0.onMainThread })
        #expect(!harness.registrar.calls.isEmpty)
        #expect(harness.registrar.calls.allSatisfy { !$0.onMainThread })
    }

    #if os(macOS)
    @Test("a file operation on the main thread traps")
    func fileOperationTraps() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run {
                _ = DiskFileOperations().fileExists(at: URL(fileURLWithPath: "/"))
            }
        }
    }

    @Test("descriptor reading on the main thread traps")
    func registrarTraps() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run {
                _ = CoreTextRegistrar().faceInfo(at: URL(fileURLWithPath: "/"))
            }
        }
    }
    #endif
}
