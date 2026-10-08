import SwiftUI

/// A source for previews: it never answers, or always fails, and never touches the network.
struct PreviewFontSource: FontSource {
    enum Behavior: Sendable {
        case neverAnswers
        case fails(WebFontError)
    }

    var behaviour: Behavior

    func fetch(_ font: FontRequest) async throws -> Data {
        switch behaviour {
        case .neverAnswers:
            try await Task.sleep(for: .seconds(86_400))
            throw CancellationError()
        case .fails(let error):
            throw error
        }
    }

    /// An instance on a throwaway session store, so previews never touch the real one.
    static func fonts(_ behaviour: Behavior) -> WebFonts {
        WebFonts(
            configuration: WebFonts.Configuration(source: PreviewFontSource(behaviour: behaviour), storage: .session),
            registrar: CoreTextRegistrar(), fileOperations: DiskFileOperations(),
            root: FileManager.default.temporaryDirectory.appendingPathComponent("WebFontKit-previews")
        )
    }
}

/// What the library previews show: the fallback while loading, after a failure, and a custom fallback.
struct WebFontPreviewContent: View {
    var behaviour: PreviewFontSource.Behavior
    var fallback: Font?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The quick brown fox").font(web: "Lobster", size: 24, fallback: fallback)
            Text("Bold italic fallback").font(web: "Lobster", size: 17, weight: .bold, italic: true, fallback: fallback)
            Text("Fixed size").font(web: "Lobster", fixedSize: 13, fallback: fallback)
        }
        .padding()
        .environment(\.webFonts, PreviewFontSource.fonts(behaviour))
    }
}

#Preview("Loading") {
    WebFontPreviewContent(behaviour: .neverAnswers, fallback: nil)
}

#Preview("Failed") {
    WebFontPreviewContent(behaviour: .fails(.offline), fallback: nil)
}

#Preview("Custom fallback") {
    WebFontPreviewContent(behaviour: .neverAnswers, fallback: .system(.title, design: .serif))
}
