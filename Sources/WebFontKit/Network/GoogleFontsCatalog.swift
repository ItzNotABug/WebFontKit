import Foundation

/// Google's file ID for every family and style, so a first load can skip the CSS2 lookup.
/// Memory-mapped and read in place. Damaged data never traps: a lookup misses or, at worst, gives a URL
/// that 404s, and the loader then asks CSS2.
///
/// An ID is a seed byte, then Google's description XOR the seed's mask row:
/// `00 <ID length − 5> 00 <name length> <name> [10 02] [18 <weight>] [3a 0b 08 <tag> 15 <float32>]… 20 00`
/// (italic, a static weight other than 400 as a varint, one block per axis). Records keep the
/// fields that differ; the reader rebuilds the description and XORs.
///
/// Names are found by the top hash bits of 32-bit FNV-1a (basis `0x811C9DC5` XOR the hash seed). An
/// unknown name matches a family ~0.2% of the time: its URL 404s and the loader asks CSS2.
///
/// Built by `scripts/catalog.sh`. Little-endian, sections in this order:
/// - header: `WFKC`, format 2, hash bits, block size, Rice parameter, build day (u32, days since
///   1970), hash seed (u16), family count (u16), then the offsets (u32) of the ten sections below
/// - layouts: count, then per layout bit 4 (a second group) and each group's flags in bits 2–3
///   and 0–1 (1 italic, 2 computed: one stored ID gives every weight)
/// - weight sets: count, then u16s, bit n for weight n × 100
/// - versions: count, then bytes
/// - axis tags: count, then per tag its 5 bytes, flags (bit 0 wght, bits 4–7 other-value count),
///   usual value (4 bytes), first other-value index
/// - other values: 4 bytes each
/// - codes: nine u16 offsets past themselves, then per code its canonical Huffman table: counts
///   per length 1–8, then symbols. In order: layout, version, weights, axis weights (a computed
///   group's set), base, axes, variable axes (a computed ID's count), tag, value
/// - row offsets: 257 u16s into the mask rows (row n ends where n + 1 starts)
/// - mask rows: row byte i masks ID byte i + 1
/// - block index: per block, its first name hash and its bit offset into the records (u24 each)
/// - records, MSB-first: per block the gaps between sorted name hashes (Rice: ones ended by a 0,
///   then the Rice parameter's bits), then per family its seed (8 bits), layout, version, and per
///   group: a weight set (a second group first has a bit: 1 = the first group's set), base
///   weight ÷ 100 if computed, then its IDs: one if computed, else one per weight, ascending.
///   Per ID: axis count, then per axis a tag (one past the table: 5 raw bytes follow) and a value
///   (0: the usual one, the weight for wght, zeros for a raw tag; 1–15: other values; 16: 4 raw
///   bytes). 15 axes marks a whole ID: its length after the seed, then runs of a zero count, a
///   literal count and the literals (8 bits each), masked like any other. A computed ID ends with
///   a bit, 1 if the weight float is its wght value, else the float's offset follows (8 bits).
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
    private let header: Header
    let built: Date

    init?(data: Data) {
        guard let header = data.withUnsafeBytes(Header.init) else { return nil }
        self.data = data
        self.header = header
        built = Date(timeIntervalSince1970: TimeInterval(header.day) * 86_400)
    }

    var familyCount: Int { header.familyCount }

    func isCurrent(at date: Date) -> Bool {
        date.timeIntervalSince(built) < Self.lifetime
    }

    /// Each style's URL, or nil when any is missing: the caller then asks CSS2 for the whole call.
    func urls(family: String, styles: [FontStyle]) -> [FontStyle: URL]? {
        let name = Array(family.utf8)
        return data.withUnsafeBytes { Decoder(bytes: $0, header: header).urls(name: name, styles: styles) }
    }
}

private final class BundleToken {}

/// The header's fields, and where each code's table starts. Nothing else is read up front.
private struct Header: Sendable {
    let hashBits, blockSize, rice, day, familyCount: Int
    let hashSeed: UInt32
    let layouts, weightSets, versions, tags, values, codes, rows, masks, index, records: Int
    let tables: [Int]

