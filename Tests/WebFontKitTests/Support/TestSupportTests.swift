import Foundation
import OSLog
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct TestSupportTests {
    @Test("the lock marks its holder only inside withLock")
    func lockMarksHolder() {
        let lock = Locked(0)
        #expect(!LockHolder.isHeldByCurrentThread)
        let heldInside = lock.withLock { _ in LockHolder.isHeldByCurrentThread }
        #expect(heldInside)
        #expect(!LockHolder.isHeldByCurrentThread)
    }

    @Test("the recording sink notes whether the library's lock was held")
    func recordingSinkSeesLock() {
        let sink = RecordingLogSink()
        sink.log(category: "test", level: .info, message: "outside", privateValues: [])
        Locked(0).withLock { _ in
            sink.log(category: "test", level: .fault, message: "inside", privateValues: ["secret"])
        }
        #expect(sink.entries.map(\.message) == ["outside", "inside"])
        #expect(sink.entriesLoggedUnderLock.map(\.message) == ["inside"])
        #expect(sink.entries(level: .fault).first?.privateValues == ["secret"])
    }

    @Test(
        "every fixture font reads with the PostScript name and glyph count SOURCES.md records",
        arguments: [
            (Fixtures.latoRegular, "Lato-Regular", 272),
            (Fixtures.latoBold, "Lato-Bold", 272),
            (Fixtures.latoItalic, "Lato-Italic", 272),
            (Fixtures.latoBoldItalic, "Lato-BoldItalic", 272),
            (Fixtures.lobster, "Lobster-Regular", 1142),
            (Fixtures.lobsterV20, "Lobster-Regular", 1174),
            (Fixtures.notoSansKannada, "NotoSansKannada-Regular", 758),
            (Fixtures.bebasNeue, "BebasNeue-Regular", 497),
            (Fixtures.lobsterWoff, "Lobster-Regular", 1142),
            (Fixtures.lobsterWoff2, "Lobster-Regular", 333),
        ]
    )
    func fixtureFontReads(path: String, name: String, glyphs: Int) {
        let info = FakeRegistrar().faceInfo(at: Fixtures.url(path))
        #expect(info?.postScriptName == name)
        #expect(info?.glyphCount == glyphs)
    }

    @Test("no corrupt fixture reads as a font", arguments: Fixtures.corrupt)
    func corruptFixtureFails(path: String) {
        #expect(FakeRegistrar().faceInfo(at: Fixtures.url(path)) == nil)
    }

    @Test("the fake registrar answers 105 for the same file and 305 for another file with the same name")
    func fakeRegistrarCodes() async throws {
        let directory = TempDirectory()
        let first = directory.url.appending(component: "a.wfkfont")
        let second = directory.url.appending(component: "b.wfkfont")
        try Fixtures.data(Fixtures.lobster).write(to: first)
        try Fixtures.data(Fixtures.lobsterV20).write(to: second)
        let registrar = FakeRegistrar()

        #expect(await registrar.register(urls: [first]).isEmpty)
        #expect(await registrar.register(urls: [first]) == [first: FakeRegistrar.Code.alreadyRegistered])
        #expect(await registrar.register(urls: [second]) == [second: FakeRegistrar.Code.duplicatedName])
        #expect(registrar.activeFace(postScriptName: "Lobster-Regular")?.fileURL == first)
        #expect(registrar.openFace(postScriptName: "Lobster-Regular").glyphCount == 1142)

        try FileManager.default.removeItem(at: first)
        #expect(registrar.openFace(postScriptName: "Lobster-Regular").glyphCount == 7)
        #expect(await registrar.unregister(urls: [first]).isEmpty)
        #expect(registrar.registeredURLs.isEmpty)
        #expect(registrar.activeFace(postScriptName: "NoSuchFont-Regular") == nil)
    }

    @Test("a held register suspends until released")
    func fakeRegistrarHolds() async throws {
        let directory = TempDirectory()
        let file = directory.url.appending(component: "a.wfkfont")
        try Fixtures.data(Fixtures.latoRegular).write(to: file)
        let registrar = FakeRegistrar()
        registrar.holdRegister()

        let registration = Task { await registrar.register(urls: [file]) }
        try await registrar.heldRegisterArrivals.wait { $0.count == 1 }
        #expect(registrar.registeredURLs.isEmpty)
        registrar.releaseRegister()
        #expect(await registration.value.isEmpty)
        #expect(registrar.registeredURLs == [file])
    }

    @Test("the disk seam renames over a file, reports a missing delete and keeps extended attributes")
    func diskOperations() throws {
        let directory = TempDirectory()
        let files = FakeFileOperations()
        let partial = directory.url.appending(component: "\(UUID().uuidString).wfkpart")
        let marker = directory.url.appending(component: "Lobster@400n@system.wfkmark")

        let handle = try files.createPartial(at: partial)
        try files.append(Data("abc".utf8), to: handle)
        try files.close(handle)
        try files.setExtendedAttribute("com.webfontkit.postscript-name", value: Data("Lobster-Regular".utf8), at: partial)
        try files.setExcludedFromBackup(at: partial)
        try files.write(Data("old".utf8), to: marker)
        try files.rename(partial, to: marker)

        #expect(try Data(contentsOf: marker) == Data("abc".utf8))
        #expect(files.appendedBytes.elements == [3])
        #expect(try files.extendedAttribute("com.webfontkit.postscript-name", at: marker) == Data("Lobster-Regular".utf8))
        #expect(try files.extendedAttribute("com.webfontkit.missing", at: marker) == nil)
        #expect(try marker.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try files.contentsOfDirectory(at: directory.url).map(\.url.lastPathComponent) == [marker.lastPathComponent])
        #expect(try files.delete(at: marker))
        #expect(try !files.delete(at: marker))
        #expect(files.calls.allSatisfy { !$0.onMainThread })
    }

    @Test("an injected failure is thrown once and recorded")
    func injectedFailure() throws {
        let directory = TempDirectory()
        let files = FakeFileOperations()
        files.fail(.write, times: 1)
        let file = directory.url.appending(component: "x.wfkpart")
        #expect(throws: POSIXError.self) { try files.write(Data(), to: file) }
        try files.write(Data(), to: file)
        #expect(files.calls(.write).count == 2)
    }

    @Test("the stub answers by URL, sees the request's own User-Agent, and records the task type")
    func stubAnswers() async throws {
        let server = StubServer()
        let url = "https://fonts.example.test/a.ttf"
        server.respond(to: url, with: .font(Data("font".utf8)))
        let base = URLSessionConfiguration.ephemeral
        base.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 Safari"]
        let session = server.makeSession(base: base)
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("WebFontKit/test", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        #expect(data == Data("font".utf8))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let seen = try #require(server.requests.first)
        #expect(seen.url.absoluteString == url)
        #expect(seen.headers["User-Agent"] == "WebFontKit/test")
        #expect(!seen.isDownloadTask)

        let (_, missing) = try await session.data(from: URL(string: "https://fonts.example.test/none")!)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("a held stub response waits for release, and a cancel is seen before it finishes")
    func stubHolds() async throws {
        let server = StubServer()
        let held = "https://fonts.example.test/held.ttf"
        let cancelled = "https://fonts.example.test/cancelled.ttf"
        server.respond(to: held, with: .font(Data(repeating: 1, count: 1000), hold: .beforeResponse))
        server.respond(to: cancelled, with: .font(Data(repeating: 2, count: 1000), hold: .afterBytes(10)))
        let session = server.makeSession()

        let load = Task { try await session.data(from: URL(string: held)!).0 }
        try await server.waitForRequests { $0.absoluteString == held }
        server.release(held)
        #expect(try await load.value.count == 1000)

        let task = session.dataTask(with: URL(string: cancelled)!)
        task.resume()
        try await server.waitForRequests { $0.absoluteString == cancelled }
        task.cancel()
        try await server.waitForCancel(of: cancelled)
        server.release(cancelled)
    }

    @Test("the production log sink accepts a line")
    func loggerSink() {
        let sink: any LogSink = .logger
        sink.log(category: "test", level: .debug, message: "smoke", privateValues: ["value"])
    }
}
