import Foundation
import os
@testable import WebFontKit

/// The real disk, with every call recorded and failures injectable.
public final class FakeFileOperations: FileOperations, Sendable {
    public enum Operation: String, Sendable, CaseIterable {
        case createDirectory, contentsOfDirectory, removeDirectory, fileExists, write, rename, delete
        case setExcludedFromBackup, createPartial, append, close
        case setExtendedAttribute, extendedAttribute
    }

    public struct Call: Sendable {
        public let operation: Operation
        public let url: URL?
        /// The rename's destination.
        public let destination: URL?
        public let onMainThread: Bool
    }

    private struct Failure {
        var operation: Operation
        var matches: @Sendable (URL?) -> Bool
        var error: any Error
        var remaining: Int?
    }

    private struct State {
        var calls: [Call] = []
        var failures: [Failure] = []
        var dropsExtendedAttributes = false
    }

    private let disk = DiskFileOperations()
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var calls: [Call] {
        state.withLock { $0.calls }
    }

    public func calls(_ operation: Operation) -> [Call] {
        calls.filter { $0.operation == operation }
    }

    /// Makes `operation` throw `error` for URLs that `matching` accepts, `times`
    /// times (nil: every time).
    public func fail(
        _ operation: Operation,
        with error: any Error = POSIXError(.ENOSPC),
        times: Int? = nil,
        matching: @escaping @Sendable (URL?) -> Bool = { _ in true }
    ) {
        state.withLock {
            $0.failures.append(Failure(operation: operation, matches: matching, error: error, remaining: times))
        }
    }

    /// When true, `setExtendedAttribute` succeeds without writing, leaving a marker with no attribute.
    public func dropExtendedAttributes(_ drop: Bool = true) {
        state.withLock { $0.dropsExtendedAttributes = drop }
    }

    private func record(_ operation: Operation, _ url: URL?, destination: URL? = nil) throws {
        let call = Call(operation: operation, url: url, destination: destination, onMainThread: pthread_main_np() != 0)
        let error = state.withLock { state -> (any Error)? in
            state.calls.append(call)
            guard let index = state.failures.firstIndex(where: { $0.operation == operation && $0.matches(url) }) else {
                return nil
            }
            let failure = state.failures[index]
            if let remaining = failure.remaining {
                if remaining <= 1 {
                    state.failures.remove(at: index)
                } else {
                    state.failures[index].remaining = remaining - 1
                }
            }
            return failure.error
        }
        if let error { throw error }
    }

    public func createDirectory(at url: URL) throws {
        try record(.createDirectory, url)
        try disk.createDirectory(at: url)
    }

    public func contentsOfDirectory(at url: URL, includingDirectories: Bool) throws -> [FileEntry] {
        try record(.contentsOfDirectory, url)
        return try disk.contentsOfDirectory(at: url, includingDirectories: includingDirectories)
    }

    public func removeDirectory(at url: URL) throws {
        try record(.removeDirectory, url)
        try disk.removeDirectory(at: url)
    }

    public func fileExists(at url: URL) -> Bool {
        try? record(.fileExists, url)
        return disk.fileExists(at: url)
    }

    public func write(_ data: Data, to url: URL) throws {
        try record(.write, url)
        try disk.write(data, to: url)
    }

    public func rename(_ source: URL, to destination: URL) throws {
        try record(.rename, source, destination: destination)
        try disk.rename(source, to: destination)
    }

    public func delete(at url: URL) throws -> Bool {
        try record(.delete, url)
        return try disk.delete(at: url)
    }

    public func setExcludedFromBackup(at url: URL) throws {
        try record(.setExcludedFromBackup, url)
        try disk.setExcludedFromBackup(at: url)
    }

    public func createPartial(at url: URL) throws -> FileHandle {
        try record(.createPartial, url)
        return try disk.createPartial(at: url)
    }

    public func append(_ data: Data, to handle: FileHandle) throws {
        try record(.append, nil)
        try disk.append(data, to: handle)
    }

    public func close(_ handle: FileHandle) throws {
        try record(.close, nil)
        try disk.close(handle)
    }

    public func setExtendedAttribute(_ name: String, value: Data, at url: URL) throws {
        try record(.setExtendedAttribute, url)
        if state.withLock({ $0.dropsExtendedAttributes }) { return }
        try disk.setExtendedAttribute(name, value: value, at: url)
    }

    public func extendedAttribute(_ name: String, at url: URL) throws -> Data? {
        try record(.extendedAttribute, url)
        return try disk.extendedAttribute(name, at: url)
    }
}
