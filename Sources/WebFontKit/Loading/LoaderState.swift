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

    var isResolving: Bool {
        if case .resolving = stage { return true }
        return false
    }
}

/// How one style's commit ended.
enum CommitOutcome: Sendable, Equatable {
    case added
    case overtaken
    case failed(WebFontError)
}

/// What a parked call is resumed with.
enum CallResult: Sendable {
    case ready([StyleKey: ValidatedFace])
    case failed(WebFontError)
    case cancelled
}

/// One `load` call waiting on its styles.
struct CallState: Sendable {
    var keys: [StyleKey]
    var continuation: CheckedContinuation<CallResult, Never>?
    var cancelled = false
}

/// The closing event a starting call owes; it belongs to the work, not the call's task.
struct PendingClose: Sendable {
    var family: String
    var styles: [FontStyle]
    var epochs: Epochs
    var keys: Set<StyleKey>
    var starterCancelled = false
    var failure: WebFontError?
    var abandoned = false
    var committed: Set<StyleKey> = []
}

/// Side effects decided under the lock and performed after it.
struct Effects: Sendable {
    var resumes: [(CheckedContinuation<CallResult, Never>, CallResult)] = []
    var start: [(key: StyleKey, url: URL, fromCatalog: Bool, job: UUID, snapshot: Snapshot)] = []
    var cancel: [Task<Void, Never>] = []
    var deletes: [URL] = []
    var closes: [(PendingClose, WebFontEvent)] = []
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
    /// Tasks of abandoned jobs that are still running, by job; their partials are deleted when they end.
    var draining: [UUID: (key: StyleKey, task: Task<Void, Never>)] = [:]

    func familiesInFlight() -> Set<String> {
        Set(jobs.keys.map(\.family)).union(closes.values.map(\.family))
    }

    mutating func withdraw(_ call: UUID) {
        for key in calls[call]?.keys ?? [] {
            jobs[key]?.waiters.remove(call)
        }
    }

    mutating func recordFailure(_ key: StyleKey, _ error: WebFontError) {
        for id in closes.keys where closes[id]!.keys.contains(key) && closes[id]!.failure == nil {
            closes[id]!.failure = error
        }
    }

    /// Decides every waiting call whose styles have all been settled, starts each
    /// fetch whose waiters have all decided, and drops jobs nobody waits on.
    mutating func advance(_ effects: inout Effects) {
        for (id, call) in calls where call.continuation != nil {
            var faces: [StyleKey: ValidatedFace] = [:]
            var failure: WebFontError?
            var pending = false
            for key in call.keys {
                switch jobs[key]?.stage {
                case .failed(let error)?: failure = failure ?? error
                case .validated(let face)?: faces[key] = face
                case nil: failure = failure ?? .notFound
                default: pending = true
                }
            }
            if let failure {
                withdraw(id)
                effects.resumes.append((call.continuation!, .failed(failure)))
                calls[id]?.continuation = nil
            } else if !pending {
                effects.resumes.append((call.continuation!, .ready(faces)))
                calls[id]?.continuation = nil
            }
        }

        for (key, job) in jobs {
            guard case .ready(let url, let fromCatalog) = job.stage, !job.waiters.isEmpty else { continue }
            // Every waiter has parked and none waits on a resolve: a call about to fail on another
            // style (and so withdraw) has failed first, and no font file is requested for it.
            let decided = job.waiters.allSatisfy { waiter in
                guard let call = calls[waiter], call.continuation != nil else { return false }
                return call.keys.allSatisfy { jobs[$0]?.isResolving != true }
            }
            if decided {
                jobs[key]?.stage = .fetching
                effects.start.append((key, url, fromCatalog, job.id, job.snapshot))
            }
        }

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

    private mutating func markAbandoned(_ key: StyleKey) {
        for id in closes.keys where closes[id]!.keys.contains(key) {
            closes[id]!.abandoned = true
        }
    }

    /// For a cancelled starter, the first thing to happen to its styles decides.
    mutating func settleCloses(_ effects: inout Effects) {
        for (id, close) in closes where close.starterCancelled {
            if let failure = close.failure {
                effects.closes.append((close, .failed(family: close.family, styles: close.styles, error: failure)))
            } else if close.abandoned {
                // Every caller abandoned it: nothing is sent.
            } else if close.keys.isSubset(of: close.committed) {
                effects.closes.append((close, .loaded(family: close.family, styles: close.styles)))
            } else {
                continue
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
