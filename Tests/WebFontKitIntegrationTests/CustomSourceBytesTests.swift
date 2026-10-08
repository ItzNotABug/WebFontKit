import CoreText
import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

extension IntegrationTests {
    /// Custom-source bytes are judged by CoreText alone, never by extension or
    /// MIME type. Each case validates, registers for real, resolves by its
    /// PostScript name, and unregisters before the next (they share one name).
    @Suite
    struct CustomSourceBytesTests {
        struct Case: Sendable, CustomTestStringConvertible {
            var fixture: String
            var path: String
            var contentType: String
            var glyphs: Int
            var testDescription: String { "\(fixture) as \(path) (\(contentType))" }
        }

        static let cases: [Case] = [Fixtures.lobsterWoff, Fixtures.lobsterWoff2].flatMap { fixture in
            let glyphs = fixture == Fixtures.lobsterWoff ? 1142 : 333
            return [
                Case(fixture: fixture, path: "Lobster.ttf", contentType: "font/ttf", glyphs: glyphs),
                Case(fixture: fixture, path: "Lobster", contentType: "font/ttf", glyphs: glyphs),
                Case(fixture: fixture, path: "font", contentType: "application/octet-stream", glyphs: glyphs),
            ]
        }

        @Test("WOFF and WOFF2 from a custom source validate and register", arguments: cases)
        func registers(_ testCase: Case) async throws {
            let server = StubServer()
            let directory = TempDirectory()
            try FileManager.default.createDirectory(at: directory.store, withIntermediateDirectories: true)
            let url = URL(string: "https://fonts.example.test/\(testCase.path)")!
            server.respond(to: url, with: StubResponse(headers: ["Content-Type": testCase.contentType], body: Fixtures.data(testCase.fixture)))
            let registrar = CoreTextRegistrar()
            let fetcher = FaceFetcher(
                session: server.makeSession(), directory: directory.store,
                files: DiskFileOperations(), registrar: registrar, logSink: RecordingLogSink()
            )

            let face = try await fetcher.fetchCustom(FontRequest(family: "Lobster"), from: FixedURLSource(url: url))
            #expect(face.postScriptName == "Lobster-Regular")
            #expect(face.glyphCount == testCase.glyphs)

            let failures = await registrar.register(urls: [face.partialURL])
            #expect(failures.isEmpty)
            let opened = await registrar.openRegisteredFace(postScriptName: "Lobster-Regular")
            #expect(opened.glyphCount == testCase.glyphs)
            #expect(opened.fileURL?.resolvingSymlinksInPath() == face.partialURL.resolvingSymlinksInPath())
            #expect(await registrar.unregister(urls: [face.partialURL]).isEmpty)
        }
    }
}

private struct FixedURLSource: RemoteFontSource {
    var url: URL

    func request(for font: FontRequest) async throws -> URLRequest {
        URLRequest(url: url)
    }
}
