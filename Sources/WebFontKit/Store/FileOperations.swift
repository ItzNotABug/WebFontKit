import Foundation

/// One file in a directory listing, with its date and size.
struct FileEntry: Sendable, Hashable {
    var url: URL
    var modificationDate: Date
    var byteCount: Int
}

/// Synchronous, never on the main thread.
protocol FileOperations: Sendable {
    func createDirectory(at url: URL) throws
    func contentsOfDirectory(at url: URL, includingDirectories: Bool) throws -> [FileEntry]
    /// One file's entry, or nil when there is no regular file.
    func fileEntry(at url: URL) throws -> FileEntry?
    func removeDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func write(_ data: Data, to url: URL) throws
    /// Atomic; replaces an existing destination.
    func rename(_ source: URL, to destination: URL) throws
    /// Returns false when there was no file.
    @discardableResult func delete(at url: URL) throws -> Bool
    func setExcludedFromBackup(at url: URL) throws

    func createPartial(at url: URL) throws -> FileHandle
    func append(_ data: Data, to handle: FileHandle) throws
    func close(_ handle: FileHandle) throws

    func setExtendedAttribute(_ name: String, value: Data, at url: URL) throws
    func extendedAttribute(_ name: String, at url: URL) throws -> Data?
}

extension FileOperations {
    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        try contentsOfDirectory(at: url, includingDirectories: false)
    }
}

/// The real disk.
struct DiskFileOperations: FileOperations {
    func createDirectory(at url: URL) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileEntry(at url: URL) throws -> FileEntry? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        // A listing's URLs carry cached values, which can outlive a file another process deleted.
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
        guard values.isRegularFile == true else { return nil }
        return FileEntry(url: url, modificationDate: values.contentModificationDate ?? .distantPast, byteCount: values.fileSize ?? 0)
    }

    func contentsOfDirectory(at url: URL, includingDirectories: Bool) throws -> [FileEntry] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants]
        )
        let keySet = Set(keys)
        return try urls.compactMap { fileURL in
            let values = try fileURL.resourceValues(forKeys: keySet)
            guard values.isRegularFile == true || (includingDirectories && values.isDirectory == true) else { return nil }
            return FileEntry(
                url: fileURL,
                modificationDate: values.contentModificationDate ?? .distantPast,
                byteCount: values.fileSize ?? 0
            )
        }
    }

    func removeDirectory(at url: URL) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard url.withUnsafeFileSystemRepresentation({ rmdir($0) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func fileExists(at url: URL) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func write(_ data: Data, to url: URL) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try data.write(to: url)
    }

    func rename(_ source: URL, to destination: URL) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in Darwin.rename(from, to) }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func delete(at url: URL) throws -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard url.withUnsafeFileSystemRepresentation({ unlink($0) }) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    func setExcludedFromBackup(at url: URL) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try url.setResourceValues(values)
    }

    func createPartial(at url: URL) throws -> FileHandle {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
        }
        return try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data, to handle: FileHandle) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try handle.write(contentsOf: data)
    }

    func close(_ handle: FileHandle) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try handle.close()
    }

    func setExtendedAttribute(_ name: String, value: Data, at url: URL) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let result = url.withUnsafeFileSystemRepresentation { path in
            value.withUnsafeBytes { bytes in setxattr(path, name, bytes.baseAddress, bytes.count, 0, 0) }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func extendedAttribute(_ name: String, at url: URL) throws -> Data? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let size = url.withUnsafeFileSystemRepresentation { getxattr($0, name, nil, 0, 0, 0) }
        guard size >= 0 else {
            if errno == ENOATTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var data = Data(count: size)
        let read = url.withUnsafeFileSystemRepresentation { path in
            data.withUnsafeMutableBytes { bytes in getxattr(path, name, bytes.baseAddress, size, 0, 0) }
        }
        guard read >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return data.prefix(read)
    }
}
