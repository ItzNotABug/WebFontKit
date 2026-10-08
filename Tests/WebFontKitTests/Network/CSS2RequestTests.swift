import Foundation
import Testing
@testable import WebFontKit

@Suite(.timeLimit(.minutes(1)))
struct CSS2RequestTests {
    private func query(_ family: String, _ styles: [FontStyle]) -> String {
        CSS2.url(family: family, styles: styles).query ?? ""
    }

    @Test("every request names exactly one family")
    func oneFamily() throws {
        let url = CSS2.url(family: "Inter", styles: [.regular, .bold])
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["family"])
        #expect(url.absoluteString.hasPrefix("https://fonts.googleapis.com/css2?"))
    }

    @Test(
        "family names with spaces and digits encode as URLComponents writes them",
        arguments: [
            ("Bebas Neue", FontStyle.boldItalic, "family=Bebas%20Neue:ital,wght@1,700"),
            ("Noto Sans JP", .regular, "family=Noto%20Sans%20JP:ital,wght@0,400"),
            ("Baloo 2", .bold, "family=Baloo%202:ital,wght@0,700"),
            ("Press Start 2P", .regular, "family=Press%20Start%202P:ital,wght@0,400"),
        ]
    )
    func encoding(family: String, style: FontStyle, expected: String) {
        #expect(query(family, [style]) == expected)
    }

    @Test("an apostrophe and non-ASCII letters percent-encode without crashing")
    func defensiveEncoding() {
        let url = CSS2.url(family: "Ünïcode's Font", styles: [.regular])
        #expect(!url.absoluteString.contains(" "))
        #expect(url.absoluteString.contains("%C3%9C"))
    }

    @Test("the family's case is passed through unchanged")
    func casePassesThrough() {
        #expect(query("lobster", [.regular]) == "family=lobster:ital,wght@0,400")
        #expect(query("LOBSTER", [.regular]) == "family=LOBSTER:ital,wght@0,400")
    }

    @Test(
        "tuples are de-duplicated and sorted by (ital, wght), with both axes always written",
        arguments: [
            ([FontStyle.regular], "0,400"),
            ([.boldItalic, .bold, .italic, .regular], "0,400;0,700;1,400;1,700"),
            ([.regular, FontStyle(weight: 400), .regular], "0,400"),
            ([FontStyle(weight: 900, italic: true), FontStyle(weight: 100), FontStyle(weight: 300, italic: true)], "0,100;1,300;1,900"),
        ]
    )
    func canonicalTuples(styles: [FontStyle], tuples: String) {
        let text = query("Inter", styles)
        #expect(text == "family=Inter:ital,wght@\(tuples)")
        #expect(!text.contains(".0"))
        #expect(!text.contains(".."))
    }

    @Test("every request carries the library's User-Agent and ignores cached answers")
    func headers() {
        let request = CSS2.request(for: CSS2.url(family: "Lobster", styles: [.regular]))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "WebFontKit/" + WebFontKit.libraryVersion)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("the vNN version is read from a gstatic URL")
    func version() {
        #expect(CSS2.version(of: URL(string: "https://fonts.gstatic.com/s/lobster/v32/neILzCirqoswsqX9_oU.ttf")!) == "v32")
        #expect(CSS2.version(of: URL(string: "https://cdn.example.com/fonts/Lobster.ttf")!) == nil)
        #expect(CSS2.version(of: URL(string: "https://cdn.example.com/v/Lobster.ttf")!) == nil)
    }
}
