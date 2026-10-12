import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct RegistryOrderTests {
    private func observeTable(_ harness: Harness, _ registry: Registry) {
        harness.registrar.observeTable {
            registry.state.withLock { Set($0.table.keys.map { "\($0.family) \($0.style.weight)\($0.style.isItalic ? "i" : "n")" }) }
        }
    }

    @Test("a face enters the table only after CoreText registered it, and is found by the first-frame check")
    func registerThenTable() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        observeTable(harness, registry)
        let face = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        // As a view does: read the family's counter, and another family's that must not change.
        let lobster = await MainActor.run { registry.generations.counter(for: "Lobster") }
        let other = await MainActor.run { registry.generations.counter(for: "Inter") }

        let result = await registry.register(face, epochs: registry.epochs(for: "Lobster"), store: harness.store)

        guard case .added(let entry) = result else { Issue.record("\(result)"); return }
        #expect(entry.registeredHere)
        #expect(registry.postScriptName(for: FaceKey(family: "Lobster", style: .regular)) == "Lobster-Regular")
        #expect(harness.registrar.calls(.register).first?.table == [])
        let row = try #require(registry.downloaded.first)
        #expect(row.family == "Lobster" && row.style == .regular && row.postScriptName == "Lobster-Regular")
        #expect(row.byteCount == 392_208)
        #expect(harness.registrar.calls.allSatisfy { !$0.onMainThread })
        #expect(harness.logSink.entriesLoggedUnderLock.isEmpty)
        #expect(await MainActor.run { lobster.value } == 1)
        #expect(await MainActor.run { other.value } == 0)
    }

    @Test("replacing a face stored under an old cache key redraws its views, even when the new file fails")
    func replaceRedraws() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let old = try harness.storeFont(Fixtures.lobsterV20, family: "Lobster", cacheKey: "old")
        _ = await registry.register(old, epochs: nil, store: harness.store)
        let current = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        harness.registrar.scriptRegister(current.url, code: FakeRegistrar.Code.invalidFontData)
        let lobster = await MainActor.run { registry.generations.counter(for: "Lobster") }
        let before = await MainActor.run { lobster.value }

        let epochs = registry.epochs(for: "Lobster")
        _ = await registry.registerReplacingStale(current, epochs: epochs, store: harness.store)

        #expect(registry.entry(for: old.key) == nil)
        #expect(await MainActor.run { lobster.value } > before)
    }

    @Test("a second (family, style) with a PostScript name the registry holds is not registered again")
    func sharedNameWithinRegistry() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let first = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        let second = try harness.storeFont(Fixtures.lobster, family: "Lobster", style: .bold)

        _ = await registry.register(first, epochs: nil, store: harness.store)
        let result = await registry.register(second, epochs: nil, store: harness.store)

        guard case .added(let entry) = result else { Issue.record("\(result)"); return }
        #expect(!entry.registeredHere)
        #expect(entry.fileURL == second.url)
        #expect(harness.registrar.calls(.register).count == 1)
        #expect(registry.postScriptName(for: second.key) == "Lobster-Regular")
        #expect(registry.downloaded.count == 2)
        #expect(harness.logSink.entries.contains { $0.message.contains("shares the PostScript name Lobster-Regular") })
    }

    @Test("a 305 for another instance's .wfkfont gives an entry not registered here, and no marker")
    func anotherInstancesFile() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let face = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        let otherInstance = TempDirectory()
        let other = otherInstance.url.appending(component: "Lobster@400n@0000000000000000.wfkfont")
        harness.registrar.scriptRegister(face.url, code: 305)
        harness.registrar.scriptActiveFace("Lobster-Regular", answer: ("Lobster-Regular", other))

        let result = await registry.register(face, epochs: nil, store: harness.store)

        guard case .added(let entry) = result else { Issue.record("\(result)"); return }
        #expect(!entry.registeredHere)
        #expect(FileManager.default.fileExists(atPath: face.url.path))
        #expect(!harness.directory.fileNames().contains { $0.hasSuffix(".wfkmark") })
        #expect(registry.downloaded.count == 1)
        withExtendedLifetime(otherInstance) {}
    }

    @Test("a 305 for a system font keeps a system-collision entry and a marker, and deletes the file")
    func systemCollision() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let face = try harness.storeFont(Fixtures.notoSansKannada, family: "Noto Sans Kannada")
        harness.registrar.scriptRegister(face.url, code: 305)
        harness.registrar.scriptActiveFace("NotoSansKannada-Regular", answer: ("NotoSansKannada-Regular", URL(fileURLWithPath: "/System/Library/Fonts/NotoSansKannada.ttc")))

        let result = await registry.register(face, epochs: nil, store: harness.store)

        #expect(result == .added(RegistryEntry(postScriptName: "NotoSansKannada-Regular", kind: .system)))
        #expect(!FileManager.default.fileExists(atPath: face.url.path))
        #expect(harness.directory.fileNames() == ["Noto%20Sans%20Kannada@400n@system.wfkmark"])
        let marker = harness.store.url(for: "Noto%20Sans%20Kannada@400n@system.wfkmark")
        #expect(harness.store.markerName(at: marker) == "NotoSansKannada-Regular")
        #expect(registry.downloaded.isEmpty)
        #expect(registry.postScriptName(for: face.key) == "NotoSansKannada-Regular")
        let order = harness.files.calls.filter { [.write, .setExtendedAttribute, .setExcludedFromBackup, .rename].contains($0.operation) }.map(\.operation)
        #expect(order == [.write, .setExtendedAttribute, .setExcludedFromBackup, .rename])
    }

    @Test("a face that fails the open is unregistered: .invalidFont while its file exists, .storage once it is gone")
    func failedOpen() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let face = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        harness.registrar.failOpen("Lobster-Regular")

        #expect(await registry.register(face, epochs: nil, store: harness.store) == .failed(.invalidFont))
        #expect(harness.registrar.registeredURLs.isEmpty)
        #expect(registry.entry(for: face.key) == nil)

        let gone = try harness.storeFont(Fixtures.latoRegular, family: "Lato")
        harness.registrar.scriptRegister(gone.url, code: 0)
        try FileManager.default.removeItem(at: gone.url)
        #expect(await registry.register(gone, epochs: nil, store: harness.store) == .failed(.storage))
    }

    @Test("an insert whose epochs changed adds nothing and undoes the registration")
    func overtaken() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let face = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        let stale = Epochs(global: 0, family: 0)
        _ = try await registry.remove(family: "Lobster", directories: [])

        #expect(await registry.register(face, epochs: stale, store: harness.store) == .overtaken)
        #expect(registry.entry(for: face.key) == nil)
        #expect(harness.registrar.registeredURLs.isEmpty)
    }

    @Test("a style alias is added only while the regular entry is in the table and the epochs are unchanged")
    func aliasInsert() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let bold = FaceKey(family: "Lobster", style: .bold)
        #expect(!(await registry.insertAlias(for: bold, epochs: registry.epochs(for: "Lobster"))))

        let face = try harness.storeFont(Fixtures.lobster, family: "Lobster")
        _ = await registry.register(face, epochs: nil, store: harness.store)
        let before = registry.epochs(for: "Lobster")
        #expect(await registry.insertAlias(for: bold, epochs: before))
        #expect(registry.postScriptName(for: bold) == "Lobster-Regular")
        #expect(registry.downloaded.count == 1)

        _ = try await registry.remove(family: "Lobster", directories: [harness.store.directory])
        #expect(registry.postScriptName(for: bold) == nil)
        _ = await registry.register(try harness.storeFont(Fixtures.lobster, family: "Lobster"), epochs: nil, store: harness.store)
        #expect(!(await registry.insertAlias(for: bold, epochs: before)))
    }

    @Test("the marker path's insert step records nothing on changed epochs")
    func systemEntryInsert() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let key = FaceKey(family: "Noto Sans Kannada", style: .regular)
        let recorded = registry.epochs(for: key.family)
        _ = try await registry.remove(family: nil, directories: [])
        #expect(!(await registry.insertSystemEntry(for: key, postScriptName: "NotoSansKannada-Regular", epochs: recorded)))
        #expect(await registry.insertSystemEntry(for: key, postScriptName: "NotoSansKannada-Regular", epochs: registry.epochs(for: key.family)))
        #expect(registry.postScriptName(for: key) == "NotoSansKannada-Regular")
    }
}
