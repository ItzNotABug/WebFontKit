#if DEBUG
import Foundation
import WebFontKit

extension StubServer {
    /// Answers CSS2 and gstatic requests from the fixtures: Lobster (regular only), and
    /// Inter as the four Lato faces. Any other family gets Google's 400 page.
    public func serveGoogle(holdCSS: Bool = false, holdFiles: Bool = false) {
        let lato: [FontStyle: String] = [.regular: Fixtures.latoRegular, .bold: Fixtures.latoBold,
                                          .italic: Fixtures.latoItalic, .boldItalic: Fixtures.latoBoldItalic]
        respondToOthers { request in
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
}
#endif
