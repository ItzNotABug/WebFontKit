import CoreText
import Foundation

/// CoreText error codes the registry tells apart.
enum CoreTextCode {
    static let alreadyRegistered = CTFontManagerError.alreadyRegistered.rawValue
    static let notRegistered = CTFontManagerError.notRegistered.rawValue
    static let duplicatedName = CTFontManagerError.duplicatedName.rawValue
}

extension Registry {
    enum RegistrationResult: Sendable, Equatable {
        case added(RegistryEntry)
        case overtaken
        case failed(WebFontError)
    }

    /// An entry stored under an older cache key goes first; otherwise registering finds its
    /// name and adds nothing. Its sharers are put back after.
    func registerReplacingStale(_ face: StoredFace, epochs: Epochs, store: Store) async -> RegistrationResult {
        var sharers: [Sharer] = []
        if let old = entry(for: face.key), old.kind != .system, old.keyHash != face.keyHash {
            sharers = await replace(face.key)
        }
        let result = await register(face, epochs: epochs, store: store)
        await reregister(sharers)
        return result
    }

    /// Holds the name's turn so the registry check and the registration act as one step.
    func register(_ face: StoredFace, epochs: Epochs?, store: Store) async -> RegistrationResult {
        let name = face.postScriptName
        await nameTurns.take(name)
        defer { nameTurns.release(name) }
        let row = downloadedRow(for: face, postScriptName: name)

        let existing = state.withLock { $0.entries(named: name) }
        if let same = existing.first(where: { $0.key == face.key }) {
            return .added(same.entry)
        }
        if let other = existing.first {
            if other.entry.kind == .system {
                return await recordSystemCollision(face, epochs: epochs, store: store)
            }
            log("registry", .info, "\(face.key) shares the PostScript name \(name) with \(other.key); not registered again")
            return await insertUnregistered(face, row: row, epochs: epochs)
        }

        #if os(macOS)
        if let active = registrar.activeFace(postScriptName: name), let url = active.fileURL,
           isAnotherInstancesFile(url, of: face) {
            log("registry", .info, "\(name) for \(face.key.family) is already served by another WebFontKit file; not registered here")
            return await insertUnregistered(face, row: row, epochs: epochs)
        }
        #endif

        let failures = await registrar.register(urls: [face.url])
        switch failures[face.url] {
        case nil, CoreTextCode.alreadyRegistered?:
            if failures[face.url] != nil {
                log("registry", .debug, "\(face.key) was already registered from this file (105)")
            }
            return await openAndInsert(face, row: row, epochs: epochs)
        case CoreTextCode.duplicatedName?:
            return await resolveDuplicatedName(face, row: row, epochs: epochs, store: store)
        case let code?:
            log("registry", .error, "Registering \(face.key) failed with CoreText error \(code)", private: [face.url.path])
            return await failure(face, epochs: epochs, registered: false)
        }
    }

    /// The font must carry the name, come from this file, and match its glyph count.
    private func openAndInsert(_ face: StoredFace, row: DownloadedFont?, epochs: Epochs?) async -> RegistrationResult {
        let opened = await registrar.openRegisteredFace(postScriptName: face.postScriptName)
        if opened.postScriptName == face.postScriptName, let url = opened.fileURL, sameFile(face.url)(url),
           opened.glyphCount == face.glyphCount, files.fileExists(at: face.url) {
            checkSilentCollision(face)
            let entry = face.entry(registeredHere: true)
            if await insert(entry, for: face.key, row: row, epochs: epochs) {
                log("registry", .info, "Registered \(face.key) as \(face.postScriptName)")
                return .added(entry)
            }
            _ = await registrar.unregister(urls: [face.url])
            return .overtaken
        }
        #if os(macOS)
        if opened.postScriptName == face.postScriptName, let url = opened.fileURL, isAnotherInstancesFile(url, of: face) {
            _ = await registrar.unregister(urls: [face.url])
            log("registry", .info, "\(face.postScriptName) for \(face.key.family) answers from another WebFontKit file; kept unregistered here")
            return await insertUnregistered(face, row: row, epochs: epochs)
        }
        #endif
        log("registry", .error, "\(face.key) did not open as \(face.postScriptName) from its file (got \(opened.postScriptName), \(opened.glyphCount) glyphs)", private: [face.url.path])
        return await failure(face, epochs: epochs, registered: true)
    }

