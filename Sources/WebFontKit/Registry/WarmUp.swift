import Foundation

extension Registry {
    /// A face warm-up is about to add to the table.
    struct WarmFace: Sendable, Equatable {
        var key: FaceKey
        var entry: RegistryEntry
        var row: DownloadedFont?
        /// Counted in `.warmedUp`.
        var counted: Bool
    }

    /// One batched registration: one file per (family, style) and per PostScript name.
    @concurrent
    func warmUp(store: Store, cacheKey: @escaping @Sendable (FaceKey) -> String, now: Date = Date()) async -> Int {
        let recorded = state.withLock { ($0.globalEpoch, $0.familyEpochs) }

        do {
            for name in try store.sweepStalePartials(now: now) {
                log("warmup", .info, "Swept a stale partial", private: [name])
            }
        } catch {
            log("warmup", .error, "Could not sweep stale partials: \(error)")
        }

        let faces = readKeptFaces(store: store, cacheKey: cacheKey)
        let names = Array(Set(faces.map(\.postScriptName))).sorted()
        await nameTurns.take(all: names)

        var warmed: [WarmFace] = []
        var failedOpens: [URL] = []
        let (batch, sharers, answered) = planBatch(faces)
        for group in answered {
            warmed += await unregisteredFaces(group, store: store)
        }

        let failures = batch.isEmpty ? [:] : await registrar.register(urls: batch.map(\.url))
        for face in batch {
            let shared = sharers[face.postScriptName] ?? []
            switch failures[face.url] {
            case nil, CoreTextCode.alreadyRegistered?:
                let opened = await registrar.openRegisteredFace(postScriptName: face.postScriptName)
                // No silent-collision check here: it only logs, and the face's first commit already did.
                if opened.postScriptName == face.postScriptName, let url = opened.fileURL, sameFile(face.url)(url),
                   opened.glyphCount == face.glyphCount, let file = try? files.fileEntry(at: face.url) {
                    warmed.append(WarmFace(key: face.key, entry: face.entry(registeredHere: true),
                                           row: downloadedRow(for: face, file: file), counted: true))
                    warmed += shared.map { unregisteredFace($0) }
                } else if opened.postScriptName == face.postScriptName, let url = opened.fileURL, isAnotherInstancesFile(url, of: face) {
                    failedOpens.append(face.url)
                    warmed += ([face] + shared).map { unregisteredFace($0) }
                } else {
                    // Kept: a stored file passed validation, so this is CoreText lagging or another
                    // process's copy, and deleting it would lose a good font.
                    failedOpens.append(face.url)
                    log("warmup", .error, "\(face.key) did not open as \(face.postScriptName); skipped", private: [face.url.path(percentEncoded: false)])
                }
            case CoreTextCode.duplicatedName?:
                warmed += await unregisteredFaces([face] + shared, store: store, afterDuplicatedName: true)
            case let code?:
                log("warmup", .error, "\(face.key) failed to register (CoreText error \(code)); skipped and kept", private: [face.url.path(percentEncoded: false)])
            }
        }

        if !failedOpens.isEmpty {
            _ = await registrar.unregister(urls: failedOpens)
        }
        let count = await insertWarmedUp(warmed, recordedGlobal: recorded.0, recordedFamilies: recorded.1)
        nameTurns.release(all: names)
        log("warmup", .info, "Warm-up registered \(count) face\(count == 1 ? "" : "s")")
        return count
    }

    /// Keeps the newest file per (family, style), preferring the current key hash; deletes the rest.
    private func readKeptFaces(store: Store, cacheKey: @Sendable (FaceKey) -> String) -> [StoredFace] {
        let owned: [Store.OwnedFile]
        do {
            owned = try store.ownedFiles()
        } catch {
            log("warmup", .error, "Could not list the store: \(error)")
            return []
        }
        var byKey: [FaceKey: [(hash: String, entry: FileEntry)]] = [:]
        for file in owned {
            switch file {
            case .font(let parsed, let entry):
                guard case .font(let hash, _) = parsed.kind else { continue }
                byKey[FaceKey(family: parsed.family, style: parsed.style), default: []].append((hash, entry))
            case .unreadable(let entry):
                log("warmup", .info, "Skipped a stored file whose name does not parse", private: [entry.url.lastPathComponent])
            case .marker, .partial:
                continue
            }
        }

        var faces: [StoredFace] = []
        for (key, candidates) in byKey.sorted(by: { $0.key < $1.key }) {
            let current = StoredFileName.keyHash(family: key.family, style: key.style, cacheKey: cacheKey(key))
            let newestFirst = candidates.sorted {
                ($0.entry.modificationDate, $0.entry.url.lastPathComponent) > ($1.entry.modificationDate, $1.entry.url.lastPathComponent)
            }
            let kept = newestFirst.first { $0.hash == current } ?? newestFirst[0]
            for other in newestFirst where other.entry.url != kept.entry.url {
                _ = try? files.delete(at: other.entry.url)
                log("warmup", .info, "Deleted an older file of \(key)", private: [other.entry.url.lastPathComponent])
            }
            guard let info = registrar.faceInfo(at: kept.entry.url) else {
                log("warmup", .error, "CoreText cannot read the stored \(key); skipped and kept", private: [kept.entry.url.lastPathComponent])
                continue
            }
            faces.append(StoredFace(key: key, url: kept.entry.url, keyHash: kept.hash, info: info, file: kept.entry))
        }
        return faces
    }

