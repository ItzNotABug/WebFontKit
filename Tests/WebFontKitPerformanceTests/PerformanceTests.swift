import Foundation
import XCTest
@testable import WebFontKit
import WebFontKitTestSupport

/// Measured on a real iPhone against Xcode baselines; on a simulator they only
/// prove the target builds and runs.
final class PerformanceTests: XCTestCase {
    private static let perfFiles: [URL] = {
        let folder = Fixtures.url("Perf")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".ttf") }.sorted().map { folder.appendingPathComponent($0) }
    }()

    /// Copies the 20 Perf faces into a store under the names a load would give them.
    private func storePerfFaces(in directory: TempDirectory) throws {
        try FileManager.default.createDirectory(at: directory.store, withIntermediateDirectories: true)
        for file in Self.perfFiles {
            let family = String(file.deletingPathExtension().lastPathComponent.dropLast("-Regular".count))
            let name = StoredFileName.font(family: family, style: .regular, cacheKey: "\(family)|400|n", version: "v1")
            try FileManager.default.copyItem(at: file, to: directory.store.appendingPathComponent(name))
        }
    }

    func testFirstFrameLookup() throws {
        let directory = TempDirectory()
        let registry = Registry(registrar: CoreTextRegistrar(), files: DiskFileOperations(), logSink: RecordingLogSink())
        registry.state.withLock { state in
            state.table[FaceKey(family: "Lobster", style: .regular)] = RegistryEntry(
                postScriptName: "Lobster-Regular",
                kind: .file(url: directory.url.appendingPathComponent("x.wfkfont"), keyHash: "0", registeredHere: true)
            )
        }
        let key = FaceKey(family: "Lobster", style: .regular)
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<10_000 { _ = registry.postScriptName(for: key) }
        }
    }

    func testWarmUpOfTwentyFonts() throws {
        XCTAssertEqual(Self.perfFiles.count, 20)
        measure(metrics: [XCTClockMetric()]) {
            let directory = TempDirectory()
            try? storePerfFaces(in: directory)
            let registry = Registry(registrar: CoreTextRegistrar(), files: DiskFileOperations(), logSink: RecordingLogSink())
            let store = Store(directory: directory.store, files: DiskFileOperations())
            let done = expectation(description: "warm-up")
            Task.detached {
                let count = await registry.warmUp(store: store, cacheKey: { "\($0.family)|400|n" })
                XCTAssertEqual(count, 20)
                _ = try? await registry.remove(family: nil, directories: [store.directory])
                done.fulfill()
            }
            wait(for: [done], timeout: 30)
        }
    }

    func testCachedLoadRoundTrip() throws {
        let directory = TempDirectory()
        let server = StubServer()
        server.respondToOthers { request in
            request.url!.host == "fonts.googleapis.com" ? .css(Fixtures.css2Text("lobster")) : .font(Fixtures.data(Fixtures.lobster))
        }
        let fonts = WebFonts(configuration: .init(session: server.makeSession()), registrar: CoreTextRegistrar(),
                             fileOperations: DiskFileOperations(), root: directory.url, logSink: RecordingLogSink())
        let loaded = expectation(description: "first load")
        Task.detached { try? await fonts.load("Lobster"); loaded.fulfill() }
        wait(for: [loaded], timeout: 30)
        measure(metrics: [XCTClockMetric()]) {
            let done = expectation(description: "cached load")
            Task.detached { try? await fonts.load("Lobster"); done.fulfill() }
            wait(for: [done], timeout: 30)
        }
        let removed = expectation(description: "cleanup")
        Task.detached { try? await fonts.removeAll(); removed.fulfill() }
        wait(for: [removed], timeout: 30)
    }

    /// The body goes to disk, so peak memory must not grow by the body's size.
    func testDownloadMemory6MB() throws {
        try measureDownload(size: 6 * 1024 * 1024)
    }

    /// The size of the largest Google file (Chiron Sung HK italic).
    func testDownloadMemory30MB() throws {
        try measureDownload(size: 30 * 1024 * 1024)
    }

    private func measureDownload(size: Int) throws {
        do {
            let directory = TempDirectory()
            let server = StubServer()
            var response = StubResponse.font(Data(repeating: 0x41, count: size))
            response.chunkSize = 64 * 1024
            server.respond(to: "https://fonts.example.test/big.bin", with: response)
            let session = server.makeSession()
            measure(metrics: [XCTMemoryMetric()]) {
                let done = expectation(description: "download")
                Task.detached {
                    let partial = try? await Downloader.download(
                        URLRequest(url: URL(string: "https://fonts.example.test/big.bin")!), session: session,
                        into: directory.url, fileOperations: DiskFileOperations()
                    )
                    if let partial { try? FileManager.default.removeItem(at: partial) }
                    done.fulfill()
                }
                wait(for: [done], timeout: 60)
            }
        }
    }
}
