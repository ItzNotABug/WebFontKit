import Foundation

/// Google's file ID for every family and style, bundled so a first load can skip the CSS2
/// lookup. Memory-mapped and never parsed up front; anything malformed reads as a miss.
///
/// Built by `scripts/catalog.sh`. Layout, little-endian:
/// - header: `WFKC`, format 1, a reserved byte, family count (u16), catalogue day (u32)
/// - index: one u32 record offset per family, records sorted by the family's UTF-8 bytes
/// - record: name length (u8), name, version (u16), group count (u8), then groups
/// - group: flags (u8: 1 italic, 2 computed), weights present (u16: bit n is weight n × 100), then
///   either a base weight ÷ 100 (u8), the weight float's offset (u8) and one ID, or one ID per
///   weight in ascending order; each ID is a length (u8) and its bytes.
struct GoogleFontsCatalog: Sendable {
    /// Mapped on first use. Nil once a year old: Google keeps serving old versions, so it would pin them.
    static let bundled: GoogleFontsCatalog? = shipped.flatMap { $0.isCurrent(at: .now) ? $0 : nil }

    /// The file in the package, whatever its age.
    static let shipped: GoogleFontsCatalog? = resourceBundle()?.url(forResource: "GoogleFonts", withExtension: "catalog")
        .flatMap { try? Data(contentsOf: $0, options: .alwaysMapped) }
        .flatMap(GoogleFontsCatalog.init(data:))

    /// Where SwiftPM and Xcode put the package's resources. Not `Bundle.module`: its accessor traps
    /// when the bundle is missing, and a missing catalogue should only mean CSS2 lookups.
    private static func resourceBundle() -> Bundle? {
        let name = "WebFontKit_WebFontKit.bundle"
        // Xcode previews name the bundle's folder in the environment.
        if let path = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"],
           let bundle = Bundle(url: URL(filePath: path).appending(component: name)) {
            return bundle
        }
        let library = Bundle(for: BundleToken.self)
        let places = [Bundle.main.resourceURL, Bundle.main.bundleURL, library.resourceURL, library.bundleURL,
                      library.bundleURL.deletingLastPathComponent()]
        return places.lazy.compactMap { $0.flatMap { Bundle(url: $0.appending(component: name)) } }.first
    }

    static let lifetime: TimeInterval = 365 * 24 * 60 * 60

    private let data: Data
    private let count: Int
    /// When `scripts/catalog.sh` built it.
    let built: Date

    init?(data: Data) {
        let header = data.withUnsafeBytes { bytes -> (count: Int, day: Int)? in
            var cursor = Cursor(bytes: bytes, at: 0)
            guard cursor.take(4).map({ Array($0) }) == Array("WFKC".utf8), cursor.u8() == 1, cursor.u8() != nil,
                  let count = cursor.u16(), let day = cursor.u32(), 12 + 4 * count <= bytes.count
            else { return nil }
            return (count, day)
        }
        guard let header else { return nil }
        self.data = data
        self.count = header.count
        built = Date(timeIntervalSince1970: TimeInterval(header.day) * 86_400)
    }

    func isCurrent(at date: Date) -> Bool {
        date.timeIntervalSince(built) < Self.lifetime
    }

    /// Each style's URL, or nil when any is missing: the caller then asks CSS2 for the whole call.
    func urls(family: String, styles: [FontStyle]) -> [FontStyle: URL]? {
        data.withUnsafeBytes { bytes in
            guard var cursor = record(named: family, in: bytes), let version = cursor.u16(), let groups = cursor.u8()
            else { return nil }
            var ids: [FontStyle: [UInt8]] = [:]
            for _ in 0..<groups {
                guard cursor.read(group: styles, into: &ids) else { return nil }
            }
            guard ids.count == styles.count else { return nil }
            // Google's folder: the name lowercased, spaces dropped (validated names hold nothing else).
            let folder = family.lowercased().filter { $0 != " " }
            var urls: [FontStyle: URL] = [:]
            for (style, id) in ids {
                let name = Data(id).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "="))
                guard let url = URL(string: "https://fonts.gstatic.com/s/\(folder)/v\(version)/\(name).ttf") else { return nil }
                urls[style] = url
            }
            return urls
        }
    }

    /// A cursor just past the family's name, found by binary search over the sorted index.
    private func record(named family: String, in bytes: UnsafeRawBufferPointer) -> Cursor? {
        let key = Array(family.utf8)
        var low = 0, high = count - 1
        while low <= high {
            let middle = (low + high) / 2
            var cursor = Cursor(bytes: bytes, at: 12 + 4 * middle)
            guard let offset = cursor.u32() else { return nil }
            cursor.at = offset
            guard let length = cursor.u8(), let name = cursor.take(length) else { return nil }
            if name.elementsEqual(key) { return cursor }
            if name.lexicographicallyPrecedes(key) { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }
}

private final class BundleToken {}

/// Bounds-checked little-endian reads; every one answers nil past the end.
private struct Cursor {
    let bytes: UnsafeRawBufferPointer
    var at: Int

    mutating func take(_ length: Int) -> Slice<UnsafeRawBufferPointer>? {
        guard length >= 0, at + length <= bytes.count else { return nil }
        defer { at += length }
        return bytes[at..<(at + length)]
    }

    mutating func u8() -> Int? { take(1).map { Int($0.first!) } }
    mutating func u16() -> Int? { take(2).map { Int($0.loadUnaligned(as: UInt16.self).littleEndian) } }
    mutating func u32() -> Int? { take(4).map { Int($0.loadUnaligned(as: UInt32.self).littleEndian) } }

    mutating func id() -> [UInt8]? {
        guard let length = u8(), let id = take(length) else { return nil }
        return Array(id)
    }

    /// Reads one group, keeping the IDs of the wanted styles it holds. False if malformed.
    mutating func read(group styles: [FontStyle], into ids: inout [FontStyle: [UInt8]]) -> Bool {
        guard let flags = u8(), let weights = u16() else { return false }
        let italic = flags & 1 != 0
        let wanted = styles.filter { $0.isItalic == italic && weights >> ($0.weight / 100) & 1 == 1 }
        if flags & 2 != 0 {
            // One ID; any other weight differs only in the little-endian Float32 of the weight.
            guard let base = u8(), let offset = u8(), let id = id(), offset + 4 <= id.count else { return false }
            for style in wanted {
                var computed = id
                let diff = Float(base * 100).bitPattern ^ Float(style.weight).bitPattern
                for byte in 0..<4 { computed[offset + byte] ^= UInt8(truncatingIfNeeded: diff >> (8 * byte)) }
                ids[style] = computed
            }
        } else {
            for weight in stride(from: 100, through: 1500, by: 100) where weights >> (weight / 100) & 1 == 1 {
                guard let id = id() else { return false }
                if let style = wanted.first(where: { $0.weight == weight }) { ids[style] = id }
            }
        }
        return true
    }
}
