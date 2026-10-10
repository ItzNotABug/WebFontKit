import Foundation

/// Where fonts come from. Throw ``WebFontError/notFound`` for a face you don't have.
///
/// ```swift
/// struct MyClient: FontSource {
///     func fetch(_ font: FontRequest) async throws -> Data {
///         try await myAPI.fontData(family: font.family, weight: font.style.weight)
///     }
/// }
/// WebFonts.shared.configure(.init(source: MyClient()))
/// ```
public protocol FontSource: Sendable {
    /// One face's bytes: TrueType, OpenType, WOFF or WOFF2.
    ///
    /// ```swift
    /// func fetch(_ font: FontRequest) async throws -> Data {
    ///     try await storage.download("fonts/\(font.family)-\(font.style.weight).ttf")
    /// }
    /// ```
    func fetch(_ font: FontRequest) async throws -> Data

    /// Names the file's version; when it changes, the next `load` replaces the stored file.
    ///
    /// ```swift
    /// func cacheKey(for font: FontRequest) -> String { "\(font.family)-v32" }
    /// ```
    func cacheKey(for font: FontRequest) -> String
}

extension FontSource {
    /// `<family>|<weight>|<n or i>`: no version, so a stored file is kept.
    ///
    /// ```swift
    /// MyClient().cacheKey(for: FontRequest(family: "Lobster")) // "Lobster|400|n"
    /// ```
    public func cacheKey(for font: FontRequest) -> String {
        "\(font.family)|\(font.style.weight)|\(font.style.isItalic ? "i" : "n")"
    }
}

/// A source that gives an https request per face; WebFontKit downloads it to disk.
///
/// ```swift
/// struct MyServer: RemoteFontSource {
///     let token: String
///     func request(for font: FontRequest) async throws -> URLRequest {
///         var request = URLRequest(url: URL(string: "https://fonts.example.com/\(font.family).ttf")!)
///         request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
///         return request
///     }
/// }
/// ```
public protocol RemoteFontSource: FontSource {
    /// The https request for one face.
    ///
    /// ```swift
    /// func request(for font: FontRequest) async throws -> URLRequest {
    ///     URLRequest(url: base.appending(path: "\(font.family)-\(font.style.weight).ttf"))
    /// }
    /// ```
    func request(for font: FontRequest) async throws -> URLRequest
}

extension RemoteFontSource {
    /// Downloads ``request(for:)`` into memory, for direct callers. WebFontKit never calls it.
    ///
    /// ```swift
    /// let bytes = try await MyServer(token: token).fetch(FontRequest(family: "Lobster"))
    /// ```
    public func fetch(_ font: FontRequest) async throws -> Data {
        try await fetch(request: font, session: .shared)
    }

    @concurrent
    func fetch(request font: FontRequest, session: URLSession) async throws -> Data {
        let request = try await request(for: font)
        guard request.url?.scheme?.lowercased() == "https" else { throw WebFontError.invalidFont }
        return try await Downloader.data(for: request, session: session)
    }
}
