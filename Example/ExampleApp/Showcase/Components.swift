import SwiftUI
import WebFontKit

/// A content card with a small caption above its content.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title).font(.caption.weight(.semibold)).textCase(.uppercase).tracking(1.2).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

/// A moving highlight across a view while something loads.
struct Shimmer: ViewModifier {
    var active: Bool
    /// Where the band's centre is, in unit points; it sweeps from off the left edge to off the right.
    @State private var sweep: CGFloat = -0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if active && !reduceMotion {
                    // Unit points, not a GeometryReader: nothing here runs during layout, which
                    // iOS 26 may do off the main thread.
                    LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                                   startPoint: UnitPoint(x: sweep - 0.25, y: 0.5),
                                   endPoint: UnitPoint(x: sweep + 0.25, y: 0.5))
                        // sourceAtop paints the band only over the content's own pixels.
                        .blendMode(.sourceAtop)
                        .onAppear {
                            sweep = -0.5
                            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { sweep = 1.5 }
                        }
                }
            }
            // Unconditional: applying it only while active would change the content's identity
            // and restart its font load.
            .compositingGroup()
            .opacity(active ? 0.55 : 1)
    }
}

extension View {
    func shimmer(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

extension WebFontPhase {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// A distinct shape per phase, so status never rests on colour alone.
    var symbol: String {
        switch self {
        case .loading: "circle.dotted"
        case .loaded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .loading: Theme.loading
        case .loaded: Theme.loaded
        case .failed: Theme.failed
        }
    }

    var label: String {
        switch self {
        case .loading: "Loading…"
        case .loaded: "Ready"
        case .failed(let error): ErrorText.describe(error)
        }
    }
}

/// A phase as a symbol, for compact places like cards and rows.
struct PhaseIcon: View {
    let phase: WebFontPhase

    var body: some View {
        Image(systemName: phase.symbol)
            .foregroundStyle(phase.color)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

/// Where a `.font(web:)` view is, as a pill. One stable structure, so a phase change
/// cross-fades the icon and label in place and the width eases, instead of swapping views.
struct PhasePill: View {
    let phase: WebFontPhase
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.loading)
                        .opacity(phase == .loading ? 1 : 0)
                    Image(systemName: phase.symbol)
                        .foregroundStyle(phase.color)
                        .contentTransition(.symbolEffect(.replace))
                        .opacity(phase == .loading ? 0 : 1)
                }
                .frame(width: 18, height: 18)
                Text(phase.label)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Font status")
            .accessibilityValue(phase.label)
            if phase.isFailed, let retry {
                Button(action: retry) {
                    // The pill is under 44 pt tall; the hit area reaches past it without changing layout.
                    Text("Retry")
                        .padding(12).contentShape(.rect).padding(-12)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .transition(.opacity)
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassCapsule(tint: phase.color.opacity(phase.isFailed ? 0.3 : 0.25), interactive: false)
        .motion(.smooth(duration: 0.4), value: phase)
    }
}

enum ErrorText {
    static func describe(_ error: WebFontError) -> String {
        switch error {
        case .notFound: "No such family or style"
        case .offline: "You're offline"
        case .invalidFont: "Not a usable font"
        case .network(let code): describe(code)
        case .server(let status): "Server error \(status)"
        case .storage: "Couldn't save the font"
        }
    }

    private static func describe(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: "The request timed out"
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost: "Couldn't reach the server"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate: "Secure connection failed"
        default: "Network problem"
        }
    }
}

extension FontStyle {
    /// "Bold italic", "Extra light": the CSS weight names, for people rather than numbers.
    var displayName: String {
        let weight = switch self.weight {
        case ..<150: "Thin"
        case ..<250: "Extra light"
        case ..<350: "Light"
        case ..<450: "Regular"
        case ..<550: "Medium"
        case ..<650: "Semibold"
        case ..<750: "Bold"
        case ..<850: "Extra bold"
        default: "Black"
        }
        guard isItalic else { return weight }
        return weight == "Regular" ? "Italic" : "\(weight) italic"
    }
}

extension Duration {
    /// One unit, as people say it: "< 1 ms", "350 ms", "2.4 secs".
    var brief: String {
        if self < .milliseconds(1) { return "< 1 ms" }
        if self < .seconds(1) { return formatted(.units(allowed: [.milliseconds], width: .abbreviated)) }
        return formatted(.units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 1)))
    }
}

/// A capsule on glass, filled with the accent when selected.
struct ChipButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? .black : .white)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background { if selected { Capsule().fill(Theme.accent) } }
            .contentShape(.capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .glassCapsule()
    }
}

/// A chip whose label is drawn in the font it names.
struct FontChip: View {
    let family: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Sized by the name in the system font, so the chip keeps its width as its own
            // font arrives; the face fits itself inside.
            Text(family)
                .font(.callout)
                .hidden()
                .overlay {
                    Text(family)
                        .font(web: family, size: 16)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
        }
        .buttonStyle(ChipButtonStyle(selected: selected))
        .accessibilityLabel(family)
        .accessibilityHint("Previews this family")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
