import SwiftUI
import Testing
@testable import WebFontKit

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PreviewRenderTests {
    @Test(
        "each library preview renders offline",
        arguments: [
            (PreviewFontSource.Behavior.neverAnswers, Font?.none),
            (.fails(.offline), nil),
            (.neverAnswers, .system(.title, design: .serif)),
        ]
    )
    func renders(behaviour: PreviewFontSource.Behavior, fallback: Font?) {
        let renderer = ImageRenderer(content: WebFontPreviewContent(behaviour: behaviour, fallback: fallback))
        let image = renderer.cgImage
        #expect(image != nil)
        #expect((image?.width ?? 0) > 0)
    }
}
