import Foundation
@testable import WebFontKit
import WebFontKitTestSupport

extension Harness {
    /// A fresh, unconfigured instance on this harness's fakes, temporary root and stub session.
    func makeFonts(source: any FontSource = .default, storage: WebFonts.Configuration.Storage = .persistent) -> WebFonts {
        WebFonts(
            configuration: WebFonts.Configuration(source: source, storage: storage, session: session),
            registrar: registrar, fileOperations: files, root: directory.url, logSink: logSink
        )
    }

    /// Records every event an instance emits, from its first access on.
    func listen(to fonts: WebFonts) -> AsyncRecorder<WebFontEvent> {
        let recorder = AsyncRecorder<WebFontEvent>()
        let stream = fonts.events
        Task { for await event in stream { recorder.append(event) } }
        return recorder
    }

    /// Starts the instance's warm-up through `events` and waits for its `.warmedUp`.
    @discardableResult
    func warmUp(_ fonts: WebFonts) async throws -> AsyncRecorder<WebFontEvent> {
        let events = listen(to: fonts)
        try await events.wait { $0.contains { if case .warmedUp = $0 { true } else { false } } }
        return events
    }

    /// Signals each join of shared work, so a test can act only after a call has joined.
    func joins(on fonts: WebFonts) -> AsyncRecorder<String> {
        let joins = AsyncRecorder<String>()
        fonts.hooks.onJoin = { joins.append($0) }
        return joins
    }

    static let interCSS2 = CSS2.url(family: "Inter", styles: [.regular]).absoluteString

    /// Serves Google's real answers for any family and style from the fixtures: Lobster
    /// (regular only) and Inter (the four Lato faces, under gstatic-like URLs).
    func serveGoogle(holdCSS: Bool = false, holdFiles: Bool = false) {
        let lato: [FontStyle: String] = [.regular: Fixtures.latoRegular, .bold: Fixtures.latoBold,
                                          .italic: Fixtures.latoItalic, .boldItalic: Fixtures.latoBoldItalic]
        server.respondToOthers { request in
            let url = request.url!.absoluteString
            if url.hasPrefix("https://fonts.googleapis.com/css2"), let family = URLComponents(string: url)?.queryItems?.first?.value {
                let name = String(family.prefix { $0 != ":" })
                let tuples = family.split(separator: "@").last.map { $0.split(separator: ";") } ?? []
                let styles = tuples.compactMap { tuple -> FontStyle? in
                    let parts = tuple.split(separator: ",")
                    guard parts.count == 2, let weight = Int(parts[1]) else { return nil }
                    return FontStyle(weight: weight, italic: parts[0] == "1")
                }
                var blocks: [String] = []
                for style in styles {
                    let exists = name == "Inter" ? lato[style] != nil : (name == "Lobster" && style == .regular)
                    guard exists else { continue }
                    let file = "https://fonts.gstatic.com/s/\(name.lowercased())/v1/\(style.weight)\(style.isItalic ? "i" : "n").ttf"
                    blocks.append("@font-face {\n  font-family: '\(name)';\n  font-style: \(style.isItalic ? "italic" : "normal");\n  font-weight: \(style.weight);\n  src: url(\(file)) format('truetype');\n}")
                }
                if blocks.isEmpty {
                    return StubResponse(statusCode: 400, headers: ["Content-Type": "text/html"], body: Fixtures.css2("not-found"))
                }
                return .css(blocks.joined(separator: "\n"), hold: holdCSS ? .beforeResponse : .none)
            }
            if url.hasPrefix("https://fonts.gstatic.com/s/lobster/") {
                return .font(Fixtures.data(Fixtures.lobster), hold: holdFiles ? .beforeResponse : .none)
            }
            if url.hasPrefix("https://fonts.gstatic.com/s/inter/v1/"), let style = lato.keys.first(where: { url.hasSuffix("/\($0.weight)\($0.isItalic ? "i" : "n").ttf") }) {
                return .font(Fixtures.data(lato[style]!), hold: holdFiles ? .beforeResponse : .none)
            }
            return StubResponse(statusCode: 404)
        }
    }

    func isCSS2(_ url: URL) -> Bool { url.host == "fonts.googleapis.com" }
    func isFontFile(_ url: URL) -> Bool { url.host == "fonts.gstatic.com" }

    var css2Requests: Int { server.requests.count { isCSS2($0.url) } }
    var fileRequests: Int { server.requests.count { isFontFile($0.url) } }
}
