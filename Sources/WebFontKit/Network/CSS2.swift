import Foundation
import OSLog

/// Google's CSS2 API: the one request per family, and reading its answer.
enum CSS2 {
    static let endpoint = URL(string: "https://fonts.googleapis.com/css2")!
    /// Where Google serves font files: `<folder>/v<version>/<file ID>.ttf`.
    static let files = URL(string: "https://fonts.gstatic.com/s")!

    static let responseCap = 1024 * 1024

    /// Tuples de-duplicated and sorted, weights as plain integers: Google rejects anything else.
    static func url(family: String, styles: [FontStyle]) -> URL {
        let tuples = Set(styles).sorted(by: FontStyle.canonicalOrder)
            .map { "\($0.isItalic ? 1 : 0),\($0.weight)" }
            .joined(separator: ";")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "family", value: "\(family):ital,wght@\(tuples)")]
        return components.url!
    }

    /// Google's CSS is cached without varying by user agent, so never send a browser's or read a cached answer.
    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(libraryUserAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    static func version(of url: URL) -> String? {
        url.pathComponents.first { component in
            component.count > 1 && component.first == "v" && component.dropFirst().allSatisfy(\.isASCIIDigit)
        }
    }

    static func faces(in css: String) -> [CSSFace] {
        var scanner = CSSScanner(css)
        return scanner.fontFaces()
    }

    /// A missing style is left out; a present one with no https TrueType/OpenType file is `.invalidFont`.
    static func urls(for styles: [FontStyle], in faces: [CSSFace]) throws(WebFontError) -> [FontStyle: URL] {
        var result: [FontStyle: URL] = [:]
        for style in Set(styles) {
            let matching = faces.filter { $0.weight == style.weight && $0.isItalic == style.isItalic }
            guard !matching.isEmpty else { continue }
            let usable = matching.lazy.flatMap(\.sources).compactMap { source -> URL? in
                guard let format = source.format?.lowercased(), format == "truetype" || format == "opentype" else {
                    return nil
                }
                return httpsURL(source.url)
            }.first
            guard let usable else { throw .invalidFont }
            result[style] = usable
        }
        return result
    }

    static func httpsURL(_ text: String) -> URL? {
        guard var components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false
        else { return nil }
        components.scheme = "https"
        return components.url
    }

    static func title(ofPage body: Data) -> String? {
        let text = String(decoding: body, as: UTF8.self)
        guard let start = text.range(of: "<title>", options: .caseInsensitive),
              let end = text.range(of: "</title>", options: .caseInsensitive, range: start.upperBound..<text.endIndex)
        else { return nil }
        return text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func looksLikeHTML(_ response: Downloader.Response) -> Bool {
        if response.contentType?.lowercased().contains("text/html") == true { return true }
        let prefix = String(decoding: response.body.prefix(64), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.hasPrefix("<")
    }

    /// One style's file URL; `.notFound` when the answer doesn't list it.
    @concurrent
    static func resolve(family: String, style: FontStyle, session: URLSession, logSink: any LogSink) async throws -> URL {
        guard let url = try await resolve(family: family, styles: [style], session: session, logSink: logSink)[style]
        else { throw WebFontError.notFound }
        return url
    }

    @concurrent
    static func resolve(
        family: String,
        styles: [FontStyle],
        session: URLSession,
        logSink: any LogSink
    ) async throws -> [FontStyle: URL] {
        let request = request(for: url(family: family, styles: styles))
        let response = try await Downloader.response(for: request, session: session, cap: responseCap)
        switch response.statusCode {
        case 200..<300:
            guard !looksLikeHTML(response) else { throw WebFontError.invalidFont }
            return try urls(for: styles, in: faces(in: String(decoding: response.body, as: UTF8.self)))
        case 400:
            if title(ofPage: response.body) == "400: Invalid selector" {
                logSink.log("source", .fault, "CSS2 answered \"Invalid selector\" for \(family): the request was malformed",
                            private: [request.url?.absoluteString ?? ""])
                throw WebFontError.server(statusCode: 400)
            }
            throw WebFontError.notFound
        default:
            throw ErrorMapping.map(status: response.statusCode)
        }
    }
}

/// One `@font-face` block of a CSS2 answer.
struct CSSFace: Equatable, Sendable {
    struct Source: Equatable, Sendable {
        var url: String
        var format: String?
    }

    var isItalic: Bool
    var weight: Int
    var sources: [Source]
}

/// Never fails; anything unreadable is skipped.
struct CSSScanner {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    mutating func fontFaces() -> [CSSFace] {
        var faces: [CSSFace] = []
        while index < scalars.count {
            let prelude = readPrelude()
            guard index < scalars.count, scalars[index] == "{" else { break }
            index += 1
            let body = readBlock()
            if prelude.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "@font-face",
               let face = Self.face(fromDeclarations: body) {
                faces.append(face)
            }
        }
        return faces
    }

    private mutating func readPrelude() -> String {
        var text = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            if skipComment() { continue }
            if scalar == "{" { return String(text) }
            if scalar == ";" || scalar == "}" {
                text.removeAll()
                index += 1
                continue
            }
            if scalar == "\"" || scalar == "'" {
                text.append(contentsOf: readString().unicodeScalars)
                continue
            }
            text.append(scalar)
            index += 1
        }
        return String(text)
    }

    private mutating func readBlock() -> String {
        var text = String.UnicodeScalarView()
        var depth = 1
        while index < scalars.count {
            if skipComment() { continue }
            let scalar = scalars[index]
            if scalar == "\"" || scalar == "'" {
                text.append(contentsOf: readString().unicodeScalars)
                continue
            }
            index += 1
            if scalar == "{" { depth += 1 }
            if scalar == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            text.append(scalar)
        }
        return String(text)
    }

    private mutating func readString() -> String {
        let quote = scalars[index]
        var text = String.UnicodeScalarView([quote])
        index += 1
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            text.append(scalar)
            if scalar == "\\", index < scalars.count {
                text.append(scalars[index])
                index += 1
                continue
            }
            if scalar == quote { break }
        }
        return String(text)
    }

    private mutating func skipComment() -> Bool {
        guard index + 1 < scalars.count, scalars[index] == "/", scalars[index + 1] == "*" else { return false }
        index += 2
        while index < scalars.count {
            if scalars[index] == "*", index + 1 < scalars.count, scalars[index + 1] == "/" {
                index += 2
                return true
            }
            index += 1
        }
        return true
    }

    static func face(fromDeclarations body: String) -> CSSFace? {
        var style: String?
        var weight: String?
        var src: String?
        for declaration in splitTopLevel(body, separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "font-style": style = value.lowercased()
            case "font-weight": weight = value.lowercased()
            case "src": src = value
            default: continue
            }
        }
        guard let src else { return nil }
        let isItalic: Bool
        switch style ?? "normal" {
        case "normal": isItalic = false
        case "italic": isItalic = true
        default: return nil
        }
        let weightValue: Int
        switch weight ?? "400" {
        case "normal": weightValue = 400
        case "bold": weightValue = 700
        case let text:
            guard let number = Int(text) else { return nil }
            weightValue = number
        }
        let sources = splitTopLevel(src, separator: ",").compactMap(source(from:))
        guard !sources.isEmpty else { return nil }
        return CSSFace(isItalic: isItalic, weight: weightValue, sources: sources)
    }

    static func source(from entry: String) -> CSSFace.Source? {
        let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("url("), let close = text.firstIndex(of: ")") else { return nil }
        let url = unquote(String(text[text.index(text.startIndex, offsetBy: 4)..<close]))
        guard !url.isEmpty else { return nil }
        var format: String?
        let rest = text[text.index(after: close)...]
        if let open = rest.range(of: "format(", options: .caseInsensitive),
           let end = rest[open.upperBound...].firstIndex(of: ")") {
            format = unquote(String(rest[open.upperBound..<end]))
        }
        return CSSFace.Source(url: url, format: format)
    }

    private static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, let first = value.first, first == "'" || first == "\"", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "'", "\"": quote = character
            case "(": depth += 1
            case ")": depth = max(0, depth - 1)
            case separator where depth == 0:
                parts.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        parts.append(current)
        return parts
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
