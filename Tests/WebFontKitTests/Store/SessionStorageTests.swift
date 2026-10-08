import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct SessionStorageTests {
    @Test("session storage uses a per-process folder under the temporary root and ignores a configured directory")
    func location() {
        let root = URL(fileURLWithPath: "/tmp/root")
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(StoreLocation.directory(isSession: true, configured: URL(fileURLWithPath: "/tmp/group"), root: root).path
            == "/tmp/root/WebFontKit-session/\(pid)")
    }

    @Test("a dead process's folder is deleted, a live one's kept, and this pid's folder emptied")
    func sweep() throws {
        let directory = TempDirectory()
        let files = FakeFileOperations()
        let own = ProcessInfo.processInfo.processIdentifier
        for pid in [own, 1, 99_999_999] {
            let folder = StoreLocation.sessionDirectory(root: directory.url, pid: pid)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent(StoredFileName.font(family: "Lobster", style: .regular, cacheKey: "k", version: nil)))
        }

        let deleted = try StoreLocation.sweepSessionFolders(root: directory.url, files: files)

        #expect(deleted == [99_999_999])
        let root = StoreLocation.sessionRoot(root: directory.url)
        #expect(directory.fileNames(in: root).sorted() == ["1", String(own)].sorted())
        #expect(directory.fileNames(in: root.appendingPathComponent("1")).count == 1)
        #expect(directory.fileNames(in: root.appendingPathComponent(String(own))).isEmpty)
    }

    @Test("kill reports a missing pid as dead and pid 1 as alive")
    func liveness() {
        #expect(!StoreLocation.processIsAlive(99_999_999))
        #expect(StoreLocation.processIsAlive(1))
        #expect(StoreLocation.processIsAlive(ProcessInfo.processInfo.processIdentifier))
    }
}
