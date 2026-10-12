import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct WarmUpTests {
    @Test("a relaunch registers every stored face in one call, off the main thread, from the file names alone")
    func relaunch() async throws {
        let harness = Harness()
        try harness.storeFont(Fixtures.lobster, family: "Inter", style: FontStyle(weight: 100))
        try harness.storeFont(Fixtures.latoRegular, family: "Inter", style: FontStyle(weight: 200))
        try harness.storeFont(Fixtures.latoBold, family: "Poppins", style: FontStyle(weight: 600), version: "v1")

        let registry = harness.makeRegistry()
        let count = await registry.warmUp(store: harness.store, cacheKey: Harness.defaultKey)

        #expect(count == 3)
        #expect(harness.registrar.calls(.register).count == 1)
        #expect(harness.registrar.calls(.register).first?.urls.count == 3)
        #expect(registry.postScriptName(for: FaceKey(family: "Inter", style: FontStyle(weight: 100))) == "Lobster-Regular")
        #expect(registry.postScriptName(for: FaceKey(family: "Inter", style: FontStyle(weight: 200))) == "Lato-Regular")
        #expect(registry.postScriptName(for: FaceKey(family: "Poppins", style: FontStyle(weight: 600))) == "Lato-Bold")
        #expect(registry.downloaded.map(\.family) == ["Inter", "Inter", "Poppins"])
        #expect(harness.registrar.calls.allSatisfy { !$0.onMainThread })
        #expect(harness.files.calls.allSatisfy { !$0.onMainThread })
        #expect(harness.server.requests.isEmpty)
        #expect(harness.logSink.entriesLoggedUnderLock.isEmpty)
    }

    @Test("a warm-up redraws the views of the families it registered, and only those")
    func warmUpRedraws() async throws {
        let harness = Harness()
        try harness.storeFont(Fixtures.lobster, family: "Lobster")
        let registry = harness.makeRegistry()
        let lobster = registry.generations.counter(for: "Lobster")
        let inter = registry.generations.counter(for: "Inter")

        _ = await registry.warmUp(store: harness.store, cacheKey: Harness.defaultKey)

        #expect(lobster.value == 1)
        #expect(inter.value == 0)
    }

    @Test("of two files for one face, the one matching the current key is kept and the other deleted")
    func keyMatch() async throws {
        let harness = Harness()
        let old = try harness.storeFont(Fixtures.lobsterV20, family: "Lobster", cacheKey: "old", modified: Date())
        let current = try harness.storeFont(Fixtures.lobster, family: "Lobster", modified: Date().addingTimeInterval(-600))

        let count = await harness.makeRegistry().warmUp(store: harness.store, cacheKey: Harness.defaultKey)

        #expect(count == 1)
        #expect(harness.registrar.calls(.register).first?.urls == [current.url])
        #expect(!FileManager.default.fileExists(atPath: old.url.path))
    }

    @Test("with no file matching the current key, the newest is kept")
    func newestWhenNoneMatches() async throws {
        let harness = Harness()
        let older = try harness.storeFont(Fixtures.lobsterV20, family: "Lobster", cacheKey: "a", modified: Date().addingTimeInterval(-600))
        let newer = try harness.storeFont(Fixtures.lobster, family: "Lobster", cacheKey: "b", modified: Date())

        _ = await harness.makeRegistry().warmUp(store: harness.store, cacheKey: Harness.defaultKey)

        #expect(harness.registrar.calls(.register).first?.urls == [newer.url])
        #expect(!FileManager.default.fileExists(atPath: older.url.path))
    }

    @Test("files the library did not name, and stored files it cannot read, are skipped and kept")
    func foreignAndUnreadable() async throws {
        let harness = Harness()
        let foreign = harness.store.url(for: "App.ttf")
        let unparsable = harness.store.url(for: "garbage.wfkfont")
        try Fixtures.data(Fixtures.lobster).write(to: foreign)
        try Fixtures.data(Fixtures.lobster).write(to: unparsable)
        let corrupt = harness.store.url(for: StoredFileName.font(family: "Lato", style: .regular, cacheKey: "k", version: nil))
        try Data("not a font".utf8).write(to: corrupt)

        let count = await harness.makeRegistry().warmUp(store: harness.store, cacheKey: Harness.defaultKey)

        #expect(count == 0)
        #expect(harness.registrar.calls(.register).allSatisfy { $0.urls.isEmpty })
        for url in [foreign, unparsable, corrupt] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("two faces with one PostScript name: the first-sorting file is registered, the other kept unregistered")
    func sharedName() async throws {
        let harness = Harness()
        let regular = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        let bold = try harness.storeFont(Fixtures.lobster, family: "Lobster", style: .bold)

        let registry = harness.makeRegistry()
        let count = await registry.warmUp(store: harness.store, cacheKey: Harness.defaultKey)

        #expect(count == 1)
        #expect(harness.registrar.calls(.register).first?.urls == [regular.url])
        #expect(registry.entry(for: bold.key)?.registeredHere == false)
        #expect(registry.entry(for: regular.key)?.registeredHere == true)
        #expect(FileManager.default.fileExists(atPath: bold.url.path))
        #expect(registry.downloaded.count == 2)
    }

    @Test("a 305 for a system font at warm-up writes the marker with the file's name and deletes the file")
    func systemCollisionAtWarmUp() async throws {
        let harness = Harness()
        let face = try harness.storeFont(Fixtures.notoSansKannada, family: "Noto Sans Kannada")
        harness.registrar.scriptRegister(face.url, code: 305)
        harness.registrar.scriptActiveFace("NotoSansKannada-Regular", answer: ("NotoSansKannada-Regular", URL(fileURLWithPath: "/System/Library/Fonts/Kannada.ttc")))

        let registry = harness.makeRegistry()
        let count = await registry.warmUp(store: harness.store, cacheKey: Harness.defaultKey)

        #expect(count == 0)
        #expect(harness.directory.fileNames() == ["Noto%20Sans%20Kannada@400n@system.wfkmark"])
        #expect(registry.entry(for: face.key) == RegistryEntry(postScriptName: "NotoSansKannada-Regular", kind: .system))
        #expect(registry.downloaded.isEmpty)
    }

    @Test("a 305 for another instance's file at warm-up keeps the file with an entry not registered here")
    func otherInstanceAtWarmUp() async throws {
        let harness = Harness()
        let face = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        harness.registrar.scriptRegister(face.url, code: 305)
        harness.registrar.scriptActiveFace("Lobster-Regular", answer: ("Lobster-Regular", URL(fileURLWithPath: "/tmp/other/Lobster@400n@0000000000000000.wfkfont")))

        let registry = harness.makeRegistry()
        #expect(await registry.warmUp(store: harness.store, cacheKey: Harness.defaultKey) == 0)
        #expect(registry.entry(for: face.key)?.registeredHere == false)
        #expect(FileManager.default.fileExists(atPath: face.url.path))
    }

    @Test("a face whose open fails gets no entry and is unregistered")
    func failedOpenAtWarmUp() async throws {
        let harness = Harness()
        let face = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        harness.registrar.failOpen("Lobster-Regular")

        let registry = harness.makeRegistry()
        #expect(await registry.warmUp(store: harness.store, cacheKey: Harness.defaultKey) == 0)
        #expect(registry.entry(for: face.key) == nil)
        #expect(harness.registrar.registeredURLs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: face.url.path))
    }

    @Test("the insert step adds nothing after a removeAll, and skips a family removed since warm-up started")
    func insertStepEpochs() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let lobster = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        let inter = try harness.storeFont(Fixtures.latoRegular, family: "Inter")
        _ = await harness.registrar.register(urls: [lobster.url, inter.url])
        let faces = [lobster, inter].map { face in
            Registry.WarmFace(
                key: face.key,
                entry: RegistryEntry(postScriptName: face.postScriptName, kind: .file(url: face.url, keyHash: face.keyHash, registeredHere: true)),
                row: nil, counted: true
            )
        }

        _ = try await registry.remove(family: "Lobster", directories: [])
        #expect(await registry.insertWarmedUp(faces, recordedGlobal: 0, recordedFamilies: [:]) == 1)
        #expect(registry.entry(for: lobster.key) == nil)
        #expect(registry.entry(for: inter.key) != nil)
        #expect(harness.registrar.registeredURLs == [inter.url])

        _ = await harness.registrar.register(urls: [lobster.url])
        #expect(await registry.insertWarmedUp(faces, recordedGlobal: -1, recordedFamilies: [:]) == 0)
        #expect(!harness.registrar.registeredURLs.contains(lobster.url))
    }

    @Test("a stale partial is swept at warm-up and a young one is kept")
    func sweep() async throws {
        let harness = Harness()
        let old = harness.store.url(for: StoredFileName.partial())
        let young = harness.store.url(for: StoredFileName.partial())
        try Data().write(to: old)
        try Data().write(to: young)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3700)], ofItemAtPath: old.path)

        _ = await harness.makeRegistry().warmUp(store: harness.store, cacheKey: Harness.defaultKey)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: young.path))
    }
}
