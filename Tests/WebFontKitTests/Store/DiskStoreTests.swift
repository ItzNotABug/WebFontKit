import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct DiskStoreTests {
    private func age(_ url: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    @Test("only the library's own files are listed; foreign files are never touched")
    func ownedFilesOnly() throws {
        let harness = Harness()
        let store = harness.store
        let font = store.url(for: StoredFileName.font(family: "Lobster", style: .regular, cacheKey: "k", version: "v32"))
        let marker = store.url(for: StoredFileName.marker(family: "Noto Sans Kannada", style: .regular))
        let partial = store.url(for: StoredFileName.partial())
        let unreadable = store.url(for: "not-a-name.wfkfont")
        for url in [font, marker, partial, unreadable] {
            try Data("x".utf8).write(to: url)
        }
        let foreign = ["App.ttf", "photo.png", "old.tmp"]
        for name in foreign {
            try Data("mine".utf8).write(to: store.url(for: name))
            try Data("mine".utf8).write(to: harness.directory.url.appending(component: name))
            try age(store.url(for: name), by: 7200)
        }

        let owned = try store.ownedFiles()
        #expect(owned.count == 4)
        #expect(owned.contains { if case .font(let parsed, _) = $0 { return parsed.family == "Lobster" } else { return false } })
        #expect(owned.contains { if case .marker(let parsed, _) = $0 { return parsed.family == "Noto Sans Kannada" } else { return false } })
        #expect(owned.contains { if case .unreadable = $0 { return true } else { return false } })

        try store.sweepStalePartials(now: Date().addingTimeInterval(7200))
        for name in foreign {
            #expect(FileManager.default.fileExists(atPath: store.url(for: name).path))
            #expect(FileManager.default.fileExists(atPath: harness.directory.url.appending(component: name).path))
        }
        #expect(!harness.files.calls(.setExcludedFromBackup).contains { $0.url?.pathExtension == "ttf" })
    }

    @Test("a partial younger than an hour survives the sweep, and an older one is deleted")
    func stalePartials() throws {
        let harness = Harness()
        let young = harness.store.url(for: StoredFileName.partial())
        let old = harness.store.url(for: StoredFileName.partial())
        try Data().write(to: young)
        try Data().write(to: old)
        try age(young, by: 3000)
        try age(old, by: 3700)

        let swept = try harness.store.sweepStalePartials()

        #expect(swept == [old.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: young.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test("a file deleted after a listing reads as gone, not from the listing's cached values")
    func fileEntryIsFresh() throws {
        let directory = TempDirectory()
        let file = directory.url.appending(component: "Lobster@400n@abc.wfkfont")
        try Data("x".utf8).write(to: file)
        let files = DiskFileOperations()
        let listed = try #require(files.contentsOfDirectory(at: directory.url).first?.url)
        #expect(try files.fileEntry(at: listed) != nil)

        try FileManager.default.removeItem(at: file)
        // Callers read it with `try?`: a throw and a nil both mean gone.
        #expect((try? files.fileEntry(at: listed)) == nil)
    }

    @Test("a missing store directory lists nothing")
    func missingDirectory() throws {
        let directory = TempDirectory()
        let store = Store(directory: directory.url.appending(component: "absent", directoryHint: .isDirectory), files: FakeFileOperations())
        #expect(try store.ownedFiles().isEmpty)
        withExtendedLifetime(directory) {}
    }

    @Test("a marker is written as a partial, given its attribute and backup exclusion, then renamed")
    func markerOrder() throws {
        let harness = Harness()
        try harness.store.writeMarker(family: "Noto Sans Kannada", style: .regular, postScriptName: "NotoSansKannada-Regular")

        let calls = harness.files.calls.filter { [.write, .setExtendedAttribute, .setExcludedFromBackup, .rename].contains($0.operation) }
        #expect(calls.map(\.operation) == [.write, .setExtendedAttribute, .setExcludedFromBackup, .rename])
        #expect(calls.dropLast().allSatisfy { $0.url?.pathExtension == "wfkpart" })
        #expect(calls.last?.destination?.lastPathComponent == "Noto%20Sans%20Kannada@400n@system.wfkmark")

        let marker = harness.store.url(for: "Noto%20Sans%20Kannada@400n@system.wfkmark")
        #expect(try Data(contentsOf: marker).isEmpty)
        #expect(harness.store.markerName(at: marker) == "NotoSansKannada-Regular")
        #expect(try marker.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(harness.leftovers.isEmpty)
    }

    @Test("a failed marker write leaves no partial behind")
    func markerFailure() throws {
        let harness = Harness()
        harness.files.fail(.setExtendedAttribute)
        #expect(throws: (any Error).self) {
            try harness.store.writeMarker(family: "Lobster", style: .regular, postScriptName: "Lobster-Regular")
        }
        #expect(harness.directory.fileNames().isEmpty)
    }

    @Test("the default directory: Application Support, and on macOS a folder named after the bundle or process")
    func defaultDirectory() {
        let support = URL(fileURLWithPath: "/Users/me/Library/Application Support")
        #expect(StoreLocation.macOSDirectory(applicationSupport: support, bundleIdentifier: "com.example.app", processName: "app").path
            == "/Users/me/Library/Application Support/com.example.app")
        #expect(StoreLocation.macOSDirectory(applicationSupport: support, bundleIdentifier: nil, processName: "swift-test").path
            == "/Users/me/Library/Application Support/swift-test")
        #expect(StoreLocation.macOSDirectory(applicationSupport: support, bundleIdentifier: "", processName: "tool").lastPathComponent == "tool")
        let directory = StoreLocation.defaultDirectory()
        #if os(macOS)
        #expect(directory.deletingLastPathComponent().lastPathComponent == "Application Support")
        #else
        #expect(directory.lastPathComponent == "Application Support")
        #endif
    }

    @Test("files go in a WebFontKit subfolder of the configured directory")
    func persistentLocation() {
        let configured = URL(fileURLWithPath: "/tmp/group")
        #expect(StoreLocation.directory(isSession: false, configured: configured, root: nil).path == "/tmp/group/WebFontKit")
        #expect(StoreLocation.directory(isSession: false, configured: nil, root: URL(fileURLWithPath: "/tmp/root")).path == "/tmp/root/WebFontKit")
    }
}
