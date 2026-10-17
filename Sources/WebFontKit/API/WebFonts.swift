import Foundation
import OSLog

/// Downloads fonts by family name, stores them, and registers them with CoreText,
/// so Apple's own font APIs draw them.
///
/// ```swift
/// await WebFonts.shared.load("Lobster")
/// Text("Hello").font(.custom("Lobster", size: 24))
/// ```
public final class WebFonts: Sendable {
    /// The instance apps use.
    ///
    /// ```swift
    /// WebFonts.shared.configure(.init(storage: .persistent))
    /// ```
    public static let shared = WebFonts()

    /// Where fonts come from and where they are kept. Every field has a default.
    ///
    /// ```swift
    /// WebFonts.shared.configure(.init(source: .default, storage: .persistent, directory: appGroupURL))
    /// ```
    public struct Configuration: Sendable {
        /// Whether downloaded files outlive the process.
        ///
        /// ```swift
        /// WebFonts.shared.configure(.init(storage: .session))
        /// ```
        public enum Storage: Sendable {
            /// Kept on disk and registered again at the next launch.
            ///
            /// ```swift
            /// WebFonts.shared.configure(.init(storage: .persistent, directory: appGroupURL))
            /// ```
            case persistent
            /// Kept for this process only; deleted at the next launch.
            ///
            /// ```swift
            /// WebFonts.shared.configure(.init(storage: .session))  // a preview or a one-off session
            /// ```
            case session
        }

        /// The font source. Default: Google Fonts (`.default`).
        ///
        /// ```swift
        /// var configuration = WebFonts.Configuration()
        /// configuration.source = .hosted(at: URL(string: "https://cdn.example.com/fonts")!)
        /// ```
        public var source: any FontSource

        /// Whether files outlive the process. Default: `.persistent`.
        ///
        /// ```swift
        /// configuration.storage = .session
        /// ```
        public var storage: Storage

        /// The folder WebFontKit creates its `WebFontKit/` subfolder in. Default (nil):
        /// Application Support, or `Application Support/<bundle id>` on macOS.
        ///
        /// ```swift
        /// configuration.directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app")
        /// ```
        public var directory: URL?

        /// The session downloads use. Default (nil): a dedicated ephemeral session. With the default
        /// source, most file URLs come from a bundled catalogue rather than a CSS2 answer.
        ///
        /// ```swift
        /// configuration.session = URLSession(configuration: myProxyConfiguration)
        /// ```
        public var session: URLSession?

        /// Creates a configuration; every argument has its default.
        ///
        /// ```swift
        /// let configuration = WebFonts.Configuration(storage: .session)
        /// ```
        public init(source: any FontSource = .default, storage: Storage = .persistent,
                    directory: URL? = nil, session: URLSession? = nil) {
            self.source = source
            self.storage = storage
            self.directory = directory
            self.session = session
        }
    }

    let registry: Registry
    let files: any FileOperations
    let logSink: any LogSink
    let root: URL?
    let hub = EventHub()
    /// Read on the first Google lookup, so creating `shared` does no I/O.
    let catalog: @Sendable () -> GoogleFontsCatalog?
    let state: Locked<LoaderState>
    #if DEBUG
    let hooks = TestHooks()
    #endif

    private convenience init() {
        self.init(configuration: nil, registrar: CoreTextRegistrar(), fileOperations: DiskFileOperations(), root: nil,
                  catalog: { GoogleFontsCatalog.bundled })
    }

    /// `configuration` is only the one in force until `configure`; the init itself
    /// starts nothing and does no I/O. `root` stands in for the default directory
    /// and for the temporary directory `.session` uses.
    init(configuration: Configuration?, registrar: any FontRegistrar, fileOperations: any FileOperations,
         root: URL?, logSink: any LogSink = .logger, catalog: @escaping @Sendable () -> GoogleFontsCatalog? = { nil }) {
        registry = Registry(registrar: registrar, files: fileOperations, logSink: logSink)
        files = fileOperations
        self.logSink = logSink
        self.root = root
        self.catalog = catalog
        state = Locked(LoaderState(current: Snapshot(configuration ?? Configuration(), sourceID: 0, root: root)))
    }

    /// Sets the source, storage, folder and session for later loads. Registers the
    /// saved fonts in the background the first time, and whenever the store changes.
    ///
    /// ```swift
    /// @main struct MyApp: App {
    ///     init() { WebFonts.shared.configure(.init(directory: appGroupURL)) }
    ///     var body: some Scene { WindowGroup { ContentView() } }
    /// }
    /// ```
    public func configure(_ configuration: Configuration) {
        state.withLock { state in
            let next = Snapshot(configuration, sourceID: state.current.sourceID + 1, root: root)
            let storeChanged = next.directory != state.current.directory
            state.current = next
            // Misses seen through another session or proxy may not hold for this one.
            state.catalogMisses = []
            if state.warmUpsStarted == 0 || storeChanged {
                startWarmUp(&state)
            }
        }
    }

    /// Loads one family's styles: from memory, from disk, or from the source. Never throws:
    /// each style loads or fails on its own, and its outcome is in the results, in the order asked.
    /// A cancelled load, or one `remove` overtakes, returns no results. A failed style isn't kept:
    /// the next `load` fetches it again; WebFontKit never retries on its own.
    ///
    /// ```swift
    /// let results = await WebFonts.shared.load("Inter", styles: [.regular, .bold])
    /// if case .failure(let error)? = results[.bold] { print(error) }
    /// ```
    @concurrent
    @discardableResult
    public func load(_ family: String, styles: [FontStyle] = [.regular]) async -> FontStyleResults {
        var seen = Set<FontStyle>()
        let unique = styles.filter { seen.insert($0).inserted }
        guard let failures = try? await loadRecordingEpochs(family, styles: unique).failures else {
            return FontStyleResults([], expected: unique.count)
        }
        return FontStyleResults(unique.map { style in (style, failures[style].map { .failure($0) } ?? .success(())) },
                                expected: unique.count)
    }

