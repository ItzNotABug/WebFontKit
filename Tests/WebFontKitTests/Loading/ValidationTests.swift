import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct ValidationTests {
    private func partial(_ harness: Harness, _ fixture: String) throws -> URL {
        let url = harness.directory.store.appending(component: StoredFileName.partial())
        try Fixtures.data(fixture).write(to: url)
        return url
    }

    @Test(
        "a font CoreText reads gives its PostScript name and glyph count, and is excluded from backup",
        arguments: [
            (Fixtures.lobster, "Lobster-Regular", 1142), (Fixtures.latoBold, "Lato-Bold", 272),
            (Fixtures.lobsterWoff, "Lobster-Regular", 1142), (Fixtures.lobsterWoff2, "Lobster-Regular", 333),
        ]
    )
    func valid(fixture: String, name: String, glyphs: Int) throws {
        let harness = Harness()
        let url = try partial(harness, fixture)
        let face = try harness.fetcher.validate(url)
        #expect(face.partialURL == url)
        #expect(face.postScriptName == name)
        #expect(face.glyphCount == glyphs)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("each corrupt fixture is .invalidFont, and the partial is deleted", arguments: Fixtures.corrupt)
    func corrupt(fixture: String) throws {
        let harness = Harness()
        let url = try partial(harness, fixture)
        #expect(throws: WebFontError.invalidFont) { try harness.fetcher.validate(url) }
        #expect(harness.leftovers.isEmpty)
    }

    @Test("each corrupt fixture served by the network is .invalidFont, with nothing left", arguments: Fixtures.corrupt)
    func corruptDownload(fixture: String) async throws {
        let harness = Harness()
        harness.server.respond(to: Harness.lobsterFile, with: .font(Fixtures.data(fixture)))
        await #expect(throws: WebFontError.invalidFont) {
            try await harness.fetcher.fetchResolved(URL(string: Harness.lobsterFile)!)
        }
        #expect(harness.leftovers.isEmpty)
    }

    @Test("a failed backup exclusion is .storage, and the partial is deleted")
    func backupFailure() throws {
        let harness = Harness()
        harness.files.fail(.setExcludedFromBackup)
        let url = try partial(harness, Fixtures.lobster)
        #expect(throws: WebFontError.storage) { try harness.fetcher.validate(url) }
        #expect(harness.leftovers.isEmpty)
    }

    @Test("a resolved URL that is not https is refused before any request")
    func resolvedNotHTTPS() async throws {
        let harness = Harness()
        await #expect(throws: WebFontError.invalidFont) {
            try await harness.fetcher.fetchResolved(URL(string: "http://fonts.gstatic.com/s/lobster/v32/a.ttf")!)
        }
        #expect(harness.server.requests.isEmpty)
    }
}
