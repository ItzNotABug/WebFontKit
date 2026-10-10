#if DEBUG
import Foundation
@testable import WebFontKit

/// A fresh directory for one test, deleted when the owner is deallocated. All
/// of a run's directories sit under `runRoot`, which the integration suite's
/// end-of-run check scans.
public final class TempDirectory: Sendable {
    public static let runRoot: URL = {
        let root = URL.temporaryDirectory
            .appending(component: "WebFontKitTestRun-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The spelling directory listings use (`/private/var/…`); resolvingSymlinksInPath strips `/private`.
        guard let real = realpath(root.path, nil) else { return root }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }()

    public let url: URL

    public init() {
        url = Self.runRoot.appending(component: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// The `WebFontKit/` subdirectory the library keeps its files in.
    public var store: URL {
        url.appending(component: "WebFontKit", directoryHint: .isDirectory)
    }

    /// The names of the files directly inside `directory` (default: `store`), sorted.
    public func fileNames(in directory: URL? = nil) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: (directory ?? store).path)) ?? []
        return names.sorted()
    }
}

/// The files in `Tests/Fixtures`.
public enum Fixtures {
    public static let root: URL = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    public static func url(_ path: String) -> URL {
        root.appending(path: path)
    }

    public static func data(_ path: String) -> Data {
        try! Data(contentsOf: url(path))
    }

    public static let latoRegular = "Fonts/Lato-Regular.ttf"
    public static let latoBold = "Fonts/Lato-Bold.ttf"
    public static let latoItalic = "Fonts/Lato-Italic.ttf"
    public static let latoBoldItalic = "Fonts/Lato-BoldItalic.ttf"
    /// gstatic's Lobster v32, the face the default source gets for "Lobster".
    public static let lobster = "Fonts/Lobster-Regular.ttf"
    public static let lobsterV20 = "Fonts/Versions/Lobster-Regular-v20.ttf"
    /// A face iOS 26.5 also ships under the same PostScript name (305).
    public static let notoSansKannada = "Fonts/NotoSansKannada-Regular.ttf"
    /// A face whose family name iOS 26.5 keeps resolving to its own copy.
    public static let bebasNeue = "Fonts/BebasNeue-Regular.ttf"
    public static let lobsterWoff = "Woff/Lobster-Regular.woff"
    public static let lobsterWoff2 = "Woff/Lobster-Regular-latin.woff2"
    public static let corrupt = [
        "Corrupt/Empty.ttf", "Corrupt/Truncated.ttf", "Corrupt/NotFound.ttf", "Corrupt/Truncated.woff2",
    ]
}

extension Fixtures {
    /// The newest capture of a CSS2 response (`css2/<name>-<date>.css` or `.html`).
    public static func css2(_ name: String) -> Data {
        let directory = url("css2")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let newest = names.filter { file in
            guard file.hasPrefix(name + "-") else { return false }
            return file.dropFirst(name.count + 1).first?.isNumber == true
        }.max()!
        return try! Data(contentsOf: directory.appending(component: newest))
    }

    public static func css2Text(_ name: String) -> String {
        String(decoding: css2(name), as: UTF8.self)
    }

    /// Writes a fixture into `directory` under the name a load would give it.
    @discardableResult
    public static func storeFont(
        _ fixture: String, family: String, style: FontStyle = .regular, in directory: URL,
        cacheKey: String? = nil, version: String? = nil, modified: Date? = nil
    ) throws -> StoredFace {
        let key = cacheKey ?? DefaultKeySource().cacheKey(for: FontRequest(family: family, style: style))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(component: StoredFileName.font(family: family, style: style, cacheKey: key, version: version))
        try data(fixture).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        guard let info = CoreTextFonts.descriptorInfo(at: url) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return StoredFace(
            key: FaceKey(family: family, style: style), url: url,
            keyHash: StoredFileName.keyHash(family: family, style: style, cacheKey: key),
            postScriptName: info.postScriptName, glyphCount: info.glyphCount, familyName: info.familyName
        )
    }
}

/// Any source that keeps the protocol's default cache key.
private struct DefaultKeySource: FontSource {
    func fetch(_ font: FontRequest) async throws -> Data { Data() }
}
#endif
