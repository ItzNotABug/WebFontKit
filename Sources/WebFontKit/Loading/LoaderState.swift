import Foundation

/// Shared work is keyed by configuration, family, style and the removal epochs
/// the call recorded, so a load started after `remove` never joins older work.
struct StyleKey: Hashable, Sendable {
    var sourceID: Int
    var family: String
    var style: FontStyle
    var epochs: Epochs

    var face: FaceKey { FaceKey(family: family, style: style) }
}

/// One style's shared download: the family's CSS2 resolve (default source only),
/// then the fetch and validation, then one commit.
struct StyleJob: Sendable {
    enum Stage: Sendable {
        case resolving(UUID)
        case ready(URL, fromCatalog: Bool)
        case fetching
        case validated(ValidatedFace)
        case failed(WebFontError)
    }

    /// Tells this job's tasks from those of an abandoned job with the same key.
    let id = UUID()
    /// The configuration of the call that started it; its fetch uses this session and directory.
    let snapshot: Snapshot
    var stage: Stage
    var waiters: Set<UUID>
    var task: Task<Void, Never>?
    var commit: Task<CommitOutcome, Never>?
    /// Set when the commit finishes; the last waiter to leave after that drops the job.
    var outcome: CommitOutcome?
}

/// How one style's commit ended.
enum CommitOutcome: Sendable, Equatable {
    case added
    case overtaken
    case failed(WebFontError)
}

/// What a parked call is resumed with once every style it waits on has settled.
enum CallResult: Sendable {
    case settled(faces: [StyleKey: ValidatedFace], failures: [FontStyle: WebFontError])
    case cancelled
}

/// One `load` call waiting on its styles.
struct CallState: Sendable {
    var keys: [StyleKey]
    var continuation: CheckedContinuation<CallResult, Never>?
    var cancelled = false
    /// Errors of its styles whose jobs failed and were dropped.
    var failures: [FontStyle: WebFontError] = [:]
}

/// The closing events a starting call owes; they belong to the work, not the call's task.
struct PendingClose: Sendable {
    var family: String
    var styles: [FontStyle]
    var epochs: Epochs
    /// Keys not yet settled.
    var keys: Set<StyleKey>
    /// The styles it fetched; if every one is abandoned, nothing is sent.
    let needed: Set<FontStyle>
    var starterCancelled = false
    var failures: [FontStyle: WebFontError] = [:]
    /// Never reported.
    var abandoned: Set<FontStyle> = []

    /// `.loaded` for the styles that made it, then one `.failed` per error, in the order asked.
    static func events(family: String, asked: [FontStyle], failures: [FontStyle: WebFontError]) -> [WebFontEvent] {
        var events: [WebFontEvent] = []
        let loaded = asked.filter { failures[$0] == nil }
        if !loaded.isEmpty { events.append(.loaded(family: family, styles: loaded)) }
        var seen: [WebFontError] = []
        for style in asked {
            guard let error = failures[style], !seen.contains(error) else { continue }
            seen.append(error)
            events.append(.failed(family: family, styles: asked.filter { failures[$0] == error }, error: error))
        }
        return events
    }
}

/// Side effects decided under the lock and performed after it.
struct Effects: Sendable {
    var resumes: [(CheckedContinuation<CallResult, Never>, CallResult)] = []
    var start: [(key: StyleKey, url: URL, fromCatalog: Bool, job: UUID, snapshot: Snapshot)] = []
    var cancel: [Task<Void, Never>] = []
    var deletes: [URL] = []
    var closes: [(PendingClose, [WebFontEvent])] = []
}

/// Every load in flight: shared jobs, waiting calls, and the closing events they owe.
struct LoaderState: Sendable {
    var current: Snapshot
    var warmUpsStarted = 0
    #if DEBUG
    var warmUpsFinished = 0
    #endif
    var warmUp: Task<Void, Never>?
    var jobs: [StyleKey: StyleJob] = [:]
    /// Families whose catalogued files Google no longer serves; they go to CSS2 from then on.
    var catalogMisses: Set<String> = []
    var resolves: [UUID: (task: Task<Void, Never>?, keys: [StyleKey])] = [:]
    var calls: [UUID: CallState] = [:]
    var closes: [UUID: PendingClose] = [:]
    /// Tasks of abandoned jobs that are still running, by job; each leaves once its partial is deleted.
    var draining: [UUID: (key: StyleKey, task: Task<Void, Never>)] = [:]

    func familiesInFlight() -> Set<String> {
        Set(jobs.keys.map(\.family)).union(closes.values.map(\.family))
    }

    mutating func withdraw(_ call: UUID) {
        for key in calls[call]?.keys ?? [] {
            jobs[key]?.waiters.remove(call)
        }
    }

