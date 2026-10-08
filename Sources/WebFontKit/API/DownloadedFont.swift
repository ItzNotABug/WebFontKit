import Foundation

/// A face WebFontKit has stored and registered, as listed by `WebFonts.shared.downloaded`.
///
/// Its PostScript name is the exact way to reach the face through Apple's APIs;
/// lookup by family name is reliable only for regular, bold, italic and bold italic.
///
/// ```swift
/// for font in WebFonts.shared.downloaded {
///     label.font = UIFont(name: font.postScriptName, size: 17)
/// }
/// ```
public struct DownloadedFont: Hashable, Sendable {
    /// The family name the face was loaded as.
    ///
    /// ```swift
    /// let families = Set(WebFonts.shared.downloaded.map(\.family))
    /// ```
    public let family: String

    /// The style the face was loaded as.
    ///
    /// ```swift
    /// let bold = WebFonts.shared.downloaded.filter { $0.style == .bold }
    /// ```
    public let style: FontStyle

    /// The face's PostScript name, which reaches exactly this face.
    ///
    /// ```swift
    /// Text("Hello").font(.custom(font.postScriptName, size: 24))
    /// ```
    public let postScriptName: String

    /// The size of the stored file, in bytes.
    ///
    /// ```swift
    /// let total = WebFonts.shared.downloaded.reduce(0) { $0 + $1.byteCount }
    /// ```
    public let byteCount: Int

    /// When the file was stored.
    ///
    /// ```swift
    /// let old = WebFonts.shared.downloaded.filter { $0.downloadedAt < cutoff }
    /// ```
    public let downloadedAt: Date
}
