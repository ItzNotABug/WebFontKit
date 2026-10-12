import CryptoKit
import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct GoogleFontsCatalogTests {
    /// Real Google rows for 25 families, plus one left to CSS2 (no URL), and the catalogue built from them.
    static let rows: [(family: String, style: String, url: String)] = {
        let raw = try! JSONSerialization.jsonObject(with: Fixtures.data("catalog/rows.json")) as! [[String]]
        return raw.map { ($0[0], $0[1], $0[2]) }
    }()
    static let catalog = GoogleFontsCatalog(data: Fixtures.data("catalog/sample.catalog"))!

    static func style(_ code: String) -> FontStyle {
        FontStyle(weight: Int(code.filter(\.isNumber))!, italic: code.hasSuffix("i"))
    }

    /// `shipped.tsv`: each shipped family's version, styles and a digest of its URLs (see SOURCES.md).
    static let listing: [(family: String, version: String, styles: [FontStyle], digest: String)] = {
        String(decoding: Fixtures.data("catalog/shipped.tsv"), as: UTF8.self).split(separator: "\n").map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            precondition(fields.count == 4, "\(line)")
            return (fields[0], fields[1], fields[2].split(separator: ",").map { style(String($0)) }, fields[3])
        }
    }()

    static let allStyles = [false, true].flatMap { italic in
        stride(from: 100, through: 900, by: 100).map { FontStyle(weight: $0, italic: italic) }
    }

    static let formatTwoShipped = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!

    @Test("every style decodes to exactly Google's URL: listed, computed, upright and italic")
    func everyRowMatchesGoogle() {
        for row in Self.rows {
            let style = Self.style(row.style)
            let url = Self.catalog.urls(family: row.family, styles: [style])?[style]?.absoluteString
            #expect(url == (row.url.isEmpty ? nil : row.url), "\(row.family) \(row.style)")
        }
    }

    @Test("a call gets all its styles, or nil when any is missing")
    func allOrNothing() {
        let urls = Self.catalog.urls(family: "Lato", styles: [.regular, .bold, .italic, .boldItalic])
        #expect(urls?.count == 4)
        #expect(Self.catalog.urls(family: "Lobster", styles: [.regular, .bold]) == nil)
    }

    /// "Zz Cbsq" is left to CSS2, and its hash meets ABeeZee's at seed 0: the sample's seed must keep them apart.
    @Test("names the sample doesn't hold miss", arguments: ["Lobstr", "lobster", "", "Zzzz Unknown", "Zz Cbsq"])
    func misses(family: String) {
        #expect(Self.catalog.urls(family: family, styles: [.regular]) == nil)
    }

    @Test("a wrong header is rejected; damaged sections never crash or hang")
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
            for _ in 0..<4 {
                damaged[Int.random(in: 56..<damaged.count, using: &random)] = .random(in: 0...255, using: &random)
            }
            let cut = damaged.prefix(Int.random(in: 0...damaged.count, using: &random))
            for data in [damaged, Data(cut)] {
                guard let catalog = GoogleFontsCatalog(data: data) else { continue }
                for family in ["Lobster", "Inter", "Lato", "Roboto"] {
                    _ = catalog.urls(family: family, styles: [.regular, .bold, .italic])
                }
            }
        }
    }

    /// Random damage rarely leaves a header that still validates, so each field byte is set to extremes in turn.
    @Test("any one header byte at an extreme never crashes or hangs", arguments: 5..<56)
    func damagedHeader(at offset: Int) {
        for value: UInt8 in [0, 1, 0x7F, 0x80, 0xFF] {
            var damaged = Fixtures.data("catalog/sample.catalog")
            damaged[offset] = value
            guard let catalog = GoogleFontsCatalog(data: damaged) else { continue }
            for family in ["Lobster", "Inter", "Lato", "Roboto"] {
                _ = catalog.urls(family: family, styles: [.regular, .bold, .italic])
            }
        }
    }

    @Test("a catalogue is used for a year after it was built, then left to CSS2")
    func expiry() {
        let built = Self.catalog.built
        #expect(Self.catalog.isCurrent(at: built.addingTimeInterval(365 * 86_400 - 1)))
        #expect(!Self.catalog.isCurrent(at: built.addingTimeInterval(365 * 86_400)))
    }

    /// A misread build day would date the file decades back (never used) or ahead (never expiring).
    @Test("the build day reads as a date between format 2's release and now")
    func buildDay() throws {
        let shipped = try #require(GoogleFontsCatalog.shipped())
        for built in [Self.catalog.built, shipped.built] {
            #expect(built >= Self.formatTwoShipped && built <= .now, "\(built)")
        }
    }

    @Test("the shipped catalogue names every fixture style's file, listed and computed, upright and italic")
    func shippedMatchesGoogle() throws {
        let shipped = try #require(GoogleFontsCatalog.shipped())
        for row in Self.rows where !row.url.isEmpty {
            let style = Self.style(row.style)
            let url = try #require(shipped.urls(family: row.family, styles: [style])?[style],
                                   "\(row.family) \(row.style)")
            let google = try #require(URL(string: row.url))
            #expect(url.pathComponents[2] == google.pathComponents[2], "\(row.family) \(row.style) folder")
            // A refreshed catalogue may hold a newer version, whose IDs can differ; within one, they can't.
            if url.pathComponents[3] == google.pathComponents[3] {
                #expect(url.lastPathComponent == google.lastPathComponent, "\(row.family) \(row.style)")
            }
        }
    }

    @Test("the shipped catalogue gives every listed family's exact URLs, every style")
    func shippedMatchesListing() throws {
        let shipped = try #require(GoogleFontsCatalog.shipped())
        #expect(Self.listing.count == shipped.familyCount)
        #expect(Set(Self.listing.map(\.family)).count == Self.listing.count)
        for entry in Self.listing {
            let urls = try #require(shipped.urls(family: entry.family, styles: entry.styles), "\(entry.family)")
            let listed = try entry.styles.map { try #require(urls[$0], "\(entry.family)").absoluteString }
            #expect(listed.allSatisfy { $0.contains("/v\(entry.version)/") }, "\(entry.family)")
            let digest = SHA256.hash(data: Data(listed.joined(separator: "\n").utf8))
                .map { String(format: "%02x", $0) }.joined()
            #expect(digest.hasPrefix(entry.digest), "\(entry.family)")
        }
    }

    /// Asked one at a time, a listed style gets the URL it gets among all of them; any other style misses,
    /// alone or beside styles the family has.
    @Test("every shipped family answers each style alone", arguments: 0..<4)
    func shippedStyleByStyle(quarter: Int) throws {
        let shipped = try #require(GoogleFontsCatalog.shipped())
        for (index, entry) in Self.listing.enumerated() where index % 4 == quarter {
            let urls = try #require(shipped.urls(family: entry.family, styles: entry.styles), "\(entry.family)")
            for style in Self.allStyles {
                let alone = shipped.urls(family: entry.family, styles: [style])?[style]
                #expect(alone == urls[style], "\(entry.family) \(style)")
            }
            let hasAll = entry.styles.count == Self.allStyles.count
            #expect((shipped.urls(family: entry.family, styles: Self.allStyles) != nil) == hasAll, "\(entry.family)")
        }
    }

    @Test("a style a family lacks makes the call miss", arguments: ["Lobster", "Roboto Flex", "Bitcount Ink"])
    func shippedMisses(family: String) throws {
        let shipped = try #require(GoogleFontsCatalog.shipped())
        #expect(shipped.urls(family: family, styles: [FontStyle(weight: 100, italic: true)]) == nil)
    }

    @Test("unknown names rarely match a shipped family")
    func shippedUnknownNames() throws {
        let shipped = try #require(GoogleFontsCatalog.shipped())
        // A 20-bit name hash: an unknown name matches some family about 0.2% of the time (one 404, then CSS2).
        var random = SplitMix64(seed: 0xCA7A)
        let letters = "abcdefghijklmnopqrstuvwxyz "
        let unknown = (0..<2_000).map { _ in String((0..<12).map { _ in letters.randomElement(using: &random)! }) }
        #expect(unknown.filter { shipped.urls(family: $0, styles: [.regular]) != nil }.count < 20)
    }
}
