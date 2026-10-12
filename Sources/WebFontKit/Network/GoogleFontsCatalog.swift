import Foundation

/// Google's file ID for every family and style, bundled so a first load can skip the CSS2
/// lookup. Memory-mapped and read in place; anything malformed reads as a miss.
///
/// A file ID is Google's description of the file, XOR a mask picked by its first byte (the seed):
/// `00 <length - 5> 00 <name length> <name> [10 02] [18 <weight>] [3a 0b 08 <axis tag> 15 <float32>]… 20 00`,
/// with `10 02` for italic, `18` and a varint for a static weight other than 400, and one block per
/// variable axis. The catalogue keeps each family's seed and the fields that differ, plus one mask
/// row per seed, and the reader rebuilds the description and XORs.
///
/// Built by `scripts/catalog.sh`. Layout:
/// - header: `WFKC`, format 2, hash bits, block size, Rice parameter, catalogue day (u32),
///   hash seed (u16), family count (u16), then ten u32 section offsets, all little-endian
/// - layouts, weight sets, versions, axis tags (tag, flags, usual value, first other value), other values
/// - nine canonical Huffman codes: counts per length 1–8, then symbols in code order
/// - mask row offsets (u16 × 257), mask rows
/// - block index: per 16 families, the first name hash and the block's bit offset (3 bytes each)
/// - records, MSB-first bits: per block, Rice-coded gaps between the sorted name hashes, then
///   each family's seed, layout, version, weights and each ID's axes, or the ID whole
struct GoogleFontsCatalog: Sendable {
    /// Mapped on first use. Nil once a year old: Google keeps serving old versions, so it would pin them.
    static let bundled: GoogleFontsCatalog? = shipped().flatMap { $0.isCurrent(at: .now) ? $0 : nil }

    /// The file in the package, whatever its age. Not kept: an expired one is unmapped at once.
    static func shipped() -> GoogleFontsCatalog? {
        resourceBundle()?.url(forResource: "GoogleFonts", withExtension: "catalog")
            .flatMap { try? Data(contentsOf: $0, options: .alwaysMapped) }
            .flatMap(GoogleFontsCatalog.init(data:))
    }

    /// Where SwiftPM and Xcode put the package's resources. Not `Bundle.module`: its accessor traps
    /// when the bundle is missing, and a missing catalogue should only mean CSS2 lookups.
    private static func resourceBundle() -> Bundle? {
        let name = "WebFontKit_WebFontKit.bundle"
        let library = Bundle(for: BundleToken.self)
        let places = [Bundle.main.resourceURL, Bundle.main.bundleURL, library.resourceURL, library.bundleURL,
                      library.bundleURL.deletingLastPathComponent()]
        return places.lazy.compactMap { $0.flatMap { Bundle(url: $0.appending(component: name)) } }.first
    }

    static let lifetime: TimeInterval = 365 * 24 * 60 * 60

    private let data: Data
    private let layout: Layout
    let built: Date

    init?(data: Data) {
        guard let layout = data.withUnsafeBytes(Layout.init) else { return nil }
        self.data = data
        self.layout = layout
        built = Date(timeIntervalSince1970: TimeInterval(layout.day) * 86_400)
    }

    func isCurrent(at date: Date) -> Bool {
        date.timeIntervalSince(built) < Self.lifetime
    }

    /// Each style's URL, or nil when any is missing: the caller then asks CSS2 for the whole call.
    func urls(family: String, styles: [FontStyle]) -> [FontStyle: URL]? {
        let name = Array(family.utf8)
        guard let (version, ids) = data.withUnsafeBytes({ Decoder(bytes: $0, layout: layout).lookUp(name, styles: styles) })
        else { return nil }
        var urls: [FontStyle: URL] = [:]
        urls.reserveCapacity(ids.count)
        for (style, id) in ids {
            guard let url = Self.fileURL(name: name, version: version, id: id) else { return nil }
            urls[style] = url
        }
        return urls
    }

    private static let filesPrefix = Array((CSS2.files.absoluteString + "/").utf8)
    private static let base64url = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// `<files>/<folder>/v<version>/<the ID as unpadded base64url>.ttf`, where the folder is the name
    /// lowercased with its spaces dropped. Nil for a name that isn't plain letters, digits and spaces.
    private static func fileURL(name: [UInt8], version: Int, id: [UInt8]) -> URL? {
        var text = [UInt8]()
        text.reserveCapacity(filesPrefix.count + name.count + 12 + (id.count * 4 + 2) / 3)
        text.append(contentsOf: filesPrefix)
        for byte in name {
            switch byte {
            case UInt8(ascii: " "): continue
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): text.append(byte + 32)
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): text.append(byte)
            default: return nil
            }
        }
        text.append(UInt8(ascii: "/"))
        text.append(UInt8(ascii: "v"))
        var digits = 1
        while version / digits >= 10 { digits *= 10 }
        while digits > 0 {
            text.append(UInt8(ascii: "0") + UInt8(version / digits % 10))
            digits /= 10
        }
        text.append(UInt8(ascii: "/"))
        // Three bytes to four characters; a short last group gives two or three, unpadded.
        var index = 0
        while index < id.count {
            let remaining = min(3, id.count - index)
            var group = Int(id[index]) << 16
            if remaining > 1 { group |= Int(id[index + 1]) << 8 }
            if remaining > 2 { group |= Int(id[index + 2]) }
            for character in 0...remaining { text.append(base64url[group >> (18 - 6 * character) & 63]) }
            index += 3
        }
        text.append(contentsOf: ".ttf".utf8)
        return URL(string: String(decoding: text, as: UTF8.self))
    }
}

