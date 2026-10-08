import Foundation

/// Google Fonts, through the keyless CSS2 API. Each download sends the user's IP address to Google.
///
/// ```swift
/// WebFonts.shared.configure(.init(source: .default))
/// ```
public struct DefaultFontSource: FontSource {
    /// Fetches one face into memory, for direct callers. WebFontKit never calls it.
    ///
    /// ```swift
    /// let bytes = try await DefaultFontSource.default.fetch(FontRequest(family: "Lobster"))
    /// ```
    public func fetch(_ font: FontRequest) async throws -> Data {
        try await fetch(font, session: LibrarySession.shared)
    }

    @concurrent
    func fetch(_ font: FontRequest, session: URLSession, logSink: any LogSink = .logger) async throws -> Data {
        let urls = try await CSS2.resolve(family: font.family, styles: [font.style], session: session, logSink: logSink)
        guard let url = urls[font.style] else { throw WebFontError.notFound }
        return try await Downloader.data(for: CSS2.request(for: url), session: session)
    }
}

extension FontSource where Self == DefaultFontSource {
    /// Google Fonts: the source used unless you configure another.
    ///
    /// ```swift
    /// WebFonts.shared.configure(.init(source: .default, storage: .persistent))
    /// ```
    public static var `default`: DefaultFontSource { DefaultFontSource() }
}
