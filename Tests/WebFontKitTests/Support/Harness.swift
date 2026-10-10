import Foundation
@testable import WebFontKit
import WebFontKitTestSupport

/// One test's stubbed network, fake disk and registrar, and store directory.
final class Harness: Sendable {
    let server = StubServer()
    let directory = TempDirectory()
    let files = FakeFileOperations()
    let registrar = FakeRegistrar()
    let logSink = RecordingLogSink()
    let session: URLSession

    init(base: URLSessionConfiguration = .ephemeral, delegateQueue: OperationQueue? = nil) {
        session = server.makeSession(base: base, delegateQueue: delegateQueue)
        try? FileManager.default.createDirectory(at: directory.store, withIntermediateDirectories: true)
    }

    var fetcher: FaceFetcher {
        FaceFetcher(session: session, directory: directory.store, files: files, registrar: registrar, logSink: logSink)
    }

    func fetcher(sizeCap: Int) -> FaceFetcher {
        var fetcher = fetcher
        fetcher.sizeCap = sizeCap
        return fetcher
    }

    /// The library's own files left in the store.
    var leftovers: [String] {
        directory.fileNames().filter { $0.hasSuffix(".wfkpart") || $0.hasSuffix(".wfkfont") }
    }

    static let lobsterCSS2 = CSS2.url(family: "Lobster", styles: [.regular]).absoluteString
    static let lobsterFile = "https://fonts.gstatic.com/s/lobster/v32/neILzCirqoswsqX9_oU.ttf"

    /// Serves Google's real answer for Lobster and the v32 file.
    func serveLobster(file: StubResponse = .font(Fixtures.data(Fixtures.lobster))) {
        server.respond(to: Self.lobsterCSS2, with: .css(Fixtures.css2Text("lobster")))
        server.respond(to: Self.lobsterFile, with: file)
    }

    /// A body that starts with this test's own marker, so a leftover temporary
    /// file can be told apart from another test's.
    static func markedBody(count: Int, marker: String) -> Data {
        var body = Data(marker.utf8)
        body.append(Data(repeating: 0x5A, count: max(0, count - body.count)))
        return body
    }

    /// `CFNetworkDownload_*.tmp` files in the temporary directory that start with `marker`.
    static func systemTemporaryFiles(startingWith marker: String) -> [String] {
        let directory = URL.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { name in
            guard name.hasPrefix("CFNetworkDownload_"),
                  let handle = try? FileHandle(forReadingFrom: directory.appending(component: name))
            else { return false }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: marker.utf8.count)) == Data(marker.utf8)
        }
    }
}

/// A `RemoteFontSource` for tests: a fixed URL per face, with custom headers.
struct TestRemoteSource: RemoteFontSource {
    var base = URL(string: "https://fonts.example.test")!
    var headers: [String: String] = ["Authorization": "Bearer token", "X-Custom": "1"]
    var key: String?
    let fetchCalls = AsyncRecorder<FontRequest>()

    func url(for font: FontRequest) -> URL {
        base.appending(path: HostedFontSource.fileName(for: font))
    }

    func request(for font: FontRequest) async throws -> URLRequest {
        var request = URLRequest(url: url(for: font))
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    func fetch(_ font: FontRequest) async throws -> Data {
        fetchCalls.append(font)
        return Data()
    }

    func cacheKey(for font: FontRequest) -> String {
        key ?? "\(font.family)|custom"
    }
}

/// A remote source whose cache key, and file URL, carry a version the test can change.
final class VersionedSource: RemoteFontSource, Sendable {
    let version: Locked<String>

    init(version: String) {
        self.version = Locked(version)
    }

    func request(for font: FontRequest) async throws -> URLRequest {
        URLRequest(url: URL(string: "https://fonts.example.test/\(version.withLock { $0 })/\(font.family).ttf")!)
    }

    func cacheKey(for font: FontRequest) -> String {
        "\(font.family)-\(version.withLock { $0 })"
    }
}

/// A `FontSource` that fetches for itself.
struct TestDataSource: FontSource {
    var result: @Sendable (FontRequest) throws -> Data

    func fetch(_ font: FontRequest) async throws -> Data {
        try result(font)
    }
}

struct TestSourceError: Error, CustomStringConvertible {
    var description: String { "TestSourceError: the source broke" }
}
