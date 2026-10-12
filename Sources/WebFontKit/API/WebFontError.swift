import Foundation

/// Why a font could not be loaded. A cancelled `load` has no entry for the styles it did not finish.
///
/// ```swift
/// switch await WebFonts.shared.load("Lobstr")[.regular] {
/// case .failure(.notFound)?: print("No such family or style")
/// case .failure(.offline)?: print("No network, and nothing on disk")
/// default: break
/// }
/// ```
public enum WebFontError: Error, Sendable, Equatable {
    /// The source has no such family, or no such style of it.
    ///
    /// ```swift
    /// if case .failure(.notFound)? = results["Lobstr"] { print("misspelt") }
    /// ```
    case notFound

    /// There is no network connection, and the font is not on disk.
    ///
    /// ```swift
    /// catch WebFontError.offline { showOfflineBanner() }
    /// ```
    case offline

    /// Not a usable font: rejected by CoreText, over 64 MiB, or no usable file in the CSS.
    ///
    /// ```swift
    /// catch WebFontError.invalidFont { report("bad font file") }
    /// ```
    case invalidFont

    /// Any other network failure, with its `URLError` code, such as a timeout.
    ///
    /// ```swift
    /// catch WebFontError.network(.timedOut) { retryLater() }
    /// ```
    case network(URLError.Code)

    /// An HTTP status that is neither success nor "not found", such as 503 or 429.
    ///
    /// ```swift
    /// catch WebFontError.server(let status) { print("server answered \(status)") }
    /// ```
    case server(statusCode: Int)

    /// A file could not be written, moved or deleted, or a registered file vanished before its first open.
    ///
    /// ```swift
    /// catch WebFontError.storage { freeSomeSpace() }
    /// ```
    case storage
}
