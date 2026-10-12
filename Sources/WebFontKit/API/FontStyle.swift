/// A weight and whether it is italic. iOS never synthesises bold or italic, so load what you draw.
///
/// ```swift
/// await WebFonts.shared.load("Inter", styles: [.regular, .bold, FontStyle(weight: 300)])
/// ```
public struct FontStyle: Hashable, Sendable {
    /// The weight, from 100 to 900 in steps of 100 (400 is regular, 700 is bold).
    ///
    /// ```swift
    /// let semibold = FontStyle(weight: 600)
    /// print(semibold.weight) // 600
    /// ```
    public let weight: Int

    /// Whether the face is italic.
    ///
    /// ```swift
    /// print(FontStyle.boldItalic.isItalic) // true
    /// ```
    public let isItalic: Bool

    /// Creates a style. The weight must be a multiple of 100 from 100 to 900; any other traps.
    ///
    /// ```swift
    /// let lightItalic = FontStyle(weight: 300, italic: true)
    /// ```
    public init(weight: Int = 400, italic: Bool = false) {
        precondition(
            Self.isValidWeight(weight),
            "FontStyle weight must be a multiple of 100 from 100 to 900, got \(weight)"
        )
        self.weight = weight
        self.isItalic = italic
    }

    /// Weight 400, upright.
    ///
    /// ```swift
    /// await WebFonts.shared.load("Lobster", styles: [.regular])
    /// ```
    public static let regular = FontStyle(weight: 400)

    /// Weight 700, upright.
    ///
    /// ```swift
    /// await WebFonts.shared.load("Inter", styles: [.bold])
    /// ```
    public static let bold = FontStyle(weight: 700)

    /// Weight 400, italic.
    ///
    /// ```swift
    /// await WebFonts.shared.load("Inter", styles: [.italic])
    /// ```
    public static let italic = FontStyle(weight: 400, italic: true)

    /// Weight 700, italic.
    ///
    /// ```swift
    /// await WebFonts.shared.load("Inter", styles: [.boldItalic])
    /// ```
    public static let boldItalic = FontStyle(weight: 700, italic: true)

    static func isValidWeight(_ weight: Int) -> Bool {
        (100...900).contains(weight) && weight % 100 == 0
    }

    /// The order the CSS2 API requires for tuples: upright before italic, then by weight.
    static func canonicalOrder(_ lhs: FontStyle, _ rhs: FontStyle) -> Bool {
        (lhs.isItalic ? 1 : 0, lhs.weight) < (rhs.isItalic ? 1 : 0, rhs.weight)
    }
}

/// One face a source is asked for.
///
/// ```swift
/// struct MyServer: RemoteFontSource {
///     func request(for font: FontRequest) async throws -> URLRequest {
///         URLRequest(url: URL(string: "https://fonts.example.com/\(font.family)/\(font.style.weight).ttf")!)
///     }
/// }
/// ```
public struct FontRequest: Hashable, Sendable {
    /// The family name, exactly as passed to `load`; names are case-sensitive.
    ///
    /// ```swift
    /// FontRequest(family: "Bebas Neue").family // "Bebas Neue"
    /// ```
    public let family: String

    /// The face of the family.
    ///
    /// ```swift
    /// FontRequest(family: "Inter", style: .bold).style.weight // 700
    /// ```
    public let style: FontStyle

    /// Creates a request for one face.
    ///
    /// ```swift
    /// let request = FontRequest(family: "Inter", style: FontStyle(weight: 300, italic: true))
    /// ```
    public init(family: String, style: FontStyle = .regular) {
        self.family = family
        self.style = style
    }
}
