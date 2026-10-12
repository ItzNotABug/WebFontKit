import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct HousekeepingTests {
    @Test("removing a family takes it out of the table, unregisters it and deletes its files, and nothing else")
    func removeFamily() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        try harness.storeFont(Fixtures.lobster, family: "Lobster")
        try harness.storeFont(Fixtures.latoRegular, family: "Inter")
        try harness.store.writeMarker(family: "Lobster", style: .bold, postScriptName: "Helvetica")
        let foreign = harness.store.url(for: "Lobster.ttf")
        try Data("mine".utf8).write(to: foreign)
        _ = await registry.warmUp(store: harness.store, cacheKey: Harness.defaultKey)
        harness.registrar.observeTable {
            registry.state.withLock { Set($0.table.keys.map(\.family)) }
        }

        let families = try await registry.remove(family: "Lobster", directories: [harness.store.directory])

        #expect(families == ["Lobster"])
        #expect(registry.entry(for: FaceKey(family: "Lobster", style: .regular)) == nil)
        #expect(registry.downloaded.map(\.family) == ["Inter"])
        #expect(harness.registrar.calls(.unregister).first?.table == ["Inter"])
        #expect(harness.directory.fileNames().filter { $0.hasPrefix("Lobster@") }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(harness.registrar.registeredURLs.count == 1)
        #expect(registry.epochs(for: "Lobster").family == 1)
    }

    @Test("removing everything leaves only foreign files, and reports each family once, sorted")
    func removeAll() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        try harness.storeFont(Fixtures.lobster, family: "Lobster")
        try harness.storeFont(Fixtures.latoRegular, family: "Inter")
        try Data().write(to: harness.store.url(for: "notes.txt"))
        _ = await registry.warmUp(store: harness.store, cacheKey: Harness.defaultKey)

        #expect(try await registry.remove(family: nil, directories: [harness.store.directory]) == ["Inter", "Lobster"])
        #expect(harness.directory.fileNames() == ["notes.txt"])
        #expect(harness.registrar.registeredURLs.isEmpty)
        #expect(registry.downloaded.isEmpty)
        #expect(registry.epochs(for: "Anything").global == 1)
    }

    @Test("removing a family with nothing stored succeeds and raises its epoch")
    func removeUnknown() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        #expect(try await registry.remove(family: "NeverLoaded", directories: [harness.store.directory]).isEmpty)
        #expect(harness.registrar.calls(.unregister).isEmpty)
        #expect(registry.epochs(for: "NeverLoaded").family == 1)
    }

    @Test("a shared name outlives its registered file: the other spelling's file is registered in its place")
    func sharedNameOutlives() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let upper = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        let lower = try harness.storeFont(Fixtures.lobster, family: "lobster")
        _ = await registry.register(upper, epochs: nil, store: harness.store)
        _ = await registry.register(lower, epochs: nil, store: harness.store)
        #expect(registry.entry(for: lower.key)?.registeredHere == false)
        let (upperCounter, lowerCounter) = await MainActor.run {
            (registry.generations.counter(for: "Lobster"), registry.generations.counter(for: "lobster"))
        }
        let before = await MainActor.run { (upperCounter.value, lowerCounter.value) }
        harness.registrar.observeTable {
            registry.state.withLock { Set($0.table.keys.map(\.family)) }
        }

        _ = try await registry.remove(family: "Lobster", directories: [harness.store.directory])

        let calls = harness.registrar.calls.filter { [.register, .unregister, .openFace].contains($0.method) }.suffix(3)
        #expect(calls.map(\.method) == [.unregister, .register, .openFace])
        #expect(calls.first?.urls == [upper.url])
        #expect(Array(calls)[1].urls == [lower.url])
        #expect(calls.dropLast().allSatisfy { $0.table == [] })
        #expect(registry.entry(for: lower.key)?.registeredHere == true)
        #expect(registry.downloaded.map(\.family) == ["lobster"])
        #expect(harness.registrar.registeredURLs == [lower.url])
        // The removed family's views and the re-registered one's both update.
        #expect(await MainActor.run { upperCounter.value } > before.0)
        #expect(await MainActor.run { lowerCounter.value } > before.1)
    }

    @Test("when the other spelling can't register again, its views still redraw")
    func sharedNameReregisterFails() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let upper = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        let lower = try harness.storeFont(Fixtures.lobster, family: "lobster")
        _ = await registry.register(upper, epochs: nil, store: harness.store)
        _ = await registry.register(lower, epochs: nil, store: harness.store)
        let lowerCounter = await MainActor.run { registry.generations.counter(for: "lobster") }
        let before = await MainActor.run { lowerCounter.value }
        harness.registrar.scriptRegister(lower.url, code: FakeRegistrar.Code.invalidFontData)

        _ = try await registry.remove(family: "Lobster", directories: [harness.store.directory])

        #expect(registry.entry(for: lower.key) == nil)
        #expect(await MainActor.run { lowerCounter.value } > before)
    }

    @Test("removing an unregistered entry's family unregisters and registers nothing")
    func removeUnregisteredEntry() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let upper = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        let lower = try harness.storeFont(Fixtures.lobster, family: "lobster")
        _ = await registry.register(upper, epochs: nil, store: harness.store)
        _ = await registry.register(lower, epochs: nil, store: harness.store)
        let registerCalls = harness.registrar.calls(.register).count

        _ = try await registry.remove(family: "lobster", directories: [harness.store.directory])

        #expect(harness.registrar.calls(.unregister).isEmpty)
        #expect(harness.registrar.calls(.register).count == registerCalls)
        #expect(!FileManager.default.fileExists(atPath: lower.url.path))
        #expect(registry.entry(for: upper.key)?.registeredHere == true)
    }

    @Test("both entries of a shared name leave in one call with one unregister and no registration")
    func bothLeave() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let regular = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        let bold = try harness.storeFont(Fixtures.lobster, family: "Lobster", style: .bold)
        _ = await registry.register(regular, epochs: nil, store: harness.store)
        _ = await registry.register(bold, epochs: nil, store: harness.store)

        _ = try await registry.remove(family: "Lobster", directories: [harness.store.directory])

        #expect(harness.registrar.calls(.unregister).map(\.urls) == [[regular.url]])
        #expect(harness.registrar.calls(.register).count == 1)
        #expect(harness.directory.fileNames().isEmpty)
    }

    @Test("a failed delete is .storage, after everything else is done")
    func failedDelete() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        try harness.storeFont(Fixtures.lobster, family: "Lobster")
        _ = await registry.warmUp(store: harness.store, cacheKey: Harness.defaultKey)
        harness.files.fail(.delete)

        await #expect(throws: WebFontError.storage) {
            try await registry.remove(family: "Lobster", directories: [harness.store.directory])
        }
        #expect(registry.entry(for: FaceKey(family: "Lobster", style: .regular)) == nil)
        #expect(harness.registrar.registeredURLs.isEmpty)
    }

    @Test(
        "the marker check returns the name of a good marker and deletes each stale kind",
        arguments: ["good", "missing", "unknown", "stored"]
    )
    func markerCheck(kind: String) throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let marker = harness.store.url(for: StoredFileName.marker(family: "Lobster", style: .regular))
        switch kind {
        case "missing":
            try Data().write(to: marker)
        case "unknown":
            try harness.store.writeMarker(family: "Lobster", style: .regular, postScriptName: "NoSuchFont-Regular")
        case "stored":
            try harness.store.writeMarker(family: "Lobster", style: .regular, postScriptName: "Lobster-Regular")
            harness.registrar.scriptActiveFace("Lobster-Regular", answer: ("Lobster-Regular", URL(fileURLWithPath: "/tmp/x/Lobster@400n@0000000000000000.wfkfont")))
        default:
            try harness.store.writeMarker(family: "Lobster", style: .regular, postScriptName: "Helvetica")
        }

        let verdict = registry.checkMarker(at: marker, store: harness.store)

        switch kind {
        case "good":
            #expect(verdict == .valid(postScriptName: "Helvetica"))
            #expect(FileManager.default.fileExists(atPath: marker.path))
        default:
            let reason: Registry.StaleMarkerReason = kind == "missing" ? .attributeMissing : kind == "unknown" ? .nameDoesNotResolve : .nameResolvesToStoredFont
            #expect(verdict == .stale(reason))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(harness.logSink.entries.contains { $0.message.contains(marker.lastPathComponent) && $0.message.contains(reason.rawValue) })
        }
    }
}
