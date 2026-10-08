import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct ErrorMappingTests {
    private let url = "https://fonts.example.test/Lobster.ttf"

    private func download(_ harness: Harness) async throws -> URL {
        try await Downloader.download(
            URLRequest(url: URL(string: url)!), session: harness.session,
            into: harness.directory.store, fileOperations: harness.files
        )
    }

    @Test(
        "the seven offline codes are .offline",
        arguments: [
            URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        ]
    )
    func offline(code: URLError.Code) async throws {
        let harness = Harness()
        harness.server.respond(to: url, with: .failure(code))
        await #expect(throws: WebFontError.offline) { try await download(harness) }
        #expect(harness.leftovers.isEmpty)
    }

    @Test("every other URL error carries its code", arguments: [URLError.Code.timedOut, .secureConnectionFailed, .badServerResponse])
    func network(code: URLError.Code) async throws {
        let harness = Harness()
        harness.server.respond(to: url, with: .failure(code))
        await #expect(throws: WebFontError.network(code)) { try await download(harness) }
    }

    @Test(
        "HTTP statuses: 404 and 400 are .notFound, the rest .server",
        arguments: [
            (404, WebFontError.notFound), (400, .notFound), (403, .server(statusCode: 403)),
            (429, .server(statusCode: 429)), (500, .server(statusCode: 500)), (503, .server(statusCode: 503)),
        ]
    )
    func status(status: Int, expected: WebFontError) async throws {
        let harness = Harness()
        harness.server.respond(to: url, with: StubResponse(statusCode: status, body: Data(repeating: 7, count: 5000)))
        await #expect(throws: expected) { try await download(harness) }
        #expect(!harness.files.calls.contains { $0.operation == .createPartial })
        #expect(harness.leftovers.isEmpty)
    }

    @Test(
        "a full disk or a failed create or append is .storage, with nothing left",
        arguments: [FakeFileOperations.Operation.createPartial, .append]
    )
    func storage(operation: FakeFileOperations.Operation) async throws {
        let harness = Harness()
        harness.files.fail(operation)
        var response = StubResponse.font(Data(repeating: 3, count: 2 * 1024 * 1024))
        response.chunkSize = 64 * 1024
        harness.server.respond(to: url, with: response)
        await #expect(throws: WebFontError.storage) { try await download(harness) }
        #expect(harness.leftovers.isEmpty)
    }

    @Test("a failed close is .storage, with nothing left")
    func failedClose() async throws {
        let harness = Harness()
        harness.files.fail(.close)
        harness.server.respond(to: url, with: .font(Data(repeating: 3, count: 1000)))
        await #expect(throws: WebFontError.storage) { try await download(harness) }
        #expect(harness.leftovers.isEmpty)
    }

    @Test("the mapping functions agree with DESIGN decision 19")
    func mappingTable() {
        #expect(ErrorMapping.map(URLError(.cannotFindHost)) == .offline)
        #expect(ErrorMapping.map(URLError(.cancelled)) == .network(.cancelled))
        #expect(ErrorMapping.map(status: 404) == .notFound)
        #expect(ErrorMapping.map(status: 418) == .server(statusCode: 418))
    }
}
