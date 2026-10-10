import Foundation
import Testing
@testable import WebFontKit

@Suite(.timeLimit(.minutes(1)))
struct FileNameTests {
    @Test("the name of Lobster 400 regular from the default source is pinned")
    func golden() {
        let key = DefaultFontSource.default.cacheKey(for: FontRequest(family: "Lobster"))
        #expect(key == "Lobster|400|n")
        // Worked out by hand (SHA-256 of "Lobster\0" "400\0" "n\0" "Lobster|400|n"), never from the code.
        #expect(StoredFileName.font(family: "Lobster", style: .regular, cacheKey: key, version: "v32")
            == "Lobster@400n@fd1062888b6dea6c@v32.wfkfont")
    }

    @Test("the family is percent-encoded except ASCII letters and digits")
    func familyEncoding() {
        #expect(StoredFileName.marker(family: "Noto Sans Kannada", style: .regular) == "Noto%20Sans%20Kannada@400n@system.wfkmark")
        #expect(StoredFileName.encode("A@b/c.é") == "A%40b%2Fc%2E%C3%A9")
        #expect(StoredFileName.decode("A%40b%2Fc%2E%C3%A9") == "A@b/c.é")
        #expect(StoredFileName.decode("bad%4") == nil)
    }

    @Test(
        "a family encodes to exactly these bytes and decodes back",
        arguments: [
            ("Lobster", "Lobster"),
            ("Bebas Neue", "Bebas%20Neue"),
            ("Été", "%C3%89t%C3%A9"),
            ("a-b_c.d", "a%2Db%5Fc%2Ed"),
            ("東京", "%E6%9D%B1%E4%BA%AC"),
        ]
    )
    func exactEncoding(family: String, encoded: String) {
        #expect(StoredFileName.encode(family) == encoded)
        #expect(StoredFileName.decode(encoded) == family)
        #expect(StoredFileName.decode(StoredFileName.encode(family)) == family)
    }

    @Test("an escape that is not two hex digits does not decode")
    func malformedEscape() {
        #expect(StoredFileName.decode("%G1") == nil)
    }

    @Test(
        "every name parses back to its family and style, with and without a version",
        arguments: [
            ("Lobster", FontStyle.regular, "v32" as String?),
            ("Bebas Neue", .boldItalic, nil),
            ("Fam@ily", FontStyle(weight: 300, italic: true), "v1"),
            ("lobster", .bold, nil),
        ]
    )
    func roundTrip(family: String, style: FontStyle, version: String?) throws {
        let name = StoredFileName.font(family: family, style: style, cacheKey: "k", version: version)
        let parsed = try #require(StoredFileName.parse(name))
        #expect(parsed.family == family)
        #expect(parsed.style == style)
        #expect(parsed.kind == .font(hash: StoredFileName.keyHash(family: family, style: style, cacheKey: "k"), version: version))
        let marker = try #require(StoredFileName.parse(StoredFileName.marker(family: family, style: style)))
        #expect(marker == .init(family: family, style: style, kind: .marker))
    }

    @Test("names that are not the library's do not parse")
    func foreignNames() {
        for name in [
            "Lobster.ttf", "Lobster@400n.wfkfont", "Lobster@450n@94f2cac70c2b6dcc.wfkfont",
            "Lobster@400x@94f2cac70c2b6dcc.wfkfont", "Lobster@400n@XYZ.wfkfont", "@400n@94f2cac70c2b6dcc.wfkfont",
            "Lobster@400n@94f2cac70c2b6dcc@32.wfkfont", "Lobster@400n@94f2cac70c2b6dcc@v32@x.wfkfont",
            "Lobster@400n@system.wfkfont", "Lobster@400n@94f2cac70c2b6dcc.ttf", "\(UUID().uuidString).wfkpart",
        ] {
            #expect(StoredFileName.parse(name) == nil, "\(name)")
        }
    }

    @Test("odd keys give valid, distinct names, even on a case-insensitive volume")
    func oddKeys() {
        let keys = ["a/b", "../..", String(repeating: "x", count: 300), "Key", "key"]
        let names = keys.map { StoredFileName.font(family: "Lobster", style: .regular, cacheKey: $0, version: nil) }
        #expect(Set(names.map { $0.lowercased() }).count == keys.count)
        #expect(names.allSatisfy { !$0.contains("/") && $0.utf8.count < 255 })
    }

    @Test("the hash covers the family as written, so case variants differ with one key")
    func caseVariants() {
        let upper = StoredFileName.font(family: "Lobster", style: .regular, cacheKey: "Lobster-v32", version: nil)
        let lower = StoredFileName.font(family: "lobster", style: .regular, cacheKey: "Lobster-v32", version: nil)
        #expect(upper.lowercased() != lower.lowercased())
    }

    @Test("one key for every style still gives one name per style")
    func oneKeyManyStyles() {
        let names = [FontStyle.regular, .bold, .italic, .boldItalic].map {
            StoredFileName.font(family: "Lobster", style: $0, cacheKey: "Lobster-v32", version: nil)
        }
        #expect(Set(names).count == 4)
    }

    @Test("a partial's name is a UUID with the partial extension")
    func partialName() {
        let name = StoredFileName.partial()
        #expect(name.hasSuffix(".wfkpart"))
        #expect(UUID(uuidString: String(name.dropLast(".wfkpart".count))) != nil)
    }
}
