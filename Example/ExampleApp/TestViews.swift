import SwiftUI
import WebFontKit

/// The screen the UI tests read: the one-liner, and its phases as an accessibility value.
struct TestHarnessView: View {
    @State private var phases: [String] = []

    var body: some View {
        VStack(spacing: 24) {
            Text("Hello, WebFontKit")
                .font(web: "Pacifico", size: 34) { phases.append(PhaseLabel.text($0)) }
                .accessibilityIdentifier("greeting")
            Text(phases.joined(separator: ","))
                .font(.footnote.monospaced())
                .accessibilityIdentifier("phases")
                .accessibilityValue(phases.joined(separator: ","))
        }
        .padding()
    }
}

/// The cold-launch race, run on a device: was the face already registered on the first frame?
/// `downloaded` lists a face only once it is registered, so "fallback" can only overcount.
struct RaceView: View {
    let family: String
    private static var firstBody: String?

    var body: some View {
        if Self.firstBody == nil {
            let registered = WebFonts.shared.downloaded.contains { $0.family == family && $0.style == .regular }
            Self.firstBody = registered ? "registered" : "fallback"
        }
        return Text("Race: \(family)")
            .font(web: family, size: 28) { phase in
                TestMode.appendRaceLine("race firstBody=\(Self.firstBody ?? "fallback") firstPhase=\(PhaseLabel.text(phase))")
                exit(0)
            }
    }
}

enum PhaseLabel {
    static func text(_ phase: WebFontPhase) -> String {
        switch phase {
        case .loading: "loading"
        case .loaded: "loaded"
        case .failed(let error): "failed(\(error))"
        }
    }
}