private final class BundleToken {}

/// The header: where each section starts. Nothing else is read up front.
private struct Layout: Sendable {
    var hashBits = 0, block = 0, rice = 0, day = 0, hashSeed: UInt32 = 0, count = 0
    var layouts = 0, weights = 0, versions = 0, tags = 0, values = 0, codes = 0, rows = 0, masks = 0, index = 0, stream = 0
    /// Where each code's counts and symbols start.
    var tables = (0, 0, 0, 0, 0, 0, 0, 0, 0)

    init?(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= 56, bytes[0] == 0x57, bytes[1] == 0x46, bytes[2] == 0x4B, bytes[3] == 0x43, bytes[4] == 2
        else { return nil }
        (hashBits, block, rice) = (Int(bytes[5]), Int(bytes[6]), Int(bytes[7]))
        (day, hashSeed, count) = (Self.u32(bytes, 8), UInt32(Self.u16(bytes, 12)), Self.u16(bytes, 14))
        (layouts, weights, versions, tags, values) = (Self.u32(bytes, 16), Self.u32(bytes, 20), Self.u32(bytes, 24), Self.u32(bytes, 28), Self.u32(bytes, 32))
        (codes, rows, masks, index, stream) = (Self.u32(bytes, 36), Self.u32(bytes, 40), Self.u32(bytes, 44), Self.u32(bytes, 48), Self.u32(bytes, 52))
        // Sections in order, inside the file.
        guard (1...24).contains(hashBits), block > 0, rice < 24, 56 <= layouts, layouts <= weights, weights <= versions,
              versions <= tags, tags <= values, values <= codes, codes <= rows, rows <= masks, masks <= index,
              index <= stream, stream <= bytes.count
        else { return nil }
        // Nine codes, each found through a u16 offset after the nine offsets.
        guard codes + 18 <= rows else { return nil }
        let first = codes + 18
        tables = (first + Self.u16(bytes, codes), first + Self.u16(bytes, codes + 2), first + Self.u16(bytes, codes + 4),
                  first + Self.u16(bytes, codes + 6), first + Self.u16(bytes, codes + 8), first + Self.u16(bytes, codes + 10),
                  first + Self.u16(bytes, codes + 12), first + Self.u16(bytes, codes + 14), first + Self.u16(bytes, codes + 16))
    }

    private static func u16(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> Int {
        Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt16.self).littleEndian)
    }

    private static func u32(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> Int {
        Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian)
    }
}

/// Reads the mapped bytes in place. Every read is bounds-checked: damaged data only ever misses.
private struct Decoder {
    let bytes: UnsafeRawBufferPointer
    let layout: Layout

    static let raw = 15
    enum Code: Int { case layout, version, weights, axisWeights, base, axes, variableAxes, tag, value }

    func byte(_ at: Int) -> Int { at >= 0 && at < bytes.count ? Int(bytes[at]) : 0 }
    func u16(_ at: Int) -> Int { byte(at) | byte(at + 1) << 8 }
    func u24(_ at: Int) -> Int { byte(at) | byte(at + 1) << 8 | byte(at + 2) << 16 }

