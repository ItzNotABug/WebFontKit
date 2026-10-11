import Foundation

extension WebFonts {
    // MARK: Warm-up

    /// The first use of an unconfigured instance starts warm-up with the configuration in force.
    func beginUse() -> Snapshot {
        state.withLock { state in
            if state.warmUpsStarted == 0 {
                startWarmUp(&state)
            }
            return state.current
        }
    }

    /// Called under the lock. Warm-ups never overlap: each waits for the one before.
    func startWarmUp(_ state: inout LoaderState) {
        state.warmUpsStarted += 1
        let previous = state.warmUp
        let snapshot = state.current
        let first = state.warmUpsStarted == 1
        state.warmUp = Task { [self] in
            await previous?.value
            await runWarmUp(snapshot, first: first)
        }
    }

    @concurrent
    func runWarmUp(_ snapshot: Snapshot, first: Bool) async {
        try? files.createDirectory(at: snapshot.directory)
        do {
            // Our own session folder is emptied at launch only: a re-warm must keep the
            // session's registered faces and in-flight partials.
            try StoreLocation.sweepSessionFolders(root: root, files: files, emptyingOwn: first)
        } catch {
            log("warmup", .error, "Could not sweep old session folders: \(error)")
        }
        let count = await registry.warmUp(
            store: Store(directory: snapshot.directory, files: files),
            cacheKey: { snapshot.cacheKey($0) }
        )
        #if DEBUG
        state.withLock { $0.warmUpsFinished += 1 }
        #endif
        hub.emit(.warmedUp(count: count))
    }

    /// Waits for the latest warm-up that has started.
    func waitForWarmUp() async {
        #if DEBUG
        if state.withLock({ $0.warmUpsFinished < $0.warmUpsStarted }) { hooks.onWarmUpWait?() }
        #endif
        await state.withLock { $0.warmUp }?.value
    }

    // MARK: Loading

    /// `load`, also returning the removal epochs it recorded (the modifier's style alias needs them).
    @concurrent
    func loadRecordingEpochs(_ family: String, styles: [FontStyle]) async throws -> Epochs {
        let snapshot = beginUse()
        var seen = Set<FontStyle>()
        let styles = styles.filter { seen.insert($0).inserted }
        let epochs = registry.epochs(for: family)
        guard !styles.isEmpty else { return epochs }

        guard Self.isValidFamilyName(family, defaultSource: snapshot.usesDefaultSource) else {
            log("load", .debug, "Rejected the family name \"\(family)\" before any request")
            hub.emit([.loading(family: family, styles: styles), .failed(family: family, styles: styles, error: .notFound)])
            throw WebFontError.notFound
        }

        var needed = missing(styles, family: family, snapshot: snapshot)
        guard !needed.isEmpty else { return epochs }
        await waitForWarmUp()
        needed = missing(needed, family: family, snapshot: snapshot)
        guard !needed.isEmpty else { return epochs }
        needed = try await lookUpStore(family, styles: needed, snapshot: snapshot, epochs: epochs)
        guard !needed.isEmpty else { return epochs }
        try await fetchAndCommit(family, asked: styles, needed: needed, snapshot: snapshot, epochs: epochs)
        return epochs
    }

