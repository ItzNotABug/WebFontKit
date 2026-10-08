import Foundation

/// Before any fetch: is the name usable, is the face already here, or did another process store it?
extension WebFonts {
    /// Whether the source in force would accept the name at all.
    func acceptsFamilyName(_ family: String) -> Bool {
        Self.isValidFamilyName(family, defaultSource: state.withLock { $0.current.usesDefaultSource })
    }

    /// Empty is invalid for every source; the default source also takes only ASCII
    /// letters, digits and single inner spaces, which every Google family fits.
    static func isValidFamilyName(_ family: String, defaultSource: Bool) -> Bool {
        guard !family.isEmpty else { return false }
        guard defaultSource else { return true }
        guard family.first != " ", family.last != " ", !family.contains("  ") else { return false }
        return family.unicodeScalars.allSatisfy { scalar in
            scalar == " " || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
    }

    /// Styles with no entry, or whose entry was stored under another cache key.
    /// A system-collision entry is never compared.
    func missing(_ styles: [FontStyle], family: String, snapshot: Snapshot) -> [FontStyle] {
        styles.filter { style in
            let key = FaceKey(family: family, style: style)
            guard let entry = registry.entry(for: key) else { return true }
            if entry.kind == .system { return false }
            return entry.keyHash != snapshot.keyHash(key)
        }
    }

    /// Another process may have stored a face, or left a system-collision marker.
    /// Returns the styles still missing.
    func lookUpStore(_ family: String, styles: [FontStyle], snapshot: Snapshot, epochs: Epochs) async throws -> [FontStyle] {
        let store = Store(directory: snapshot.directory, files: files)
        let owned = (try? store.ownedFiles(family: family)) ?? []
        var remaining: [FontStyle] = []
        for style in styles {
            let key = FaceKey(family: family, style: style)
            let hash = snapshot.keyHash(key)
            // Waits for a running commit only when a file of this face exists; otherwise a load
            // after `remove` would queue behind the commit that `remove` overtook.
            let candidate = owned.contains { file in
                switch file {
                case .font(let parsed, _), .marker(let parsed, _): parsed.family == family && parsed.style == style
                default: false
                }
            }
            guard candidate else {
                remaining.append(style)
                continue
            }
            let found = try await registry.faceTurns.with(key) { () async throws -> Bool in
                guard !missing([style], family: family, snapshot: snapshot).isEmpty else { return true }
                let fonts = owned.compactMap { file -> FileEntry? in
                    guard case .font(let parsed, let entry) = file, parsed.family == family, parsed.style == style,
                          case .font(hash, _) = parsed.kind else { return nil }
                    return entry
                }.sorted { $0.modificationDate > $1.modificationDate }
                if let file = fonts.first, files.fileExists(at: file.url), let info = registry.registrar.faceInfo(at: file.url) {
                    // Another process may have stored it under a newer cache key than our entry's.
                    let face = StoredFace(key: key, url: file.url, keyHash: hash, info: info, file: file)
                    switch await registry.registerReplacingStale(face, epochs: epochs, store: store) {
                    case .added: return true
                    case .overtaken: throw CancellationError()
                    case .failed(let error): log("store", .error, "A stored \(family) file could not be registered (\(error)); fetching it again")
                    }
                }
                let marker = store.url(for: StoredFileName.marker(family: family, style: style))
                if owned.contains(where: { $0.entry.url.lastPathComponent == marker.lastPathComponent }),
                   case .valid(let name) = registry.checkMarker(at: marker, store: store) {
                    guard await registry.insertSystemEntry(for: key, postScriptName: name, epochs: epochs) else {
                        throw CancellationError()
                    }
                    return true
                }
                return false
            }
            if !found {
                remaining.append(style)
            }
        }
        return remaining
    }
}