    func lookUp(_ name: [UInt8], styles: [FontStyle]) -> (Int, [FontStyle: [UInt8]])? {
        var hash: UInt32 = 0x811C_9DC5 ^ layout.hashSeed
        for byte in name { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
        let wanted = Int(hash >> UInt32(32 - layout.hashBits))

        // The last block whose first hash is at most the wanted one.
        var low = 0, high = (layout.stream - layout.index) / 6
        guard high > 0, u24(layout.index) <= wanted else { return nil }
        while high - low > 1 {
            let middle = (low + high) / 2
            if u24(layout.index + 6 * middle) <= wanted { low = middle } else { high = middle }
        }
        var bits = Bits(bytes: bytes, at: 8 * layout.stream + u24(layout.index + 6 * low + 3))
        let families = min(layout.block, layout.count - low * layout.block)
        guard families > 0 else { return nil }
        // One pass over the block's hash gaps: where the name sits, and the bits left at its first record.
        var current = u24(layout.index + 6 * low), position = current == wanted ? 0 : -1
        for familyIndex in 1..<max(families, 1) {
            var ones = 0
            while true {
                let run = (~bits.peek(32)).leadingZeroBitCount
                ones += run
                bits.at += run
                guard ones < 1 << 12 else { return nil }
                if run < 32 { break }
            }
            bits.at += 1
            current += ones << layout.rice | bits.read(layout.rice)
            if current == wanted { position = familyIndex }
            if current > wanted, position < 0 { return nil }   // sorted: it isn't here
        }
        guard position >= 0 else { return nil }
        for _ in 0..<position {
            guard family(&bits, name: nil, styles: []) != nil else { return nil }
        }
        return family(&bits, name: name, styles: styles)
    }

    /// A canonical Huffman symbol, from the code's counts per length and its symbols in code order.
    private func symbol(_ code: Code, _ bits: inout Bits) -> Int? {
        let table: Int
        switch code {
        case .layout: table = layout.tables.0
        case .version: table = layout.tables.1
        case .weights: table = layout.tables.2
        case .axisWeights: table = layout.tables.3
        case .base: table = layout.tables.4
        case .axes: table = layout.tables.5
        case .variableAxes: table = layout.tables.6
        case .tag: table = layout.tables.7
        case .value: table = layout.tables.8
        }
        let window = Int(bits.peek(8))
        var value = 0, first = 0, index = 0
        for length in 1...8 {
            value |= window >> (8 - length) & 1
            let count = byte(table + length - 1)
            if value - first < count {
                bits.at += length
                return byte(table + 8 + index + value - first)
            }
            index += count
            first = (first + count) << 1
            value <<= 1
        }
        return nil
    }

    /// One family's record. With no name it is only read past.
    private func family(_ bits: inout Bits, name: [UInt8]?, styles: [FontStyle]) -> (Int, [FontStyle: [UInt8]])? {
        let seed = bits.read(8)
        guard let layoutIndex = symbol(.layout, &bits), let versionIndex = symbol(.version, &bits),
              layoutIndex < byte(layout.layouts), versionIndex < byte(layout.versions)
        else { return nil }
        let shape = byte(layout.layouts + 1 + layoutIndex), version = byte(layout.versions + 1 + versionIndex)
        var ids: [FontStyle: [UInt8]] = [:]
        var firstWeights = 0
        for group in 0...(shape >> 4 & 1) {
            let flags = group == 0 ? shape >> 2 & 3 : shape & 3
            let italic = flags & 1 != 0, computed = flags & 2 != 0
            var weights = firstWeights
            if group == 0 || !bits.flag() {
                guard let weightsIndex = symbol(computed ? .axisWeights : .weights, &bits), weightsIndex < byte(layout.weights)
                else { return nil }
                weights = u16(layout.weights + 1 + 2 * weightsIndex)
            }
            if group == 0 { firstWeights = weights }
            let wanted = name == nil ? [] : styles.filter { $0.isItalic == italic && weights >> ($0.weight / 100) & 1 == 1 }
            if computed {
                guard let base = symbol(.base, &bits), let axes = symbol(.variableAxes, &bits),
                      let id = id(&bits, seed: seed, name: wanted.isEmpty ? nil : name, italic: italic, computed: true,
                                  weight: base * 100, axes: axes)
                else { return nil }
                let offset = bits.flag() ? id.weightOffset : bits.read(8)
                for style in wanted {
                    // Any other weight differs only in the little-endian Float32 of the weight.
                    guard offset >= 0, offset + 4 <= id.bytes.count else { return nil }
                    var other = id.bytes
                    let diff = Float(base * 100).bitPattern ^ Float(style.weight).bitPattern
                    for position in 0..<4 { other[offset + position] ^= UInt8(truncatingIfNeeded: diff >> (8 * position)) }
                    ids[style] = other
                }
            } else {
                for weight in stride(from: 100, through: 1500, by: 100) where weights >> (weight / 100) & 1 == 1 {
                    let style = wanted.first { $0.weight == weight }
                    guard let axes = symbol(.axes, &bits),
                          let id = id(&bits, seed: seed, name: style == nil ? nil : name, italic: italic, computed: false,
                                      weight: weight, axes: axes)
                    else { return nil }
                    if let style { ids[style] = id.bytes }
                }
            }
        }
        if name != nil, ids.count != styles.count { return nil }
        return (version, ids)
    }

    private struct ID { var bytes: [UInt8] = []; var weightOffset = -1 }

    /// One call per byte instead of the array's growth path at every site: keeps the code small.
    @inline(never) private static func put(_ byte: UInt8, into text: inout [UInt8]) { text.append(byte) }

    /// One file ID: rebuilt and unmasked for a name, otherwise only read past.
    private func id(_ bits: inout Bits, seed: Int, name: [UInt8]?, italic: Bool, computed: Bool, weight: Int, axes: Int) -> ID? {
        var id = ID()
        var text: [UInt8] = []
        let build = name != nil
        if axes == Self.raw {
            let length = bits.read(8)
            text.reserveCapacity(build ? length + 1 : 0)
            if build { Self.put(UInt8(seed), into: &text) }
            var read = 0
            while read < length {
                let zeros = bits.read(8), literals = bits.read(8)
                guard zeros + literals > 0 else { return nil }
                if build { text.append(contentsOf: repeatElement(0, count: zeros)) }
                for _ in 0..<literals {
                    let value = bits.read(8)
                    if build { Self.put(UInt8(value), into: &text) }
                }
                read += zeros + literals
            }
            guard read == length else { return nil }
        } else {
            if let name {
                text.reserveCapacity(name.count + 20 + 13 * axes)
                Self.put(UInt8(seed), into: &text); Self.put(0, into: &text); Self.put(0, into: &text); Self.put(0, into: &text)
                Self.put(UInt8(truncatingIfNeeded: name.count), into: &text)
                text.append(contentsOf: name)
                if italic { Self.put(0x10, into: &text); Self.put(0x02, into: &text) }
                if !computed, weight != 400 {
                    Self.put(0x18, into: &text)
                    var value = weight
                    while value >= 0x80 { Self.put(UInt8(value & 0x7F | 0x80), into: &text); value >>= 7 }
                    Self.put(UInt8(value), into: &text)
                }
            }
            let tagCount = byte(layout.tags)
            for _ in 0..<axes {
                // A tag the catalogue doesn't list follows its symbol whole, as does a value it can't name.
                guard let tagIndex = symbol(.tag, &bits), tagIndex <= tagCount else { return nil }
                let entry = layout.tags + 1 + 11 * tagIndex
                let known = tagIndex < tagCount, fromWeight = known && byte(entry + 5) & 1 != 0
                if build { Self.put(0x3A, into: &text); Self.put(0x0B, into: &text); Self.put(0x08, into: &text) }
                for position in 0..<5 {
                    let tagByte = known ? byte(entry + position) : bits.read(8)
                    if build { Self.put(UInt8(tagByte), into: &text) }
                }
                if build { Self.put(0x15, into: &text) }
                guard let valueIndex = symbol(.value, &bits) else { return nil }
                if fromWeight { id.weightOffset = text.count }
                switch valueIndex {
                case 16:
                    for _ in 0..<4 {
                        let valueByte = bits.read(8)
                        if build { Self.put(UInt8(valueByte), into: &text) }
                    }
                case 0 where fromWeight:
                    let pattern = Float(weight).bitPattern
                    if build { for shift in stride(from: 0, to: 32, by: 8) { Self.put(UInt8(truncatingIfNeeded: pattern >> shift), into: &text) } }
                case 0:
                    if build { for position in 0..<4 { text.append(known ? UInt8(byte(entry + 6 + position)) : 0) } }
                default:
                    guard known, valueIndex - 1 < byte(entry + 5) >> 4 else { return nil }
                    let at = layout.values + 4 * (byte(entry + 10) + valueIndex - 1)
                    if build { for position in 0..<4 { text.append(UInt8(byte(at + position))) } }
                }
            }
            guard build else { return id }
            Self.put(0x20, into: &text); Self.put(0x00, into: &text)
            text[2] = UInt8(truncatingIfNeeded: text.count - 5)
        }
        guard build else { return id }
        let start = u16(layout.rows + 2 * seed), end = u16(layout.rows + 2 * seed + 2)
        guard text.count - 1 <= end - start, layout.masks + end <= layout.index else { return nil }
        for at in 1..<text.count { text[at] ^= UInt8(byte(layout.masks + start + at - 1)) }
        id.bytes = text
        return id
    }
}

/// MSB-first bits; past the end reads zeros.
private struct Bits {
    let bytes: UnsafeRawBufferPointer
    var at: Int

    func peek(_ count: Int) -> UInt32 {
        let first = at >> 3
        var window: UInt64 = 0
        if first >= 0, first + 8 <= bytes.count {
            window = bytes.loadUnaligned(fromByteOffset: first, as: UInt64.self).bigEndian
        } else {
            for at in first..<first + 8 { window = window << 8 | UInt64(at >= 0 && at < bytes.count ? bytes[at] : 0) }
        }
        return UInt32(truncatingIfNeeded: (window << UInt64(at & 7)) >> UInt64(64 - count))
    }

    mutating func read(_ count: Int) -> Int {
        defer { at += count }
        return count == 0 ? 0 : Int(peek(count))
    }

    mutating func flag() -> Bool { read(1) == 1 }
}
