import Foundation
import Observation
import OSLog

/// A requested face: the family as the caller wrote it, and a style.
struct FaceKey: Hashable, Sendable, Comparable {
    var family: String
    var style: FontStyle

    static func < (lhs: FaceKey, rhs: FaceKey) -> Bool {
        if lhs.family != rhs.family { return lhs.family < rhs.family }
        return FontStyle.canonicalOrder(lhs.style, rhs.style)
    }

    var regular: FaceKey { FaceKey(family: family, style: .regular) }
}

extension FaceKey: CustomStringConvertible {
    /// "Lobster 400", "Inter 700 italic": how logs name a face.
    var description: String { "\(family) \(style.logDescription)" }
}

extension FontStyle {
    var logDescription: String { "\(weight)\(isItalic ? " italic" : "")" }
}

/// What the table maps a requested face to.
struct RegistryEntry: Sendable, Equatable {
    /// A downloaded file, or a system font that answers the name instead.
    enum Kind: Sendable, Equatable {
        /// `registeredHere` is false when another file with the same PostScript name answers for it.
        case file(url: URL, keyHash: String, registeredHere: Bool)
        case system
    }

    var postScriptName: String
    var kind: Kind

    var fileURL: URL? {
        if case .file(let url, _, _) = kind { return url }
        return nil
    }

    var keyHash: String? {
        if case .file(_, let hash, _) = kind { return hash }
        return nil
    }

    var registeredHere: Bool {
        if case .file(_, _, true) = kind { return true }
        return false
    }
}

/// Removal epochs recorded when a call starts; a change means `remove` overtook it.
struct Epochs: Sendable, Hashable {
    var global: Int
    var family: Int
}

/// Separate from the locked table because an `@Observable` class can't be `Sendable`.
@MainActor
@Observable
final class RegistryGeneration {
    private(set) var value = 0

    nonisolated init() {}

    func bump() {
        value += 1
    }
}

/// The table the first-frame check reads, with `downloaded` and the removal epochs.
struct RegistryState: Sendable {
    var table: [FaceKey: RegistryEntry] = [:]
    var aliases: Set<FaceKey> = []
    var downloaded: [FaceKey: DownloadedFont] = [:]
    var globalEpoch = 0
    var familyEpochs: [String: Int] = [:]

    func epochs(for family: String) -> Epochs {
        Epochs(global: globalEpoch, family: familyEpochs[family] ?? 0)
    }

    /// Takes every file entry named `postScriptName` out of the table, for `reregister` to put back.
    mutating func takeSharers(named postScriptName: String) -> [Sharer] {
        var sharers: [Sharer] = []
        for (key, entry) in entries(named: postScriptName) where entry.fileURL != nil {
            sharers.append(Sharer(key: key, entry: entry, row: downloaded[key], epochs: epochs(for: key.family)))
            table[key] = nil
            downloaded[key] = nil
        }
        return sharers
    }

    func entries(named postScriptName: String) -> [(key: FaceKey, entry: RegistryEntry)] {
        table.filter { $0.value.postScriptName == postScriptName }
            .map { ($0.key, $0.value) }
            .sorted { $0.key < $1.key }
    }

}

func sameFile(_ lhs: URL) -> (URL) -> Bool {
    let path = lhs.resolvingSymlinksInPath().path(percentEncoded: false)
    return { $0.resolvingSymlinksInPath().path(percentEncoded: false) == path }
}

/// A stored file, read but not yet in the table.
struct StoredFace: Sendable, Equatable {
    var key: FaceKey
    var url: URL
    var keyHash: String
    var postScriptName: String
    var glyphCount: Int
    var familyName: String
    /// Its size and date, when a directory listing already read them.
    var file: FileEntry?

    init(key: FaceKey, url: URL, keyHash: String, postScriptName: String, glyphCount: Int, familyName: String, file: FileEntry? = nil) {
        self.key = key
        self.url = url
        self.keyHash = keyHash
        self.postScriptName = postScriptName
        self.glyphCount = glyphCount
        self.familyName = familyName
        self.file = file
    }

