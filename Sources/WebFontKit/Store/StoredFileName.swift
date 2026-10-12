import CryptoKit
import Foundation

/// `<family>@<weight><n|i>@<hash>[@v<NN>].wfkfont`, `…@system.wfkmark`, `<UUID>.wfkpart`. No index: processes share the directory.
enum StoredFileName {
    static let fontExtension = "wfkfont"
    static let markerExtension = "wfkmark"
    static let partialExtension = "wfkpart"

    /// A font with its key hash and version, or a system-collision marker.
    enum Kind: Equatable, Sendable {
        case font(hash: String, version: String?)
        case marker
    }

    /// What a stored file's name says: family, style and kind.
    struct Parsed: Equatable, Sendable {
        var family: String
        var style: FontStyle
        var kind: Kind
    }

    static func font(family: String, style: FontStyle, cacheKey: String, version: String?) -> String {
        var name = "\(prefix(family: family, style: style))@\(keyHash(family: family, style: style, cacheKey: cacheKey))"
        if let version {
            name += "@\(version)"
        }
        return name + "." + fontExtension
    }

    static func marker(family: String, style: FontStyle) -> String {
        "\(prefix(family: family, style: style))@system.\(markerExtension)"
    }

    static func partial() -> String {
        UUID().uuidString + "." + partialExtension
    }

    /// Never change this, or every stored file looks stale.
    static func keyHash(family: String, style: FontStyle, cacheKey: String) -> String {
        var input = Data(family.utf8)
        for part in [String(style.weight), style.isItalic ? "i" : "n", cacheKey] {
            input.append(0)
            input.append(contentsOf: part.utf8)
        }
        // The first 8 bytes as lowercase hex; `String(format:)` per byte was slow.
        var hex: [UInt8] = []
        hex.reserveCapacity(16)
        for byte in SHA256.hash(data: input).prefix(8) {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func parse(_ name: String) -> Parsed? {
        let fields = name.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3, let family = decode(fields[0]), !family.isEmpty,
              let style = parseStyle(fields[1])
        else { return nil }

        if fields.count == 3, fields[2] == "system." + markerExtension {
            return Parsed(family: family, style: style, kind: .marker)
        }
        let suffix = "." + fontExtension
        switch fields.count {
        case 3 where fields[2].hasSuffix(suffix):
            let hash = String(fields[2].dropLast(suffix.count))
            guard isHash(hash) else { return nil }
            return Parsed(family: family, style: style, kind: .font(hash: hash, version: nil))
        case 4 where fields[3].hasSuffix(suffix):
            let version = String(fields[3].dropLast(suffix.count))
            guard isHash(fields[2]), isVersion(version) else { return nil }
            return Parsed(family: family, style: style, kind: .font(hash: fields[2], version: version))
        default:
            return nil
        }
    }

    private static func prefix(family: String, style: FontStyle) -> String {
        "\(encode(family))@\(style.weight)\(style.isItalic ? "i" : "n")"
    }

    /// ASCII letters and digits; everything else is percent-encoded, so a name splits cleanly at `@`.
    private static let unescaped = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    static func encode(_ family: String) -> String {
        family.addingPercentEncoding(withAllowedCharacters: unescaped)!
    }

    static func decode(_ encoded: String) -> String? {
        encoded.removingPercentEncoding
    }

    private static func parseStyle(_ field: String) -> FontStyle? {
        guard let marker = field.last, marker == "n" || marker == "i",
              let weight = Int(field.dropLast()), FontStyle.isValidWeight(weight)
        else { return nil }
        return FontStyle(weight: weight, italic: marker == "i")
    }

    private static func isHash(_ text: String) -> Bool {
        text.count == 16 && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static func isVersion(_ text: String) -> Bool {
        text.count > 1 && text.first == "v" && text.dropFirst().allSatisfy { ("0"..."9").contains($0) }
    }
}
