import Foundation

/// A store directory. Only `.wfkfont`, `.wfkpart` and `.wfkmark` files are ever touched.
struct Store: Sendable {
    static let markerAttribute = "com.webfontkit.postscript-name"
    /// Younger partials may belong to another process's running download.
    static let stalePartialAge: TimeInterval = 3600

    let directory: URL
    let files: any FileOperations

    /// A file in the store the library named, by what it is.
    enum OwnedFile: Sendable, Equatable {
        case font(StoredFileName.Parsed, FileEntry)
        case marker(StoredFileName.Parsed, FileEntry)
        case partial(FileEntry)
        case unreadable(FileEntry)

        var entry: FileEntry {
            switch self {
            case .font(_, let entry), .marker(_, let entry), .partial(let entry), .unreadable(let entry): entry
            }
        }
    }

    /// With `family`, only that family's fonts and markers: names start with the encoded family,
    /// so a lookup never parses the rest of the store.
    func ownedFiles(family: String? = nil) throws -> [OwnedFile] {
        guard files.fileExists(at: directory) else { return [] }
        let prefix = family.map { StoredFileName.encode($0) + "@" }
        return try files.contentsOfDirectory(at: directory).compactMap { entry in
            let name = entry.url.lastPathComponent
            if let prefix, !name.hasPrefix(prefix) { return nil }
            switch entry.url.pathExtension {
            case StoredFileName.partialExtension:
                return .partial(entry)
            case StoredFileName.fontExtension:
                guard let parsed = StoredFileName.parse(name), case .font = parsed.kind else { return .unreadable(entry) }
                return .font(parsed, entry)
            case StoredFileName.markerExtension:
                guard let parsed = StoredFileName.parse(name), parsed.kind == .marker else { return nil }
                return .marker(parsed, entry)
            default:
                return nil
            }
        }
    }

    @discardableResult
    func sweepStalePartials(now: Date = Date()) throws -> [String] {
        var swept: [String] = []
        for case .partial(let entry) in try ownedFiles() where now.timeIntervalSince(entry.modificationDate) > Self.stalePartialAge {
            if try files.delete(at: entry.url) {
                swept.append(entry.url.lastPathComponent)
            }
        }
        return swept
    }

    func url(for name: String) -> URL {
        directory.appending(component: name)
    }

    /// Renamed into place last, so a marker never exists without its attribute.
    func writeMarker(family: String, style: FontStyle, postScriptName: String) throws {
        let partial = url(for: StoredFileName.partial())
        do {
            try files.write(Data(), to: partial)
            try files.setExtendedAttribute(Self.markerAttribute, value: Data(postScriptName.utf8), at: partial)
            try files.setExcludedFromBackup(at: partial)
            try files.rename(partial, to: url(for: StoredFileName.marker(family: family, style: style)))
        } catch {
            _ = try? files.delete(at: partial)
            throw error
        }
    }

    func markerName(at url: URL) -> String? {
        guard let data = try? files.extendedAttribute(Self.markerAttribute, at: url), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Where stores live: the configured folder's `WebFontKit/`, or the per-process session folder.
enum StoreLocation {
    static let subdirectory = "WebFontKit"
    static let sessionFolder = "WebFontKit-session"

    static func directory(isSession: Bool, configured: URL?, root: URL?) -> URL {
        if isSession {
            return sessionDirectory(root: root, pid: ProcessInfo.processInfo.processIdentifier)
        }
        return (configured ?? root ?? defaultDirectory()).appending(component: subdirectory, directoryHint: .isDirectory)
    }

    static func sessionRoot(root: URL?) -> URL {
        (root ?? URL.temporaryDirectory).appending(component: sessionFolder, directoryHint: .isDirectory)
    }

    static func sessionDirectory(root: URL?, pid: Int32) -> URL {
        sessionRoot(root: root).appending(component: String(pid), directoryHint: .isDirectory)
    }

    /// On macOS Application Support is shared by every app, hence the per-app folder.
    static func defaultDirectory() -> URL {
        let support = URL.applicationSupportDirectory
        #if os(macOS)
        return macOSDirectory(applicationSupport: support, bundleIdentifier: Bundle.main.bundleIdentifier,
                              processName: ProcessInfo.processInfo.processName)
        #else
        return support
        #endif
    }

    static func macOSDirectory(applicationSupport: URL, bundleIdentifier: String?, processName: String) -> URL {
        let name = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? processName
        return applicationSupport.appending(component: name, directoryHint: .isDirectory)
    }

    /// A folder with our own pid was left by an earlier process with that pid, so it is emptied.
    @discardableResult
    static func sweepSessionFolders(root: URL?, files: any FileOperations,
                                    pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                    emptyingOwn: Bool = true,
                                    isAlive: (Int32) -> Bool = processIsAlive) throws -> [Int32] {
        let sessionRoot = sessionRoot(root: root)
        guard files.fileExists(at: sessionRoot) else { return [] }
        var deleted: [Int32] = []
        for folder in try files.contentsOfDirectory(at: sessionRoot, includingDirectories: true) {
            guard let folderPID = Int32(folder.url.lastPathComponent) else { continue }
            let store = Store(directory: folder.url, files: files)
            if folderPID == pid {
                guard emptyingOwn else { continue }
                for owned in try store.ownedFiles() {
                    _ = try files.delete(at: owned.entry.url)
                }
            } else if !isAlive(folderPID) {
                for owned in try store.ownedFiles() {
                    _ = try files.delete(at: owned.entry.url)
                }
                try files.removeDirectory(at: folder.url)
                deleted.append(folderPID)
            }
        }
        return deleted
    }

    /// `EPERM` means alive; only `ESRCH` means dead.
    static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }
}
