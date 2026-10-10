#if DEBUG
import OSLog
@testable import WebFontKit

/// Records every log line instead of writing it to the unified log. One per
/// instance under test, so parallel tests never see each other's entries.
public final class RecordingLogSink: LogSink, Sendable {
    public struct Entry: Sendable {
        public let category: String
        public let level: OSLogType
        public let message: String
        public let privateValues: [String]
        /// Whether the library's lock was held on the logging thread, which the
        /// library must never do.
        public let lockHeld: Bool
    }

    private let recorded = OSAllocatedUnfairLock(initialState: [Entry]())

    public init() {}

    public func log(category: String, level: OSLogType, message: String, privateValues: [String]) {
        let entry = Entry(
            category: category,
            level: level,
            message: message,
            privateValues: privateValues,
            lockHeld: LockHolder.isHeldByCurrentThread
        )
        recorded.withLock { $0.append(entry) }
    }

    public var entries: [Entry] {
        recorded.withLock { $0 }
    }

    public func entries(level: OSLogType) -> [Entry] {
        entries.filter { $0.level == level }
    }

    /// Entries logged while the library's lock was held; always empty in a correct library.
    public var entriesLoggedUnderLock: [Entry] {
        entries.filter(\.lockHeld)
    }
}
#endif
