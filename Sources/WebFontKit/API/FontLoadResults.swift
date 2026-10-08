/// The outcome of a batch `load`, per family, in the order asked.
///
/// ```swift
/// let results = await WebFonts.shared.load(["Pacifico", "Lobstr"])
/// for (family, result) in results { print(family, result) }
/// ```
public struct FontLoadResults: Sequence, Sendable {
    /// One family and how its load ended.
    public typealias Element = (family: String, result: Result<Void, WebFontError>)

    private let entries: [Element]
    /// Distinct families asked for; one that did not finish has no entry.
    private let expected: Int

    init(_ entries: [Element], expected: Int) {
        self.entries = entries
        self.expected = expected
    }

    /// True when every family in the batch loaded.
    ///
    /// ```swift
    /// if !results.allSucceeded { retryLater(results.failed.map(\.family)) }
    /// ```
    public var allSucceeded: Bool {
        entries.allSatisfy { if case .success = $0.result { true } else { false } }
            && entries.count == expected
    }

    /// The families that loaded, in the order asked.
    ///
    /// ```swift
    /// print(results.succeeded) // ["Pacifico"]
    /// ```
    public var succeeded: [String] {
        entries.compactMap { if case .success = $0.result { $0.family } else { nil } }
    }

    /// The families that failed, with their errors, in the order asked.
    ///
    /// ```swift
    /// for (family, error) in results.failed { print(family, error) }
    /// ```
    public var failed: [(family: String, error: WebFontError)] {
        entries.compactMap { if case .failure(let error) = $0.result { ($0.family, error) } else { nil } }
    }

    /// Iterates the families in the order asked.
    ///
    /// ```swift
    /// for (family, result) in results { print(family, result) }
    /// ```
    public func makeIterator() -> IndexingIterator<[Element]> {
        entries.makeIterator()
    }

    /// The result for one family, or nil if it was not in the batch or did not finish.
    ///
    /// ```swift
    /// if case .failure(.notFound)? = results["Lobstr"] { print("misspelt") }
    /// ```
    public subscript(_ family: String) -> Result<Void, WebFontError>? {
        entries.first { $0.family == family }?.result
    }
}
