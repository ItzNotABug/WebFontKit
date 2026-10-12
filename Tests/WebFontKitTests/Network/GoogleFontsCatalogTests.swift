import CryptoKit
import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite
struct GoogleFontsCatalogTests {
    /// Real Google rows for ten families (`Tests/Fixtures/catalog/rows.json`) and the catalogue built from them.
    static let rows: [(family: String, style: String, url: String)] = {
        let raw = try! JSONSerialization.jsonObject(with: Fixtures.data("catalog/rows.json")) as! [[String]]
        return raw.map { ($0[0], $0[1], $0[2]) }
    }()
    static let catalog = GoogleFontsCatalog(data: Fixtures.data("catalog/sample.catalog"))!

    static func style(_ code: String) -> FontStyle {
        FontStyle(weight: Int(code.filter(\.isNumber))!, italic: code.hasSuffix("i"))
    }

    @Test("every style decodes to exactly Google's URL: listed, computed, upright and italic")
    func everyRowMatchesGoogle() {
        for row in Self.rows {
            let style = Self.style(row.style)
            #expect(Self.catalog.urls(family: row.family, styles: [style])?[style]?.absoluteString == row.url,
                    "\(row.family) \(row.style)")
        }
    }

    @Test("a call gets all its styles, or nil when any is missing")
    func allOrNothing() {
        let urls = Self.catalog.urls(family: "Lato", styles: [.regular, .bold, .italic, .boldItalic])
        #expect(urls?.count == 4)
        #expect(Self.catalog.urls(family: "Lobster", styles: [.regular, .bold]) == nil)
    }

    @Test("an unknown family, or a name in other letter case, is a miss", arguments: ["Lobstr", "lobster", "", "Zzzz Unknown"])
    func misses(family: String) {
        #expect(Self.catalog.urls(family: family, styles: [.regular]) == nil)
    }

    @Test("the binary search finds the first and last families too")
    func edges() {
        let names = Set(Self.rows.map(\.family)).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        for name in [names.first!, names.last!] {
            let row = Self.rows.first { $0.family == name }!
            #expect(Self.catalog.urls(family: name, styles: [Self.style(row.style)]) != nil, "\(name)")
        }
    }

    @Test("a wrong header is rejected; damaged data only ever misses")
    func malformed() {
        var wrongMagic = Fixtures.data("catalog/sample.catalog")
        wrongMagic[0] = UInt8(ascii: "X")
        #expect(GoogleFontsCatalog(data: wrongMagic) == nil)
        #expect(GoogleFontsCatalog(data: Data("WFKC".utf8)) == nil)

        let full = Fixtures.data("catalog/sample.catalog")
        // Seeded, so a failing round replays exactly.
        var random = SplitMix64(seed: 0x5EED)
        for _ in 0..<500 {
            var damaged = full
            for _ in 0..<4 { damaged[Int.random(in: 12..<damaged.count, using: &random)] = .random(in: 0...255, using: &random) }
            let cut = damaged.prefix(Int.random(in: 0...damaged.count, using: &random))
            for data in [damaged, Data(cut)] {
                guard let catalog = GoogleFontsCatalog(data: data) else { continue }
                for family in ["Lobster", "Inter", "Lato", "Roboto"] {
                    _ = catalog.urls(family: family, styles: [.regular, .bold, .italic])
                }
            }
        }
    }

    @Test("a catalogue is used for a year after it was built, then left to CSS2")
    func expiry() {
        let built = Self.catalog.built
        #expect(Self.catalog.isCurrent(at: built.addingTimeInterval(300 * 86_400)))
        #expect(!Self.catalog.isCurrent(at: built.addingTimeInterval(366 * 86_400)))
    }

    @Test("the shipped catalogue names every fixture style's file, listed and computed, upright and italic")
    func shippedMatchesGoogle() throws {
        let shipped = try #require(GoogleFontsCatalog.shipped())
        for row in Self.rows {
            let style = Self.style(row.style)
            let url = try #require(shipped.urls(family: row.family, styles: [style])?[style], "\(row.family) \(row.style)")
            let google = try #require(URL(string: row.url))
            // File IDs outlive font versions, so a refreshed catalogue still matches these rows.
            #expect(url.lastPathComponent == google.lastPathComponent, "\(row.family) \(row.style)")
            #expect(url.pathComponents[2] == google.pathComponents[2])
        }
    }

    /// `shipped.tsv`, written with the shipped catalogue: every family, its version and styles, and the
    /// start of the SHA-256 of its URLs (in the listed style order, newline-separated). The builder
    /// checked each URL against Google's own answer.
    @Test("the shipped catalogue gives every listed family's exact URLs, every style")
    func shippedMatchesListing() throws {
        let shipped = try #require(GoogleFontsCatalog.shipped())
        let lines = String(decoding: Fixtures.data("catalog/shipped.tsv"), as: UTF8.self).split(separator: "\n")
        #expect(lines.count > 1_000)
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            try #require(fields.count == 4, "\(line)")
            let styles = fields[2].split(separator: ",").map { Self.style(String($0)) }
            let urls = try #require(shipped.urls(family: fields[0], styles: styles), "\(fields[0])")
            let listed = styles.map { urls[$0]!.absoluteString }
            #expect(listed.allSatisfy { $0.contains("/v\(fields[1])/") }, "\(fields[0])")
            let digest = SHA256.hash(data: Data(listed.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(digest.hasPrefix(fields[3]), "\(fields[0])")
        }
    }

    @Test("a style a family lacks makes the call miss; unknown names rarely match", arguments: ["Lobster", "Roboto Flex", "Bitcount Ink"])
    func shippedMisses(family: String) throws {
        let shipped = try #require(GoogleFontsCatalog.shipped())
        #expect(shipped.urls(family: family, styles: [FontStyle(weight: 100, italic: true)]) == nil)
        // A 20-bit name hash: an unknown name matches some family about 0.2% of the time (one 404, then CSS2).
        var random = SplitMix64(seed: 0xCA7A)
        let unknown = (0..<2_000).map { _ in String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz ".randomElement(using: &random)! }) }
        #expect(unknown.filter { shipped.urls(family: $0, styles: [.regular]) != nil }.count < 20)
    }

    @Test("the shipped catalogue opens and knows Lobster by its stable file ID")
    func bundled() throws {
        let url = try #require(GoogleFontsCatalog.shipped()?.urls(family: "Lobster", styles: [.regular])?[.regular])
        #expect(url.host == "fonts.gstatic.com")
        #expect(url.path.hasPrefix("/s/lobster/v"))
        #expect(url.lastPathComponent == "neILzCirqoswsqX9_oU.ttf")
    }
}