    init?(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= 56, bytes.prefix(5).elementsEqual("WFKC\u{2}".utf8) else { return nil }
        (hashBits, blockSize, rice) = (Int(bytes[5]), Int(bytes[6]), Int(bytes[7]))
        (day, hashSeed, familyCount) = (Self.u32(bytes, 8), UInt32(Self.u16(bytes, 12)), Self.u16(bytes, 14))
        (layouts, weightSets, versions, tags, values) =
            (Self.u32(bytes, 16), Self.u32(bytes, 20), Self.u32(bytes, 24), Self.u32(bytes, 28), Self.u32(bytes, 32))
        (codes, rows, masks, index, records) =
            (Self.u32(bytes, 36), Self.u32(bytes, 40), Self.u32(bytes, 44), Self.u32(bytes, 48), Self.u32(bytes, 52))
        // Sections in order and inside the file.
        guard (1...24).contains(hashBits), rice < 24, 56 <= layouts, layouts <= weightSets,
              weightSets <= versions, versions <= tags, tags <= values, values <= codes, codes + 18 <= rows,
              rows <= masks, masks <= index, index <= records, records <= bytes.count
        else { return nil }
        // Nine u16 offsets, from the end of the offsets.
        let first = codes + 18
        tables = stride(from: codes, to: first, by: 2).map { first + Self.u16(bytes, $0) }
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
    let header: Header

    /// The axis count that marks an ID kept whole.
    static let whole = 15
    enum Code: Int { case layout, version, weights, axisWeights, base, axes, variableAxes, tag, value }

    func byte(_ at: Int) -> Int { at >= 0 && at < bytes.count ? Int(bytes[at]) : 0 }
    func u16(_ at: Int) -> Int { byte(at) | byte(at + 1) << 8 }
    func u24(_ at: Int) -> Int { byte(at) | byte(at + 1) << 8 | byte(at + 2) << 16 }

    func urls(name: [UInt8], styles: [FontStyle]) -> [FontStyle: URL]? {
        var hash: UInt32 = 0x811C_9DC5 ^ header.hashSeed
        for byte in name { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
        let nameHash = Int(hash >> UInt32(32 - header.hashBits))

        // The last block whose first hash is at most the name's.
        var low = 0, high = (header.records - header.index) / 6
        guard high > 0, u24(header.index) <= nameHash else { return nil }
        while high - low > 1 {
            let middle = (low + high) / 2
            if u24(header.index + 6 * middle) <= nameHash { low = middle } else { high = middle }
        }
        let families = min(header.blockSize, header.familyCount - low * header.blockSize)
        guard families > 0 else { return nil }
        var bits = Bits(bytes: bytes, at: 8 * header.records + u24(header.index + 6 * low + 3))
        // Read every gap, finding the name's place; leaves the bits at the block's first record.
        var current = u24(header.index + 6 * low)
        var position: Int? = current == nameHash ? 0 : nil
        for familyIndex in 1..<families {
            // Unary quotient, counted a word at a time.
            var ones = 0
            while true {
                let run = (~bits.peek(32)).leadingZeroBitCount
                ones += run
                bits.at += run
                guard ones << header.rice < 1 << header.hashBits else { return nil }
                if run < 32 { break }
            }
            bits.at += 1
            current += ones << header.rice | bits.read(header.rice)
            if current == nameHash { position = familyIndex }
            if current > nameHash, position == nil { return nil }   // sorted: it isn't here
        }
        guard let position else { return nil }
        var urls = [FontStyle: URL](minimumCapacity: styles.count)
        for _ in 0..<position {
            guard family(&bits, name: nil, styles: [], into: &urls) else { return nil }
        }
        guard family(&bits, name: name, styles: styles, into: &urls), urls.count == styles.count else { return nil }
        return urls
    }

    /// A canonical Huffman symbol, from the code's counts per length and its symbols in code order.
    private func symbol(_ code: Code, _ bits: inout Bits) -> Int? {
        let table = header.tables[code.rawValue]
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

    /// One family's record, adding each wanted style's URL. With no name it is only read past.
    private func family(_ bits: inout Bits, name: [UInt8]?, styles: [FontStyle],
                        into urls: inout [FontStyle: URL]) -> Bool {
        let seed = bits.read(8)
        guard let layoutIndex = symbol(.layout, &bits), layoutIndex < byte(header.layouts),
              let versionIndex = symbol(.version, &bits), versionIndex < byte(header.versions)
        else { return false }
        let shape = byte(header.layouts + 1 + layoutIndex), version = byte(header.versions + 1 + versionIndex)
        var text: [UInt8] = []
        var weights = 0
        for group in 0...(shape >> 4 & 1) {
            let flags = group == 0 ? shape >> 2 & 3 : shape & 3
            let italic = flags & 1 != 0, computed = flags & 2 != 0
            if group == 0 || !bits.flag() {
                guard let set = symbol(computed ? .axisWeights : .weights, &bits), set < byte(header.weightSets)
                else { return false }
                weights = u16(header.weightSets + 1 + 2 * set)
            }
            if computed {
                let wanted = styles.contains { $0.isItalic == italic }
                var weightOffset: Int?
                guard let base = symbol(.base, &bits), let axes = symbol(.variableAxes, &bits),
                      id(&bits, into: &text, weightOffset: &weightOffset, seed: seed, name: wanted ? name : nil,
                         italic: italic, computed: true, weight: base * 100, axes: axes)
                else { return false }
                let offset = bits.flag() ? weightOffset : bits.read(8)
                guard wanted, let name else { continue }
                for style in styles where style.isItalic == italic && weights >> (style.weight / 100) & 1 == 1 {
                    // Other weights differ only in the weight float: patched in, then back out.
                    guard let offset, offset + 4 <= text.count else { return false }
                    let diff = Float(base * 100).bitPattern ^ Float(style.weight).bitPattern
                    Self.flip(&text, at: offset, by: diff)
                    guard Self.add(style, name: name, version: version, id: text, to: &urls) else { return false }
                    Self.flip(&text, at: offset, by: diff)
                }
            } else {
                for weight in stride(from: 100, through: 1500, by: 100) where weights >> (weight / 100) & 1 == 1 {
                    let style = styles.first { $0.isItalic == italic && $0.weight == weight }
                    var weightOffset: Int?
                    guard let axes = symbol(.axes, &bits),
                          id(&bits, into: &text, weightOffset: &weightOffset, seed: seed,
                             name: style == nil ? nil : name, italic: italic, computed: false, weight: weight,
                             axes: axes)
                    else { return false }
                    if let style, let name {
                        guard Self.add(style, name: name, version: version, id: text, to: &urls) else { return false }
                    }
                }
            }
        }
        return true
    }

    /// One file ID into `text`: rebuilt for a name, otherwise only read past. False for a bad record.
    private func id(_ bits: inout Bits, into text: inout [UInt8], weightOffset: inout Int?, seed: Int, name: [UInt8]?,
                    italic: Bool, computed: Bool, weight: Int, axes: Int) -> Bool {
        let build = name != nil
        if build { text.removeAll(keepingCapacity: true) }
        if axes == Self.whole {
            let length = bits.read(8)
            if build {
                text.reserveCapacity(length + 1)
                text.append(UInt8(seed))
            }
            var read = 0
            while read < length {
                // A valid record ends inside the file; a damaged count stops here.
                guard bits.at <= 8 * bytes.count else { return false }
                let zeros = bits.read(8), literals = bits.read(8)
                if build { text.append(contentsOf: repeatElement(0, count: zeros)) }
                for _ in 0..<literals {
                    let value = bits.read(8)
                    if build { text.append(UInt8(value)) }
                }
                read += zeros + literals
            }
            guard read == length else { return false }
        } else {
            if let name {
                text.reserveCapacity(name.count + 20 + 13 * axes)
                text.append(UInt8(seed))
                text.append(0)
                text.append(0)   // the length, set at the end
                text.append(0)
                text.append(UInt8(truncatingIfNeeded: name.count))
                text.append(contentsOf: name)
                if italic {
                    text.append(0x10)
                    text.append(0x02)
                }
                if !computed, weight != 400 {
                    text.append(0x18)
                    var value = weight
                    while value >= 0x80 {
                        text.append(UInt8(value & 0x7F | 0x80))
                        value >>= 7
                    }
                    text.append(UInt8(value))
                }
            }
            let tagCount = byte(header.tags)
            for _ in 0..<axes {
                guard bits.at <= 8 * bytes.count else { return false }
                // Unlisted tags and values follow their symbol raw.
                guard let tagIndex = symbol(.tag, &bits), tagIndex <= tagCount else { return false }
                let entry = header.tags + 1 + 11 * tagIndex
                let listed = tagIndex < tagCount, fromWeight = listed && byte(entry + 5) & 1 != 0
                if build {
                    text.append(0x3A)
                    text.append(0x0B)
                    text.append(0x08)
                }
                for position in 0..<5 {
                    let tagByte = listed ? byte(entry + position) : bits.read(8)
                    if build { text.append(UInt8(tagByte)) }
                }
                if build { text.append(0x15) }
                guard let valueIndex = symbol(.value, &bits) else { return false }
                if fromWeight { weightOffset = text.count }
                switch valueIndex {
                case 0 where fromWeight:
                    let pattern = Float(weight).bitPattern
                    if build {
                        for position in 0..<4 { text.append(UInt8(truncatingIfNeeded: pattern >> (8 * position))) }
                    }
                case 0:
                    if build { for position in 0..<4 { text.append(listed ? UInt8(byte(entry + 6 + position)) : 0) } }
                case 16:
                    for _ in 0..<4 {
                        let valueByte = bits.read(8)
                        if build { text.append(UInt8(valueByte)) }
                    }
                default:
                    guard listed, valueIndex - 1 < byte(entry + 5) >> 4 else { return false }
                    let at = header.values + 4 * (byte(entry + 10) + valueIndex - 1)
                    if build { for position in 0..<4 { text.append(UInt8(byte(at + position))) } }
                }
            }
            if build {
                text.append(0x20)
                text.append(0x00)
                text[2] = UInt8(truncatingIfNeeded: text.count - 5)
            }
        }
        guard build else { return true }
        let start = u16(header.rows + 2 * seed), end = u16(header.rows + 2 * seed + 2)
        guard text.count - 1 <= end - start, header.masks + end <= header.index else { return false }
        for at in 1..<text.count { text[at] ^= UInt8(byte(header.masks + start + at - 1)) }
        return true
    }

    /// XORs a little-endian u32 into four bytes; twice undoes it.
    private static func flip(_ text: inout [UInt8], at offset: Int, by diff: UInt32) {
        for position in 0..<4 { text[offset + position] ^= UInt8(truncatingIfNeeded: diff >> (8 * position)) }
    }

    /// Builds the style's URL into `urls`; false for a name Google's URLs can't hold.
    private static func add(_ style: FontStyle, name: [UInt8], version: Int, id: [UInt8],
                            to urls: inout [FontStyle: URL]) -> Bool {
        guard let url = url(name: name, version: version, id: id) else { return false }
        urls[style] = url
        return true
    }

    private static let files = Array((CSS2.files.absoluteString + "/").utf8)
    private static let base64url = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// `<files>/<folder>/v<version>/<the ID as unpadded base64url>.ttf`, the folder being the name lowercased
    /// with its spaces dropped. Nil for a name that isn't plain letters, digits and spaces, as no Google name is.
    private static func url(name: [UInt8], version: Int, id: [UInt8]) -> URL? {
        var text: [UInt8] = []
        text.reserveCapacity(files.count + name.count + 8 + (id.count * 4 + 2) / 3 + 4)
        text.append(contentsOf: files)
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
        text.append(contentsOf: String(version).utf8)
        text.append(UInt8(ascii: "/"))
        var index = 0
        while index < id.count {
            // Three bytes to four characters; a short last group gives two or three.
            let remaining = min(3, id.count - index)
            var group = Int(id[index]) << 16
            if remaining > 1 { group |= Int(id[index + 1]) << 8 }
            if remaining > 2 { group |= Int(id[index + 2]) }
            for sextet in 0...remaining { text.append(base64url[group >> (18 - 6 * sextet) & 63]) }
            index += 3
        }
        text.append(contentsOf: ".ttf".utf8)
        return URL(string: String(decoding: text, as: UTF8.self))
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
            for index in first..<first + 8 {
                window = window << 8 | UInt64(index >= 0 && index < bytes.count ? bytes[index] : 0)
            }
        }
        return UInt32(truncatingIfNeeded: (window << UInt64(at & 7)) >> UInt64(64 - count))
    }

    mutating func read(_ count: Int) -> Int {
        defer { at += count }
        return count == 0 ? 0 : Int(peek(count))
    }

    mutating func flag() -> Bool { read(1) == 1 }
}
