import SwiftUI

#if DEBUG
/// A source for previews: it never answers, or always fails, and never touches the network.
struct PreviewFontSource: FontSource {
    enum Behavior: Sendable {
        case neverAnswers
        case fails(WebFontError)
    }

    var behavior: Behavior

    func fetch(_ font: FontRequest) async throws -> Data {
        switch behavior {
        case .neverAnswers:
            try await Task.sleep(for: .seconds(86_400))
            throw CancellationError()
        case .fails(let error):
            throw error
        }
    }

    /// An instance on a throwaway session store, so previews never touch the real one.
    static func fonts(_ behavior: Behavior) -> WebFonts {
        WebFonts(
            configuration: WebFonts.Configuration(source: PreviewFontSource(behavior: behavior), storage: .session),
            registrar: CoreTextRegistrar(), fileOperations: DiskFileOperations(),
            root: URL.temporaryDirectory.appending(component: "WebFontKit-previews", directoryHint: .isDirectory)
        )
    }
}

/// What the library previews show: the fallback while loading, after a failure, and a custom fallback.
struct WebFontPreviewContent: View {
    var behavior: PreviewFontSource.Behavior
    var fallback: Font?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The quick brown fox").font(web: "Lobster", size: 24, fallback: fallback)
            Text("Bold italic fallback").font(web: "Lobster", size: 17, weight: .bold, italic: true, fallback: fallback)
            Text("Fixed size").font(web: "Lobster", fixedSize: 13, fallback: fallback)
        }
        .padding()
        .environment(\.webFonts, PreviewFontSource.fonts(behavior))
    }
}

#Preview("Loading") {
    WebFontPreviewContent(behavior: .neverAnswers, fallback: nil)
}

#Preview("Failed") {
    WebFontPreviewContent(behavior: .fails(.offline), fallback: nil)
}

#Preview("Custom fallback") {
    WebFontPreviewContent(behavior: .neverAnswers, fallback: .system(.title, design: .serif))
}
#endif
