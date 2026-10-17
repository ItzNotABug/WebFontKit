/// The outcome of one family's `load`, per style, in the order asked.
///
/// ```swift
/// let results = await WebFonts.shared.load("Lobster", styles: [.regular, .bold])
/// for (style, result) in results { print(style, result) }
/// ```
public struct FontStyleResults: Sequence, Sendable {
    /// One style and how its load ended.
    ///
    /// ```swift
    /// for (style, result) in results where (try? result.get()) == nil { print("failed", style) }
    /// ```
    public typealias Element = (style: FontStyle, result: Result<Void, WebFontError>)

    private let entries: [Element]
    /// Distinct styles asked for; a cancelled load has no entries.
    private let expected: Int

    init(_ entries: [Element], expected: Int) {
        self.entries = entries
        self.expected = expected
    }

    /// True when every style asked for loaded.
    ///
    /// ```swift
    /// if !results.allSucceeded { print(results.failed) }
    /// ```
    public var allSucceeded: Bool {
        entries.allSatisfy { if case .success = $0.result { true } else { false } }
            && entries.count == expected
    }

    /// The styles that loaded, in the order asked.
    ///
    /// ```swift
    /// print(results.succeeded) // [FontStyle.regular]
    /// ```
    public var succeeded: [FontStyle] {
        entries.compactMap { if case .success = $0.result { $0.style } else { nil } }
    }

    /// The styles that failed, with their errors, in the order asked.
    ///
    /// ```swift
    /// for (style, error) in results.failed { print(style, error) }
    /// ```
    public var failed: [(style: FontStyle, error: WebFontError)] {
        entries.compactMap { if case .failure(let error) = $0.result { ($0.style, error) } else { nil } }
    }

    /// Iterates the styles in the order asked.
    ///
    /// ```swift
    /// for (style, result) in results { print(style, result) }
    /// ```
    public func makeIterator() -> IndexingIterator<[Element]> {
        entries.makeIterator()
    }

    /// The result for one style, or nil if it was not asked for or the load was cancelled or overtaken by `remove`.
    ///
    /// ```swift
    /// if case .failure(.notFound)? = results[.bold] { print("no bold face") }
    /// ```
    public subscript(_ style: FontStyle) -> Result<Void, WebFontError>? {
        entries.first { $0.style == style }?.result
    }
}
