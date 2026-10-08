import Foundation

/// Fonts you serve yourself from one https folder, named like this:
///
/// | Style | File |
/// |---|---|
/// | regular (400) | `<Family>.ttf` |
/// | bold (700) | `<Family>-Bold.ttf` |
/// | italic (400 italic) | `<Family>-Italic.ttf` |
/// | bold italic (700 italic) | `<Family>-BoldItalic.ttf` |
/// | any other weight | `<Family>-<weight>.ttf`, or `<Family>-<weight>Italic.ttf` |
///
/// A server layout for Inter regular, bold and light italic:
///
/// ```
/// https://cdn.example.com/fonts/Inter.ttf
/// https://cdn.example.com/fonts/Inter-Bold.ttf
/// https://cdn.example.com/fonts/Inter-300Italic.ttf
/// ```
///
/// ```swift
/// WebFonts.shared.configure(.init(source: .hosted(at: URL(string: "https://cdn.example.com/fonts")!)))
/// ```
public struct HostedFontSource: RemoteFontSource {
    let base: URL

    init(base: URL) {
        precondition(Self.isValidBase(base), "HostedFontSource needs an https base URL, got \(base)")
        self.base = base
    }

    /// The request for one face's file.
    ///
    /// ```swift
    /// let request = try await HostedFontSource.hosted(at: base).request(for: FontRequest(family: "Inter", style: .bold))
    /// // https://cdn.example.com/fonts/Inter-Bold.ttf
    /// ```
    public func request(for font: FontRequest) async throws -> URLRequest {
        URLRequest(url: base.appendingPathComponent(Self.fileName(for: font)))
    }

    static func fileName(for font: FontRequest) -> String {
        let suffix: String
        switch (font.style.weight, font.style.isItalic) {
        case (400, false): suffix = ""
        case (700, false): suffix = "-Bold"
        case (400, true): suffix = "-Italic"
        case (700, true): suffix = "-BoldItalic"
        case (let weight, false): suffix = "-\(weight)"
        case (let weight, true): suffix = "-\(weight)Italic"
        }
        return "\(font.family)\(suffix).ttf"
    }

    static func isValidBase(_ base: URL) -> Bool {
        base.scheme?.lowercased() == "https"
    }
}

extension FontSource where Self == HostedFontSource {
    /// Your own https folder of font files. A non-https base is a programming error.
    ///
    /// ```swift
    /// WebFonts.shared.configure(.init(source: .hosted(at: URL(string: "https://cdn.example.com/fonts")!)))
    /// ```
    public static func hosted(at base: URL) -> HostedFontSource {
        HostedFontSource(base: base)
    }
}
