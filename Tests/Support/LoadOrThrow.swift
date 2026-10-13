#if DEBUG
import WebFontKit

extension WebFonts {
    /// `load` as a throwing call: the first failure in the order asked, or
    /// `CancellationError` for a style that did not finish.
    public func loadOrThrow(_ family: String, styles: [FontStyle] = [.regular]) async throws {
        let results = await load(family, styles: styles)
        if let failure = results.failed.first { throw failure.error }
        if !results.allSucceeded { throw CancellationError() }
    }
}
#endif