    private func planBatch(_ faces: [StoredFace]) -> (batch: [StoredFace], sharers: [String: [StoredFace]], answered: [[StoredFace]]) {
        let table = state.withLock { $0.table }
        let namesInTable = Set(table.values.map(\.postScriptName))
        var batch: [StoredFace] = []
        var sharers: [String: [StoredFace]] = [:]
        var answered: [[StoredFace]] = []
        let groups = Dictionary(grouping: faces.filter { table[$0.key] == nil }, by: \.postScriptName)
        for name in groups.keys.sorted() {
            let group = groups[name]!.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
            if namesInTable.contains(name) {
                answered.append(group)
                continue
            }
            #if os(macOS)
            if let active = registrar.activeFace(postScriptName: name), let url = active.fileURL,
               isAnotherInstancesFile(url, of: group[0]) {
                answered.append(group)
                continue
            }
            #endif
            batch.append(group[0])
            sharers[name] = Array(group.dropFirst())
        }
        return (batch, sharers, answered)
    }

    private func unregisteredFace(_ face: StoredFace) -> WarmFace {
        WarmFace(key: face.key, entry: face.entry(registeredHere: false),
                 row: downloadedRow(for: face), counted: false)
    }

    /// A system font answering the name turns each face into a marker; anything else leaves an unregistered entry.
    private func unregisteredFaces(_ faces: [StoredFace], store: Store, afterDuplicatedName: Bool = false) async -> [WarmFace] {
        guard let first = faces.first else { return [] }
        let tableEntry = state.withLock { $0.entries(named: first.postScriptName).first?.entry }
        var system = tableEntry?.kind == .system
        if afterDuplicatedName, tableEntry == nil {
            let active = registrar.activeFace(postScriptName: first.postScriptName)
            system = active.map { $0.fileURL?.pathExtension != StoredFileName.fontExtension } ?? false
            if !system {
                log("warmup", .info, "Another WebFontKit file already serves \(first.postScriptName); kept unregistered here")
            }
        }
        guard system else { return faces.map(unregisteredFace) }
        var warmed: [WarmFace] = []
        for face in faces {
            do {
                try store.writeMarker(family: face.key.family, style: face.key.style, postScriptName: face.postScriptName)
                _ = try files.delete(at: face.url)
            } catch {
                log("warmup", .error, "Could not replace the stored \(face.key) with its system-collision marker")
            }
            log("warmup", .info, "\(face.key) is also a system font with the same PostScript name: drawing the system's \(face.postScriptName)")
            warmed.append(WarmFace(key: face.key, entry: RegistryEntry(postScriptName: face.postScriptName, kind: .system), row: nil, counted: false))
        }
        return warmed
    }

    /// Skips everything after a `removeAll`, and faces whose family was removed or gained an entry meanwhile.
    func insertWarmedUp(_ faces: [WarmFace], recordedGlobal: Int, recordedFamilies: [String: Int]) async -> Int {
        let (added, skipped) = state.withLock { state -> ([WarmFace], [WarmFace]) in
            guard state.globalEpoch == recordedGlobal else { return ([], faces) }
            var added: [WarmFace] = []
            var skipped: [WarmFace] = []
            for face in faces {
                let family = face.key.family
                if (state.familyEpochs[family] ?? 0) != (recordedFamilies[family] ?? 0) || state.table[face.key] != nil {
                    skipped.append(face)
                    continue
                }
                state.table[face.key] = face.entry
                state.downloaded[face.key] = face.row
                added.append(face)
            }
            return (added, skipped)
        }
        let unregister = skipped.filter(\.entry.registeredHere).compactMap(\.entry.fileURL)
        if !unregister.isEmpty {
            _ = await registrar.unregister(urls: unregister)
        }
        if !added.isEmpty {
            await bumpGenerations(of: Set(added.map(\.key.family)))
        }
        return added.filter(\.counted).count
    }
}
