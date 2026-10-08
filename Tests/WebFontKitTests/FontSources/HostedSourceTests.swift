import Foundation
import Testing
@testable import WebFontKit

@Suite(.timeLimit(.minutes(1)))
struct HostedSourceTests {
    static let allStyles: [FontStyle] = [false, true].flatMap { italic in
        stride(from: 100, through: 900, by: 100).map { FontStyle(weight: $0, italic: italic) }
    }

    private let base = URL(string: "https://cdn.example.com/fonts")!

    @Test(
        "the naming rule",
        arguments: [
            (FontStyle.regular, "Inter.ttf"), (.bold, "Inter-Bold.ttf"), (.italic, "Inter-Italic.ttf"),
            (.boldItalic, "Inter-BoldItalic.ttf"), (FontStyle(weight: 300), "Inter-300.ttf"),
            (FontStyle(weight: 300, italic: true), "Inter-300Italic.ttf"), (FontStyle(weight: 900), "Inter-900.ttf"),
        ]
    )
    func naming(style: FontStyle, file: String) async throws {
        let request = try await HostedFontSource.hosted(at: base).request(for: FontRequest(family: "Inter", style: style))
        #expect(request.url?.absoluteString == "https://cdn.example.com/fonts/\(file)")
    }

    @Test("all 18 styles give distinct URLs")
    func distinct() async throws {
        let source: any RemoteFontSource = .hosted(at: base)
        var urls: Set<URL> = []
        for style in Self.allStyles {
            urls.insert(try #require(try await source.request(for: FontRequest(family: "Inter", style: style)).url))
        }
        #expect(urls.count == 18)
    }

    @Test("spaces are sent as %20")
    func spaces() async throws {
        let request = try await HostedFontSource.hosted(at: base).request(for: FontRequest(family: "Bebas Neue"))
        #expect(request.url?.absoluteString == "https://cdn.example.com/fonts/Bebas%20Neue.ttf")
    }

    @Test("only an https base passes the check the precondition calls")
    func basePredicate() {
        #expect(HostedFontSource.isValidBase(base))
        #expect(!HostedFontSource.isValidBase(URL(string: "http://cdn.example.com/fonts")!))
        #expect(!HostedFontSource.isValidBase(URL(fileURLWithPath: "/tmp/fonts")))
    }

    #if os(macOS)
    @Test("an http base stops the program")
    func httpBaseTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = HostedFontSource.hosted(at: URL(string: "http://cdn.example.com/fonts")!)
        }
    }
    #endif

    @Test("the hosted source uses the default cache key")
    func cacheKey() {
        let source: any FontSource = .hosted(at: base)
        #expect(source.cacheKey(for: FontRequest(family: "Inter", style: .bold)) == "Inter|700|n")
    }
}