    private func fetchAndCommit(_ family: String, asked: [FontStyle], needed: [FontStyle],
                                snapshot: Snapshot, epochs: Epochs) async throws {
        let call = UUID()
        let keys = needed.map { StyleKey(sourceID: snapshot.sourceID, family: family, style: $0, epochs: epochs) }
        let (starts, resolve, joined) = state.withLock { state -> ([(StyleKey, UUID)], (UUID, [StyleKey])?, Bool) in
            var toStart: [StyleKey] = []
            for key in keys {
                if state.jobs[key] != nil {
                    state.jobs[key]!.waiters.insert(call)
                } else {
                    toStart.append(key)
                }
            }
            state.calls[call] = CallState(keys: keys)
            let joined = toStart.count < keys.count
            guard !toStart.isEmpty else { return ([], nil, joined) }
            state.closes[call] = PendingClose(family: family, styles: asked, epochs: epochs, keys: Set(keys))
            var resolve: (UUID, [StyleKey])?
            if snapshot.usesDefaultSource {
                let id = UUID()
                for key in toStart {
                    state.jobs[key] = StyleJob(snapshot: snapshot, stage: .resolving(id), waiters: [call])
                }
                state.resolves[id] = (nil, toStart)
                resolve = (id, toStart)
            } else {
                for key in toStart {
                    state.jobs[key] = StyleJob(snapshot: snapshot, stage: .fetching, waiters: [call])
                }
            }
            return (toStart.map { ($0, state.jobs[$0]!.id) }, resolve, joined)
        }
        #if DEBUG
        if joined { hooks.onJoin?(family) }
        #endif
        if !starts.isEmpty {
            hub.emit(.loading(family: family, styles: asked))
            if let (id, resolveKeys) = resolve {
                startResolve(id, keys: resolveKeys, snapshot: snapshot)
            } else {
                for (key, job) in starts { startFetch(key, url: nil, fromCatalog: false, job: job, snapshot: snapshot) }
            }
        }

        #if DEBUG
        await hooks.beforePark?()
        #endif
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CallResult, Never>) in
                let (effects, cancelled) = state.withLock { state -> (Effects, Bool) in
                    var effects = Effects()
                    let cancelled = state.calls[call]?.cancelled == true
                    // Cancelled before parking: withdraw, and let work only it wanted stop.
                    if cancelled {
                        state.withdraw(call)
                    } else {
                        state.calls[call]?.continuation = continuation
                    }
                    state.advance(&effects)
                    return (effects, cancelled)
                }
                perform(effects)
                if cancelled { continuation.resume(returning: .cancelled) }
            }
        } onCancel: {
            cancel(call)
        }

        switch result {
        case .cancelled:
            state.withLock { _ = $0.calls.removeValue(forKey: call) }
            throw CancellationError()
        case .failed(let error):
            let draining = state.withLock { state in
                state.calls[call] = nil
                return state.draining.values.filter { keys.contains($0.key) }.map(\.task)
            }
            for task in draining { await task.value }
            close(call, with: .failed(family: family, styles: asked, error: error))
            throw error
        case .ready(let faces):
            var outcomes: [CommitOutcome] = []
            for key in keys {
                guard let face = faces[key] else { continue }
                let (commit, finished) = state.withLock { state -> (Task<CommitOutcome, Never>?, CommitOutcome?) in
                    guard var job = state.jobs[key] else { return (nil, nil) }
                    if job.commit == nil {
                        job.commit = Task { [self] in await self.commit(key, face: face, snapshot: snapshot) }
                    }
                    job.waiters.remove(call)
                    // A commit that already finished left the job to its last waiter to drop.
                    if let outcome = job.outcome {
                        state.jobs[key] = job.waiters.isEmpty ? nil : job
                        return (nil, outcome)
                    }
                    state.jobs[key] = job
                    return (job.commit, nil)
                }
                if let finished {
                    outcomes.append(finished)
                } else {
                    // Never nil: the call is still a waiter, so its job is there.
                    outcomes.append(await commit?.value ?? .overtaken)
                }
            }
            state.withLock { _ = $0.calls.removeValue(forKey: call) }
            if outcomes.contains(.overtaken) {
                close(call, with: nil)
                throw CancellationError()
            }
            if Task.isCancelled {
                let effects = state.withLock { state -> Effects in
                    state.closes[call]?.starterCancelled = true
                    var effects = Effects()
                    state.settleCloses(&effects)
                    return effects
                }
                perform(effects)
                throw CancellationError()
            }
            if let failure = outcomes.lazy.compactMap({ if case .failed(let error) = $0 { error } else { nil } }).first {
                close(call, with: .failed(family: family, styles: asked, error: failure))
                throw failure
            }
            close(call, with: .loaded(family: family, styles: asked))
        }
    }

    /// The starting call sends its own closing event, unless `remove` overtook it.
    private func close(_ call: UUID, with event: WebFontEvent?) {
        guard let close = state.withLock({ $0.closes.removeValue(forKey: call) }), let event else { return }
        emitIfCurrent(close, event)
    }

    /// A parked call withdraws at once; one not yet parked withdraws as it parks.
    private func cancel(_ call: UUID) {
        let effects = state.withLock { state -> Effects in
            var effects = Effects()
            state.calls[call]?.cancelled = true
            state.closes[call]?.starterCancelled = true
            if let continuation = state.calls[call]?.continuation {
                state.withdraw(call)
                state.calls[call]?.continuation = nil
                effects.resumes.append((continuation, .cancelled))
            }
            state.advance(&effects)
            return effects
        }
        perform(effects)
    }

    /// Runs after unlocking. A cancel can arrive on the main thread, where no file is touched.
    private func perform(_ effects: Effects) {
        // Deleted before any waiter resumes, so a failed call leaves nothing behind.
        if !effects.deletes.isEmpty {
            let files = files
            if !Thread.isMainThread {
                for url in effects.deletes { _ = try? files.delete(at: url) }
            } else {
                Task.detached { for url in effects.deletes { _ = try? files.delete(at: url) } }
            }
        }
        for (continuation, result) in effects.resumes {
            continuation.resume(returning: result)
        }
        for task in effects.cancel {
            task.cancel()
        }
        for start in effects.start {
            startFetch(start.key, url: start.url, fromCatalog: start.fromCatalog, job: start.job, snapshot: start.snapshot)
        }
        for (close, event) in effects.closes {
            emitIfCurrent(close, event)
        }
    }

    /// A closing event is sent only if `remove` hasn't overtaken the load since it started.
    private func emitIfCurrent(_ close: PendingClose, _ event: WebFontEvent) {
        if registry.epochs(for: close.family) == close.epochs {
            hub.emit(event)
        }
    }

    private func startResolve(_ id: UUID, keys: [StyleKey], snapshot: Snapshot) {
        guard let family = keys.first?.family else { return }
        let task = Task { [self] in
            let outcome: Result<[FontStyle: URL], WebFontError>
            // Every style in the bundled catalogue: no CSS2 request. Any miss asks CSS2 for all of them.
            let trusted = !state.withLock { $0.catalogMisses.contains(family) }
            let catalogued = trusted ? catalog()?.urls(family: family, styles: keys.map(\.style)) : nil
            if let catalogued {
                outcome = .success(catalogued)
            } else {
                do {
                    outcome = .success(try await CSS2.resolve(family: family, styles: keys.map(\.style),
                                                              session: snapshot.session, logSink: logSink))
                } catch let error as WebFontError {
                    outcome = .failure(error)
                } catch {
                    // A cancelled resolve's jobs are already gone, so this only ends jobs still waiting.
                    outcome = .failure(.network(.cancelled))
                }
            }
            let effects = state.withLock { state -> Effects in
                for key in keys {
                    guard case .resolving(id)? = state.jobs[key]?.stage else { continue }
                    switch outcome {
                    case .success(let urls):
                        if let url = urls[key.style] {
                            state.jobs[key]?.stage = .ready(url, fromCatalog: catalogued != nil)
                        } else {
                            state.jobs[key]?.stage = .failed(.notFound)
                            state.recordFailure(key, .notFound)
                        }
                    case .failure(let error):
                        state.jobs[key]?.stage = .failed(error)
                        state.recordFailure(key, error)
                    }
                }
                state.resolves[id] = nil
                var effects = Effects()
                state.advance(&effects)
                return effects
            }
            perform(effects)
        }
        state.withLock { state in
            if state.resolves[id] != nil { state.resolves[id]?.task = task }
        }
    }

    /// A catalogued URL Google answers with an error status falls back to CSS2, as without a
    /// catalogue, and the family skips the catalogue from then on.
    private func fetchResolved(_ url: URL, fromCatalog: Bool, key: StyleKey, fetcher: FaceFetcher,
                               snapshot: Snapshot) async throws -> ValidatedFace {
        do {
            return try await fetcher.fetchResolved(url)
        } catch let error as WebFontError where fromCatalog && error.isStatusFailure {
            if error.meansGone { state.withLock { _ = $0.catalogMisses.insert(key.family) } }
            log("load", .info, "The catalogued URL for \(key.face) failed (\(error)); asking CSS2")
            let fresh = try await CSS2.resolve(family: key.family, style: key.style, session: snapshot.session, logSink: logSink)
            return try await fetcher.fetchResolved(fresh)
        }
    }

    private func startFetch(_ key: StyleKey, url: URL?, fromCatalog: Bool, job: UUID, snapshot: Snapshot) {
        #if DEBUG
        hooks.onFetch?(key.family)
        #endif
        let task = Task { [self] in
            let fetcher = FaceFetcher(session: snapshot.session, directory: snapshot.directory, files: files,
                                      registrar: registry.registrar, logSink: logSink)
            let outcome: Result<ValidatedFace, WebFontError>
            do {
                try files.createDirectory(at: snapshot.directory)
                if let url {
                    outcome = .success(try await fetchResolved(url, fromCatalog: fromCatalog, key: key, fetcher: fetcher, snapshot: snapshot))
                } else {
                    outcome = .success(try await fetcher.fetchCustom(FontRequest(family: key.family, style: key.style), from: snapshot.source))
                }
            } catch let error as WebFontError {
                outcome = .failure(error)
            } catch is CancellationError {
                // Only a current job records it: our own cancel has already dropped the job, and a
                // source's own `CancellationError` must still end it.
                outcome = .failure(.network(.cancelled))
            } catch {
                outcome = .failure(.storage)
            }
            let (effects, orphan) = state.withLock { state -> (Effects, URL?) in
                var effects = Effects()
                var orphan: URL?
                state.draining[job] = nil
                // A job abandoned and started again under the same key is a different job.
                let current = state.jobs[key]?.id == job
                switch outcome {
                case .success(let face):
                    if current, case .fetching? = state.jobs[key]?.stage {
                        state.jobs[key]?.stage = .validated(face)
                    } else {
                        orphan = face.partialURL
                    }
                case .failure(let error):
                    if current {
                        state.jobs[key]?.stage = .failed(error)
                        state.recordFailure(key, error)
                    }
                }
                state.advance(&effects)
                return (effects, orphan)
            }
            if let orphan {
                _ = try? files.delete(at: orphan)
            }
            perform(effects)
        }
        let attached = state.withLock { state -> Bool in
            guard state.jobs[key]?.id == job else { return false }
            state.jobs[key]?.task = task
            return true
        }
        // Its job was dropped before the task could attach, so nothing else would cancel it.
        if !attached { task.cancel() }
    }

    /// Rename, register and add to the table, once per style. Commits of one
    /// (family, style) never overlap, so an overtaken commit's undo finishes first.
    @concurrent
    private func commit(_ key: StyleKey, face: ValidatedFace, snapshot: Snapshot) async -> CommitOutcome {
        let faceKey = key.face
        let outcome = await registry.faceTurns.with(faceKey) { () async -> CommitOutcome in
            let hash = snapshot.keyHash(faceKey)
            let final = snapshot.directory.appending(component: 
                StoredFileName.font(family: key.family, style: key.style, cacheKey: snapshot.cacheKey(faceKey), version: face.version)
            )
            do {
                try files.rename(face.partialURL, to: final)
            } catch {
                _ = try? files.delete(at: face.partialURL)
                return registry.epochs(for: key.family) != key.epochs ? .overtaken : .failed(.storage)
            }
            let stored = StoredFace(key: faceKey, url: final, keyHash: hash, postScriptName: face.postScriptName,
                                    glyphCount: face.glyphCount, familyName: face.familyName)
            switch await registry.registerReplacingStale(stored, epochs: key.epochs, store: Store(directory: snapshot.directory, files: files)) {
            case .added:
                return .added
            case .overtaken:
                _ = try? files.delete(at: final)
                return .overtaken
            case .failed(let error):
                _ = try? files.delete(at: final)
                return .failed(error)
            }
        }
        let effects = state.withLock { state -> Effects in
            for id in state.closes.keys where state.closes[id]!.keys.contains(key) {
                switch outcome {
                case .added: state.closes[id]!.committed.insert(key)
                case .failed(let error): if state.closes[id]!.failure == nil { state.closes[id]!.failure = error }
                // `remove` overtook it: no closing event is owed.
                case .overtaken: state.closes[id]!.abandoned = true
                }
            }
            // Dropped now if nobody waits; otherwise by the last waiter to leave.
            if state.jobs[key]?.waiters.isEmpty == true {
                state.jobs[key] = nil
            } else {
                state.jobs[key]?.outcome = outcome
            }
            var effects = Effects()
            state.settleCloses(&effects)
            return effects
        }
        perform(effects)
        return outcome
    }
}

private extension WebFontError {
    /// The server answered, but not with the file: a 4xx or 5xx.
    var isStatusFailure: Bool {
        switch self {
        case .notFound, .server: true
        default: false
        }
    }

    /// Not a passing failure: rate limits and server errors aren't remembered.
    var meansGone: Bool {
        switch self {
        case .notFound, .server(statusCode: 403), .server(statusCode: 410): true
        default: false
        }
    }
}