    /// Loads each family's regular style, several at once. Never throws: each
    /// family's outcome is in the results, in the order asked.
    ///
    /// ```swift
    /// let results = await WebFonts.shared.load(["Pacifico", "Bebas Neue"])
    /// print(results.allSucceeded)
    /// ```
    @concurrent
    @discardableResult
    public func load(_ families: [String]) async -> FontLoadResults {
        _ = beginUse()
        var seen = Set<String>()
        let unique = families.filter { seen.insert($0).inserted }
        var finished: [String: Result<Void, WebFontError>] = [:]
        await withTaskGroup(of: (String, Result<Void, WebFontError>?).self) { group in
            var pending = unique.makeIterator()
            func startNext() -> Bool {
                guard !Task.isCancelled, let family = pending.next() else { return false }
                group.addTask { [self] in
                    guard let failures = try? await loadRecordingEpochs(family, styles: [.regular]).failures else {
                        return (family, nil)
                    }
                    return (family, failures[.regular].map { .failure($0) } ?? .success(()))
                }
                return true
            }
            for _ in 0..<Self.batchConcurrency where startNext() {}
            for await (family, result) in group {
                finished[family] = result
                _ = startNext()
            }
        }
        let entries = unique.compactMap { family in finished[family].map { (family: family, result: $0) } }
        return FontLoadResults(entries, expected: unique.count)
    }

    static let batchConcurrency = 4

    /// Every load, warm-up and removal, as it happens. Each access is a new stream;
    /// the latest `.warmedUp` arrives first, and a slow reader keeps the newest 256.
    ///
    /// ```swift
    /// Task { for await event in WebFonts.shared.events { print(event) } }
    /// ```
    public var events: AsyncStream<WebFontEvent> {
        _ = beginUse()
        return hub.stream()
    }

    /// The faces stored and registered, from memory. Complete once `.warmedUp` has arrived.
    ///
    /// ```swift
    /// let names = WebFonts.shared.downloaded.map(\.postScriptName)
    /// ```
    public var downloaded: [DownloadedFont] {
        _ = beginUse()
        return registry.downloaded
    }

    /// Unregisters one family's faces and deletes its files. Views using it fall
    /// back to their fallback font.
    ///
    /// ```swift
    /// try await WebFonts.shared.remove("Lobster")
    /// ```
    @concurrent
    public func remove(_ family: String) async throws {
        try await removeFamilies(family)
    }

    /// Unregisters every face WebFontKit stored and deletes its files.
    ///
    /// ```swift
    /// try await WebFonts.shared.removeAll()
    /// ```
    @concurrent
    public func removeAll() async throws {
        try await removeFamilies(nil)
    }

    // MARK: Internals

    /// The first-frame check: the PostScript name to draw, or nil. Never starts anything.
    func postScriptName(family: String, style: FontStyle) -> String? {
        registry.postScriptName(for: FaceKey(family: family, style: style))
    }

    @concurrent
    func removeFamilies(_ family: String?) async throws {
        let snapshot = beginUse()
        await waitForWarmUp()
        let inFlight = state.withLock { $0.familiesInFlight() }
        // Read first: a failed delete throws after the table is already cleared.
        let held = registry.families(matching: family)
        var removed: [String] = []
        var failure: (any Error)?
        do {
            removed = try await registry.remove(family: family, directories: [snapshot.directory])
        } catch {
            failure = error
            removed = held.sorted()
        }
        if let family {
            hub.emit(.removed(family: family))
        } else {
            hub.emit(Set(removed).union(inFlight).sorted().map { .removed(family: $0) })
        }
        if let failure { throw failure }
    }

    func log(_ category: String, _ level: OSLogType, _ message: String) {
        logSink.log(category, level, message)
    }
}

#if DEBUG
/// Seams for tests, each nil unless a test sets it. Debug builds only.
final class TestHooks: Sendable {
    private struct Closures {
        var onJoin: (@Sendable (String) -> Void)?
        var beforePark: (@Sendable () async -> Void)?
        var beforeAlias: (@Sendable () async -> Void)?
        var onWarmUpWait: (@Sendable () -> Void)?
        var onFetch: (@Sendable (String) -> Void)?
    }

    private let closures = Locked(Closures())

    /// Called with the family each time a call joins work another call started.
    var onJoin: (@Sendable (String) -> Void)? {
        get { closures.withLock { $0.onJoin } }
        set { closures.withLock { $0.onJoin = newValue } }
    }

    /// Awaited by a call after it starts or joins work, before it waits on it.
    var beforePark: (@Sendable () async -> Void)? {
        get { closures.withLock { $0.beforePark } }
        set { closures.withLock { $0.beforePark = newValue } }
    }

    /// Awaited by the modifier between its regular load and its alias insert.
    var beforeAlias: (@Sendable () async -> Void)? {
        get { closures.withLock { $0.beforeAlias } }
        set { closures.withLock { $0.beforeAlias = newValue } }
    }

    /// Called with the family each time a face's download starts.
    var onFetch: (@Sendable (String) -> Void)? {
        get { closures.withLock { $0.onFetch } }
        set { closures.withLock { $0.onFetch = newValue } }
    }

    /// Called each time a caller starts waiting on an unfinished warm-up.
    var onWarmUpWait: (@Sendable () -> Void)? {
        get { closures.withLock { $0.onWarmUpWait } }
        set { closures.withLock { $0.onWarmUpWait = newValue } }
    }
}
#endif
