import Foundation

extension Registry {
    /// Why a system-collision marker no longer holds.
    enum StaleMarkerReason: String, Sendable, Equatable {
        case attributeMissing = "attribute missing"
        case nameDoesNotResolve = "name does not resolve"
        case nameResolvesToStoredFont = "name resolves to a .wfkfont"
    }

    /// A marker still naming a system font, or a stale one to delete.
    enum MarkerVerdict: Sendable, Equatable {
        case valid(postScriptName: String)
        case stale(StaleMarkerReason)
    }

    func checkMarker(at url: URL, store: Store) -> MarkerVerdict {
        let verdict: MarkerVerdict
        if let name = store.markerName(at: url) {
            if let active = registrar.activeFace(postScriptName: name) {
                verdict = active.fileURL?.pathExtension == StoredFileName.fontExtension
                    ? .stale(.nameResolvesToStoredFont) : .valid(postScriptName: name)
            } else {
                verdict = .stale(.nameDoesNotResolve)
            }
        } else {
            verdict = .stale(.attributeMissing)
        }
        if case .stale(let reason) = verdict {
            _ = try? files.delete(at: url)
            log("store", .info, "Deleted a stale system-collision marker \(url.lastPathComponent): \(reason.rawValue)")
        }
        return verdict
    }

    /// Removes `family`, or every family for nil. Throws `.storage` only after doing everything else.
    @concurrent
    func remove(family: String?, directories: [URL]) async throws -> [String] {
        let matches: @Sendable (String) -> Bool = { family == nil || $0 == family }
        let (removed, sharers, families) = state.withLock { state -> ([RegistryEntry], [Sharer], Set<String>) in
            if let family {
                state.familyEpochs[family, default: 0] += 1
            } else {
                state.globalEpoch += 1
            }
            let keys = state.table.keys.filter { matches($0.family) }
            var families = Set(keys.map(\.family))
            families.formUnion(state.aliases.filter { matches($0.family) }.map(\.family))
            families.formUnion(state.downloaded.keys.filter { matches($0.family) }.map(\.family))
            let removed = keys.compactMap { state.table.removeValue(forKey: $0) }
            state.aliases = state.aliases.filter { !matches($0.family) }
            state.downloaded = state.downloaded.filter { !matches($0.key.family) }

            let sharers = Set(removed.filter(\.registeredHere).map(\.postScriptName)).flatMap { state.takeSharers(named: $0) }
            return (removed, sharers, families)
        }
        // Sharers can be other families' entries ("lobster" beside "Lobster"): they redraw too.
        let changed = families.union(sharers.map(\.key.family))
        if !changed.isEmpty {
            await bumpGenerations(of: changed)
        }

        var failed = false
        let registered = removed.filter(\.registeredHere).compactMap(\.fileURL)
        if !registered.isEmpty {
            let failures = await registrar.unregister(urls: registered)
            if failures.values.contains(where: { $0 != CoreTextCode.notRegistered }) {
                failed = true
                log("registry", .error, "Unregistering \(family ?? "every family") failed: \(failures.values.sorted())")
            }
        }

        var deletedFamilies = Set<String>()
        var searched = Set(directories.map { $0.standardizedFileURL })
        searched.formUnion(removed.compactMap { $0.fileURL?.deletingLastPathComponent().standardizedFileURL })
        for directory in searched.sorted(by: { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }) {
            let store = Store(directory: directory, files: files)
            do {
                for owned in try store.ownedFiles() {
                    switch owned {
                    case .font(let parsed, let entry), .marker(let parsed, let entry):
                        guard matches(parsed.family) else { continue }
                        if try files.delete(at: entry.url) {
                            deletedFamilies.insert(parsed.family)
                        }
                    case .partial, .unreadable:
                        continue
                    }
                }
            } catch {
                failed = true
                log("store", .error, "Deleting the files of \(family ?? "every family") failed: \(error)")
            }
        }

        await reregister(sharers)
        if failed {
            throw WebFontError.storage
        }
        return families.union(deletedFamilies).sorted()
    }

    /// Registers the first-sorting sharer in place of a removed face, then puts every sharer back.
    func reregister(_ sharers: [Sharer]) async {
        let byName = Dictionary(grouping: sharers, by: \.entry.postScriptName)
        for name in byName.keys.sorted() {
            let group = byName[name]!.sorted { ($0.entry.fileURL?.lastPathComponent ?? "") < ($1.entry.fileURL?.lastPathComponent ?? "") }
            guard let first = group.first, let url = first.entry.fileURL, let hash = first.entry.keyHash,
                  let info = registrar.faceInfo(at: url)
            else {
                log("registry", .error, "Could not read the file to register \(name) again; its entries stay out")
                continue
            }
            let chosen = StoredFace(key: first.key, url: url, keyHash: hash, info: info)
            let store = Store(directory: url.deletingLastPathComponent(), files: files)
            guard case .added = await register(chosen, epochs: first.epochs, store: store) else {
                log("registry", .error, "Registering \(name) again from \(first.key.family) failed; its entries stay out until a later load")
                continue
            }
            for other in group.dropFirst() {
                var entry = other.entry
                if let url = entry.fileURL, let hash = entry.keyHash {
                    entry.kind = .file(url: url, keyHash: hash, registeredHere: false)
                }
                _ = await insert(entry, for: other.key, row: other.row, epochs: other.epochs)
            }
        }
    }

    /// Takes the old face of `key` out before its replacement registers, with any entries
    /// sharing its name; returns them for `reregister` afterwards.
    func replace(_ key: FaceKey) async -> [Sharer] {
        let (old, sharers) = state.withLock { state -> (RegistryEntry?, [Sharer]) in
            guard let old = state.table.removeValue(forKey: key) else { return (nil, []) }
            state.downloaded[key] = nil
            return (old, old.registeredHere ? state.takeSharers(named: old.postScriptName) : [])
        }
        guard let old else { return [] }
        await bumpGenerations(of: Set(sharers.map(\.key.family)).union([key.family]))
        if old.registeredHere, let url = old.fileURL {
            _ = await registrar.unregister(urls: [url])
        }
        if let url = old.fileURL {
            _ = try? files.delete(at: url)
        }
        log("registry", .info, "Replacing \(key): the cache key changed")
        return sharers
    }
}
