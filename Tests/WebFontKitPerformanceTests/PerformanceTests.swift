import Foundation
import XCTest
@testable import WebFontKit
import WebFontKitTestSupport

/// The numbers mean something only when measured on a device; on a simulator or a Mac
/// these show that the target builds and runs.
final class PerformanceTests: XCTestCase {
    /// The 20 Perf faces, as fixture paths.
    private static func perfFixtures() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: Fixtures.url("Perf").path)
            .filter { $0.hasSuffix(".ttf") }.sorted().map { "Perf/\($0)" }
    }

    /// The 20 Perf faces, stored under the names a load would give them.
    private static func storePerfTemplate() throws -> TempDirectory {
        let directory = TempDirectory()
        for fixture in try perfFixtures() {
            let family = String(URL(fileURLWithPath: fixture).deletingPathExtension().lastPathComponent.dropLast("-Regular".count))
            _ = try Fixtures.storeFont(fixture, family: family, in: directory.store, version: "v1")
        }
        return directory
    }

    /// Copies, at new paths: CoreText has read none of them, so warm-up is measured cold.
    private static func storePerfFaces(from template: TempDirectory, in directory: TempDirectory) throws {
        try FileManager.default.createDirectory(at: directory.store, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: template.store, includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(at: file, to: directory.store.appending(component: file.lastPathComponent))
        }
    }

    /// Runs async work from XCTest's synchronous measure blocks, and rethrows its error.
    private func run<T: Sendable>(timeout: TimeInterval = 60, _ body: @escaping @Sendable () async throws -> T) throws -> T {
        let done = XCTestExpectation(description: "async work")
        let result = Locked<Result<T, any Error>?>(nil)
        let task = Task.detached {
            do {
                let value = try await body()
                result.withLock { $0 = .success(value) }
            } catch {
                result.withLock { $0 = .failure(error) }
            }
            done.fulfill()
        }
        if XCTWaiter.wait(for: [done], timeout: timeout) != .completed {
            // Cancelled and awaited, so a slow iteration can't run on into the next one.
            task.cancel()
            _ = XCTWaiter.wait(for: [done], timeout: 10)
            XCTFail("timed out after \(Int(timeout)) s")
        }
        return try XCTUnwrap(result.withLock { $0 }).get()
    }

    func testFirstFrameLookup() throws {
        let directory = TempDirectory()
        let registry = Registry(registrar: CoreTextRegistrar(), files: DiskFileOperations(), logSink: RecordingLogSink())
        registry.state.withLock { state in
            state.table[FaceKey(family: "Lobster", style: .regular)] = RegistryEntry(
                postScriptName: "Lobster-Regular",
                kind: .file(url: directory.url.appending(component: "x.wfkfont"), keyHash: "0", registeredHere: true)
            )
        }
        let key = FaceKey(family: "Lobster", style: .regular)
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<10_000 { _ = registry.postScriptName(for: key) }
        }
    }

    /// A catalogue lookup replaces a CSS2 round trip, so it must stay far below a millisecond.
    func testCatalogLookup() throws {
        let catalog = try XCTUnwrap(GoogleFontsCatalog.bundled)
        let families = ["Lobster", "Inter", "Roboto", "Noto Sans Kannada", "Playfair Display", "ABeeZee", "Zilla Slab"]
        measure(metrics: [XCTClockMetric()]) {
            for index in 0..<10_000 {
                _ = catalog.urls(family: families[index % families.count], styles: [.regular, .bold])
            }
        }
    }

    func testWarmUpOfTwentyFonts() throws {
        XCTAssertEqual(try Self.perfFixtures().count, 20)
        let template = try Self.storePerfTemplate()
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric()], options: options) {
            let directory = TempDirectory()
            let stored = Result { try Self.storePerfFaces(from: template, in: directory) }
            let registry = Registry(registrar: CoreTextRegistrar(), files: DiskFileOperations(), logSink: RecordingLogSink())
            let store = Store(directory: directory.store, files: DiskFileOperations())
            // Every iteration starts and stops, whatever throws, so XCTest reports only the real failure.
            startMeasuring()
            let warmed = Result { try stored.get(); return try run { await registry.warmUp(store: store, cacheKey: { "\($0.family)|400|n" }) } }
            stopMeasuring()
            do {
                XCTAssertEqual(try warmed.get(), 20)
                _ = try run { try await registry.remove(family: nil, directories: [store.directory]) }
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    func testCachedLoadRoundTrip() throws {
        let directory = TempDirectory()
        let server = StubServer()
        server.serveGoogle()
        let fonts = WebFonts(configuration: .init(session: server.makeSession()), registrar: CoreTextRegistrar(),
                             fileOperations: DiskFileOperations(), root: directory.url, logSink: RecordingLogSink())
        try run { try await fonts.load("Lobster") }
        measure(metrics: [XCTClockMetric()]) {
            do {
                try run { try await fonts.load("Lobster") }
            } catch {
                XCTFail("\(error)")
            }
        }
        try run { try await fonts.removeAll() }
    }

    /// The body goes to disk, so peak memory must not grow by the body's size.
    func testDownloadMemory6MB() throws {
        measureDownload(size: 6 * 1024 * 1024)
    }

    /// The size of the largest Google file (Chiron Sung HK italic).
    func testDownloadMemory30MB() throws {
        measureDownload(size: 30 * 1024 * 1024)
    }

    private func measureDownload(size: Int) {
        let directory = TempDirectory()
        let server = StubServer()
        let url = URL(string: "https://fonts.example.test/big.bin")!
        server.respond(to: url, with: .font(Data(repeating: 0x41, count: size)))
        let session = server.makeSession()
        measure(metrics: [XCTMemoryMetric()]) {
            do {
                try run {
                    let partial = try await Downloader.download(
                        URLRequest(url: url), session: session, into: directory.url, fileOperations: DiskFileOperations()
                    )
                    try FileManager.default.removeItem(at: partial)
                }
            } catch {
                XCTFail("\(error)")
            }
        }
    }
}