    init(key: FaceKey, url: URL, keyHash: String, info: FaceInfo, file: FileEntry? = nil) {
        self.init(key: key, url: url, keyHash: keyHash, postScriptName: info.postScriptName,
                  glyphCount: info.glyphCount, familyName: info.familyName, file: file)
    }

    func entry(registeredHere: Bool) -> RegistryEntry {
        RegistryEntry(postScriptName: postScriptName, kind: .file(url: url, keyHash: keyHash, registeredHere: registeredHere))
    }
}

/// An entry taken out with the face registered under its PostScript name, to be put back after.
struct Sharer: Sendable {
    var key: FaceKey
    var entry: RegistryEntry
    var row: DownloadedFont?
    var epochs: Epochs
}

/// CoreText registrations, the table the first-frame check reads, `downloaded`, and the removal epochs.
final class Registry: Sendable {
    let registrar: any FontRegistrar
    let files: any FileOperations
    let logSink: any LogSink
    let generation = RegistryGeneration()
    let state = Locked(RegistryState())
    let faceTurns = Turns<FaceKey>()
    let nameTurns = Turns<String>()

    init(registrar: any FontRegistrar, files: any FileOperations, logSink: any LogSink) {
        self.registrar = registrar
        self.files = files
        self.logSink = logSink
    }

    // MARK: Reading

    /// The first-frame check. Never waits.
    func postScriptName(for key: FaceKey) -> String? {
        state.withLock { state in
            if let entry = state.table[key] { return entry.postScriptName }
            if state.aliases.contains(key), let regular = state.table[key.regular] { return regular.postScriptName }
            return nil
        }
    }

    func entry(for key: FaceKey) -> RegistryEntry? {
        state.withLock { $0.table[key] }
    }

    /// Copied under the lock, sorted after it.
    var downloaded: [DownloadedFont] {
        let rows = state.withLock { Array($0.downloaded) }
        return rows.sorted { $0.key < $1.key }.map(\.value)
    }

    /// The families removing `family` (or every family, for nil) would take out of the table.
    func families(matching family: String?) -> Set<String> {
        state.withLock { state in
            let keys = Set(state.table.keys).union(state.aliases).union(state.downloaded.keys)
            return Set(keys.map(\.family).filter { family == nil || $0 == family })
        }
    }

    func epochs(for family: String) -> Epochs {
        state.withLock { $0.epochs(for: family) }
    }

    // MARK: Logging and the generation

    func log(_ category: String, _ level: OSLogType, _ message: String, private values: [String] = []) {
        logSink.log(category, level, message, private: values)
    }

    func bumpGeneration() async {
        await MainActor.run { generation.bump() }
    }

    // MARK: Inserting

    /// Nil when the file is gone.
    func downloadedRow(for face: StoredFace) -> DownloadedFont? {
        (face.file ?? (try? files.fileEntry(at: face.url))).map { downloadedRow(for: face, file: $0) }
    }

    func downloadedRow(for face: StoredFace, file: FileEntry) -> DownloadedFont {
        DownloadedFont(
            family: face.key.family, style: face.key.style, postScriptName: face.postScriptName,
            byteCount: file.byteCount, downloadedAt: file.modificationDate
        )
    }

    /// Returns false, adding nothing, when the call's epochs changed.
    func insert(_ entry: RegistryEntry, for key: FaceKey, row: DownloadedFont?, epochs: Epochs?) async -> Bool {
        let added = state.withLock { state -> Bool in
            if let epochs, state.epochs(for: key.family) != epochs { return false }
            state.table[key] = entry
            state.downloaded[key] = row
            return true
        }
        if added {
            await bumpGeneration()
        }
        return added
    }

    func insertSystemEntry(for key: FaceKey, postScriptName: String, epochs: Epochs) async -> Bool {
        await insert(RegistryEntry(postScriptName: postScriptName, kind: .system), for: key, row: nil, epochs: epochs)
    }

    /// Adds the alias only while the regular entry is in the table and the epochs are unchanged.
    func insertAlias(for key: FaceKey, epochs: Epochs) async -> Bool {
        let added = state.withLock { state -> Bool in
            guard state.epochs(for: key.family) == epochs, state.table[key.regular] != nil else { return false }
            state.aliases.insert(key)
            return true
        }
        if added {
            await bumpGeneration()
        }
        return added
    }
}
