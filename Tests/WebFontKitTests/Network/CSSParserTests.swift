import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct CSSParserTests {
    private func summary(_ css: String) -> [String] {
        CSS2.faces(in: css).map { face in
            "\(face.isItalic ? "italic" : "normal") \(face.weight) \(face.sources.map { "\($0.format ?? "-"):\($0.url)" }.joined(separator: ","))"
        }
    }

    private func gstatic(_ path: String) -> String {
        "truetype:https://fonts.gstatic.com/s/\(path).ttf"
    }

    @Test("every captured answer parses to its faces")
    func capturedFixtures() {
        #expect(summary(Fixtures.css2Text("lobster")) == ["normal 400 \(gstatic("lobster/v32/neILzCirqoswsqX9_oU"))"])
        #expect(summary(Fixtures.css2Text("noto-sans-jp")).count == 1)
        #expect(summary(Fixtures.css2Text("material-symbols-outlined")).count == 1)
        #expect(summary(Fixtures.css2Text("nabla")).count == 1)
        #expect(summary(Fixtures.css2Text("inter-450")).map { $0.prefix(10) } == ["normal 400", "normal 500"])
    }

    @Test("faces come back in Google's order and are matched by style and weight, not position")
    func matchedByStyle() throws {
        let faces = CSS2.faces(in: Fixtures.css2Text("inter-four-styles"))
        #expect(faces.map { "\($0.isItalic ? "i" : "n")\($0.weight)" } == ["i400", "i700", "n400", "n700"])
        let urls = try CSS2.urls(for: [.regular, .bold, .italic, .boldItalic], in: faces)
        #expect(urls[.regular] == URL(string: faces[2].sources[0].url))
        #expect(urls[.boldItalic] == URL(string: faces[1].sources[0].url))
        #expect(urls.count == 4)
    }

    @Test("rules outside @font-face yield no face and no error")
    func otherRulesSkipped() {
        let icon = CSS2.faces(in: Fixtures.css2Text("material-symbols-outlined"))
        #expect(icon.count == 1 && icon[0].weight == 400)
        let colour = CSS2.faces(in: Fixtures.css2Text("nabla"))
        #expect(colour.count == 1)
        #expect(CSS2.faces(in: "body { --google-font-color-nabla:none; }").isEmpty)
    }

    @Test("other properties, comments and whitespace variations are tolerated")
    func tolerance() {
        let css = """
        /* latin */
        @font-face{font-family:'Inter';font-style :  italic ;font-stretch: normal;
          font-display: swap; /* inside */ font-weight:700;
          unicode-range: U+0000-00FF, U+0131;
          src:url(https://fonts.gstatic.com/s/inter/v20/a.ttf)   format( 'truetype' )
        }
        @FONT-FACE {
          font-style: normal;
          font-weight: 400;
          src: url("https://fonts.gstatic.com/s/inter/v20/b.ttf") format("opentype");
        }
        """
        #expect(summary(css) == [
            "italic 700 truetype:https://fonts.gstatic.com/s/inter/v20/a.ttf",
            "normal 400 opentype:https://fonts.gstatic.com/s/inter/v20/b.ttf",
        ])
    }

    @Test("a captured answer with comments and Google's other properties added keeps its faces")
    func editedCapture() {
        let edited = Fixtures.css2Text("inter-four-styles")
            .replacingOccurrences(of: "@font-face {", with: "/* latin */\n@font-face {\n  font-display: swap;\n  font-stretch: normal;")
            .replacingOccurrences(of: "font-weight", with: "unicode-range: U+0000-00FF;\n  font-weight")
        #expect(summary(edited) == summary(Fixtures.css2Text("inter-four-styles")))
    }

    @Test("extra faces are ignored and only requested styles are mapped")
    func extrasIgnored() throws {
        let urls = try CSS2.urls(for: [.regular], in: CSS2.faces(in: Fixtures.css2Text("inter-450")))
        #expect(Array(urls.keys) == [.regular])
    }

    @Test("a partial answer leaves the missing style out")
    func partialAnswer() throws {
        // Google answers `Lobster:wght@400;700` with the regular face alone, byte for byte the plain capture.
        let urls = try CSS2.urls(for: [.regular, .bold], in: CSS2.faces(in: Fixtures.css2Text("lobster")))
        #expect(Array(urls.keys) == [.regular])
    }

    @Test(
        "a face with no TrueType or OpenType file, or a non-https one, makes the answer unusable",
        arguments: [
            ("format('truetype')", "format('woff2')"),
            ("url(https://", "url(http://"),
            ("format('truetype')", ""),
        ]
    )
    func unusable(find: String, replace: String) {
        let css = Fixtures.css2Text("lobster").replacingOccurrences(of: find, with: replace)
        #expect(throws: WebFontError.invalidFont) {
            try CSS2.urls(for: [.regular], in: CSS2.faces(in: css))
        }
    }

    @Test("the two 400 pages are told apart by their titles")
    func titles() {
        #expect(CSS2.title(ofPage: Fixtures.css2("not-found")) == "400: Font family not found")
        #expect(CSS2.title(ofPage: Fixtures.css2("invalid-selector")) == "400: Invalid selector")
        #expect(CSS2.title(ofPage: Data("no title".utf8)) == nil)
    }

    @Test("an HTML page is recognised by its content type or its first character")
    func htmlDetection() {
        #expect(CSS2.looksLikeHTML(.init(statusCode: 200, contentType: "text/html; charset=utf-8", body: Data())))
        #expect(CSS2.looksLikeHTML(.init(statusCode: 200, contentType: nil, body: Data("  <!DOCTYPE html>".utf8))))
        #expect(!CSS2.looksLikeHTML(.init(statusCode: 200, contentType: "text/css", body: Fixtures.css2("lobster"))))
    }

    @Test("weights written as keywords, unknown styles and missing sources")
    func edgeDeclarations() {
        #expect(CSSScanner.face(fromDeclarations: "font-weight: bold; src: url(https://a/b.ttf)")?.weight == 700)
        #expect(CSSScanner.face(fromDeclarations: "font-weight: normal; src: url(https://a/b.ttf)")?.weight == 400)
        #expect(CSSScanner.face(fromDeclarations: "font-style: oblique; src: url(https://a/b.ttf)") == nil)
        #expect(CSSScanner.face(fromDeclarations: "font-weight: 100 900; src: url(https://a/b.ttf)") == nil)
        #expect(CSSScanner.face(fromDeclarations: "font-weight: 400") == nil)
        #expect(CSSScanner.face(fromDeclarations: "src: local(Lobster)") == nil)
        #expect(CSSScanner.source(from: "url() format('truetype')") == nil)
    }
}

extension CSSParserTests {
    @Test("an https scheme in any case is handed out as https, and a URL with no host is refused")
    func schemeCase() throws {
        let css = Fixtures.css2Text("lobster").replacingOccurrences(of: "url(https://", with: "url(HtTpS://")
        let urls = try CSS2.urls(for: [.regular], in: CSS2.faces(in: css))
        #expect(urls[.regular]?.absoluteString == "https://fonts.gstatic.com/s/lobster/v32/neILzCirqoswsqX9_oU.ttf")
        #expect(CSS2.httpsURL("https:///no-host.ttf") == nil)
        #expect(CSS2.httpsURL("ftp://fonts.example.test/a.ttf") == nil)
    }
}
