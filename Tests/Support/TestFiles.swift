import Foundation

/// A seeded generator for the fuzz tests; the standard library has none.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    /// The seed from `WEBFONTKIT_SEED` when set, otherwise `fallback`. Prints it
    /// before the caller's first iteration, because a crash leaves no chance to
    /// print afterwards.
    public static func seed(default fallback: UInt64, label: String) -> UInt64 {
        let seed = ProcessInfo.processInfo.environment["WEBFONTKIT_SEED"].flatMap(UInt64.init) ?? fallback
        print("\(label): seed \(seed) (replay with WEBFONTKIT_SEED=\(seed))")
        return seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A fresh directory for one test, deleted when the owner is deallocated. All
/// of a run's directories sit under `runRoot`, which the integration suite's
/// end-of-run check scans.
public final class TempDirectory: Sendable {
    public static let runRoot: URL = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebFontKitTestRun-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The spelling directory listings use (`/private/var/…`); resolvingSymlinksInPath strips `/private`.
        guard let real = realpath(root.path, nil) else { return root }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }()

    public let url: URL

    public init() {
        url = Self.runRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// The `WebFontKit/` subdirectory the library keeps its files in.
    public var store: URL {
        url.appendingPathComponent("WebFontKit", isDirectory: true)
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
        root.appendingPathComponent(path)
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
        }.sorted().last!
        return try! Data(contentsOf: directory.appendingPathComponent(newest))
    }

    public static func css2Text(_ name: String) -> String {
        String(decoding: css2(name), as: UTF8.self)
    }
}
