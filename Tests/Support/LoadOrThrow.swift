#if DEBUG
import WebFontKit

extension WebFonts {
    /// `load` as a throwing call: the first failure in the order asked, or
    /// `CancellationError` for a style that did not finish.
    public func loadOrThrow(_ family: String, styles: [FontStyle] = [.regular]) async throws {
        let results = await load(family, styles: styles)
        var seen = Set<FontStyle>()
        for style in styles where seen.insert(style).inserted {
            switch results[style] {
            case .success?: continue
            case .failure(let error)?: throw error
            case nil: throw CancellationError()
            }
        }
    }
}
#endif