    // A settled key leaves its closes, so a later job under that key isn't credited to them.
    mutating func recordFailure(_ key: StyleKey, _ error: WebFontError) {
        for id in closes.keys where closes[id]!.keys.remove(key) != nil {
            closes[id]!.failures[key.style] = error
        }
    }

    mutating func settle(_ key: StyleKey, _ outcome: CommitOutcome) {
        switch outcome {
        case .added: for id in closes.keys { closes[id]!.keys.remove(key) }
        case .failed(let error): recordFailure(key, error)
        // `remove` overtook it: no closing event is owed.
        case .overtaken: markAbandoned(key)
        }
    }

    mutating func markAbandoned(_ key: StyleKey) {
        for id in closes.keys where closes[id]!.keys.remove(key) != nil {
            closes[id]!.abandoned.insert(key.style)
        }
    }

    /// Resumes every waiting call whose styles have all settled, starts each fetch
    /// whose waiters have all parked, and drops jobs nobody waits on.
    mutating func advance(_ effects: inout Effects) {
        // A failed job is dropped at once, so no later call joins it and the next one retries.
        for (key, job) in jobs {
            guard case .failed(let error) = job.stage else { continue }
            for waiter in job.waiters { calls[waiter]?.failures[key.style] = error }
            jobs[key] = nil
        }

        for (id, call) in calls where call.continuation != nil {
            var faces: [StyleKey: ValidatedFace] = [:]
            var failures = call.failures
            var pending = false
            for key in call.keys where failures[key.style] == nil {
                switch jobs[key]?.stage {
                case .validated(let face)?: faces[key] = face
                case nil: failures[key.style] = .notFound
                default: pending = true
                }
            }
            guard !pending else { continue }
            effects.resumes.append((call.continuation!, .settled(faces: faces, failures: failures)))
            calls[id]?.continuation = nil
        }

        for (key, job) in jobs {
            guard case .ready(let url, let fromCatalog) = job.stage, !job.waiters.isEmpty else { continue }
            // A call cancelled before parking withdraws as it parks, so no file is requested for it.
            if job.waiters.allSatisfy({ calls[$0]?.continuation != nil }) {
                jobs[key]?.stage = .fetching
                effects.start.append((key, url, fromCatalog, job.id, job.snapshot))
            }
        }

        // A job whose commit has finished is done once its last waiter leaves, cancelled or not.
        for (key, job) in jobs where job.waiters.isEmpty && job.outcome != nil { jobs[key] = nil }
        for (key, job) in jobs where job.waiters.isEmpty && job.commit == nil {
            switch job.stage {
            case .fetching:
                if let task = job.task {
                    effects.cancel.append(task)
                    draining[job.id] = (key, task)
                }
                markAbandoned(key)
            case .validated(let face):
                effects.deletes.append(face.partialURL)
                markAbandoned(key)
            case .resolving(let resolve):
                if let entry = resolves[resolve], entry.keys.allSatisfy({ jobs[$0]?.waiters.isEmpty ?? true }) {
                    if let task = entry.task { effects.cancel.append(task) }
                    resolves[resolve] = nil
                }
                markAbandoned(key)
            case .ready:
                markAbandoned(key)
            case .failed:
                break
            }
            jobs[key] = nil
        }
        settleCloses(&effects)
    }

    /// For a cancelled starter: once every key has settled. Abandoned styles aren't reported.
    mutating func settleCloses(_ effects: inout Effects) {
        for (id, close) in closes where close.starterCancelled && close.keys.isEmpty {
            if !close.abandoned.isSuperset(of: close.needed) {
                let styles = close.styles.filter { !close.abandoned.contains($0) }
                let events = PendingClose.events(family: close.family, asked: styles, failures: close.failures)
                effects.closes.append((close, events))
            }
            closes[id] = nil
        }
    }
}

/// The configuration in force, resolved once.
struct Snapshot: Sendable {
    let source: any FontSource
    var sourceID: Int
    var directory: URL
    var session: URLSession

    init(_ configuration: WebFonts.Configuration, sourceID: Int, root: URL?) {
        source = configuration.source
        self.sourceID = sourceID
        directory = StoreLocation.directory(isSession: configuration.storage == .session,
                                            configured: configuration.directory, root: root)
        session = configuration.session ?? LibrarySession.shared
    }

    var usesDefaultSource: Bool { source is DefaultFontSource }

    func cacheKey(_ key: FaceKey) -> String {
        source.cacheKey(for: FontRequest(family: key.family, style: key.style))
    }

    func keyHash(_ key: FaceKey) -> String {
        StoredFileName.keyHash(family: key.family, style: key.style, cacheKey: cacheKey(key))
    }
}
