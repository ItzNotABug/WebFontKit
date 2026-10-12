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
        try await fetch(font, session: LibrarySession.shared, catalog: GoogleFontsCatalog.bundled)
    }

    /// The catalogued file when there is one, as a load does; one Google reports gone falls back to CSS2.
    @concurrent
    func fetch(_ font: FontRequest, session: URLSession, logSink: any LogSink = .logger,
               catalog: GoogleFontsCatalog? = nil) async throws -> Data {
        if let url = catalog?.urls(family: font.family, styles: [font.style])?[font.style] {
            do {
                return try await Downloader.data(for: CSS2.request(for: url), session: session)
            } catch let error as WebFontError where error.meansGone {
                let face = FaceKey(family: font.family, style: font.style)
                logSink.log("source", .info, "The catalogued URL for \(face) failed (\(error)); asking CSS2")
            }
        }
        let url = try await CSS2.resolve(family: font.family, style: font.style, session: session, logSink: logSink)
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