    /// Not ours: another instance's `.wfkfont`, or else a system font.
    private func resolveDuplicatedName(_ face: StoredFace, row: DownloadedFont?, epochs: Epochs?, store: Store) async -> RegistrationResult {
        guard let active = registrar.activeFace(postScriptName: face.postScriptName) else {
            log("registry", .error, "305 for \(face.key), but \(face.postScriptName) does not resolve")
            return await failure(face, epochs: epochs, registered: false)
        }
        if let url = active.fileURL, url.pathExtension == StoredFileName.fontExtension {
            log("registry", .info, "305 for \(face.key): \(face.postScriptName) is served by another WebFontKit file; kept unregistered here", private: [url.path])
            return await insertUnregistered(face, row: row, epochs: epochs)
        }
        return await recordSystemCollision(face, epochs: epochs, store: store)
    }

    /// The marker is written before the insert and deleted if overtaken, so a concurrent `remove` leaves none.
    func recordSystemCollision(_ face: StoredFace, epochs: Epochs?, store: Store) async -> RegistrationResult {
        var markerWritten = false
        do {
            try store.writeMarker(family: face.key.family, style: face.key.style, postScriptName: face.postScriptName)
            markerWritten = true
        } catch {
            log("store", .error, "Could not write the system-collision marker for \(face.key)")
        }
        let entry = RegistryEntry(postScriptName: face.postScriptName, kind: .system)
        guard await insert(entry, for: face.key, row: nil, epochs: epochs) else {
            if markerWritten {
                _ = try? files.delete(at: store.url(for: StoredFileName.marker(family: face.key.family, style: face.key.style)))
            }
            return .overtaken
        }
        _ = try? files.delete(at: face.url)
        log("registry", .info, "\(face.key) is also a system font (305 mode): drawing the system's \(face.postScriptName)")
        return .added(entry)
    }

    private func insertUnregistered(_ face: StoredFace, row: DownloadedFont?, epochs: Epochs?) async -> RegistrationResult {
        let entry = face.entry(registeredHere: false)
        return await insert(entry, for: face.key, row: row, epochs: epochs) ? .added(entry) : .overtaken
    }

    private func failure(_ face: StoredFace, epochs: Epochs?, registered: Bool) async -> RegistrationResult {
        if registered {
            _ = await registrar.unregister(urls: [face.url])
        }
        if let epochs, self.epochs(for: face.key.family) != epochs {
            return .overtaken
        }
        return .failed(files.fileExists(at: face.url) ? .invalidFont : .storage)
    }

    func isAnotherInstancesFile(_ url: URL, of face: StoredFace) -> Bool {
        guard url.pathExtension == StoredFileName.fontExtension, !sameFile(face.url)(url) else { return false }
        // Copied out first: comparing resolves symlinks, a syscall, which never runs under the lock.
        let named = state.withLock { $0.table.values.compactMap(\.fileURL) }
        return !named.contains(where: sameFile(url))
    }

    /// Silent mode (iOS): registered, but the family name still resolves to Apple's copy. Only logged.
    func checkSilentCollision(_ face: StoredFace) {
        #if os(iOS)
        let resolved = registrar.faceForFamily(face.familyName)
        guard resolved.familyName == face.familyName, let url = resolved.fileURL,
              !sameFile(face.url)(url), url.pathExtension != StoredFileName.fontExtension
        else { return }
        log("registry", .info, "\(face.key) is also a system font (silent mode): \(face.postScriptName) draws the downloaded face, the family name \(face.familyName) draws the system's")
        #endif
    }
}
