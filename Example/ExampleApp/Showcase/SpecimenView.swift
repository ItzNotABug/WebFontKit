import SwiftUI
import WebFontKit

/// A type specimen: big glyphs, the character set, a size waterfall, and each style loading on its own.
struct SpecimenView: View {
    let family: String
    @Environment(FontLibrary.self) private var library
    @State private var attempt = 0

    private struct ContentID: Hashable {
        var attempt: Int
        var generation: Int
    }

    var body: some View {
        // Keyed so Retry, or removing the family elsewhere, starts the specimen over.
        SpecimenContent(family: family, stored: FontLibrary.isStored(family, style: .regular)) { attempt += 1 }
            .id(ContentID(attempt: attempt, generation: library.generation(of: family)))
            .screen(family)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SpecimenContent: View {
    let family: String
    let retry: () -> Void
    @State private var phase: WebFontPhase
    @Environment(FontLibrary.self) private var library
    /// Fixed slots everywhere a web font draws: the fallback, the skeleton and the face differ
    /// in metrics, and none of them may move the page.
    @ScaledMetric(relativeTo: .largeTitle) private var heroHeight: CGFloat = 170
    @ScaledMetric(relativeTo: .body) private var glyphLineHeight: CGFloat = 38
    @ScaledMetric(relativeTo: .title2) private var uikitHeight: CGFloat = 44

    init(family: String, stored: Bool, retry: @escaping () -> Void) {
        self.family = family
        self.retry = retry
        _phase = State(initialValue: stored ? .loaded : .loading)
    }

    var body: some View {
        ScrollView {
            // Lazy: the push lands at once, and sections below the fold build as they scroll in.
            LazyVStack(alignment: .leading, spacing: 18) {
                hero
                Card(title: "Character set") {
                    ForEach(["ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz", "0123456789 & ! ? @ # %"], id: \.self) { line in
                        Text(line)
                            .font(web: family, size: 26)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .redacted(reason: phase == .loading ? .placeholder : [])
                            .shimmer(phase == .loading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: glyphLineHeight)
                    }
                }
                Card(title: "Waterfall") {
                    ForEach([12, 16, 22, 30, 40], id: \.self) { size in
                        WaterfallRow(family: family, size: CGFloat(size), loading: phase == .loading)
                    }
                }
                Card(title: "UIKit") {
                    UIKitLabel(postScriptName: phase == .loaded ? regularFace : nil)
                        .frame(height: uikitHeight)
                    Text("Once registered, Apple's own APIs draw it too: this is a UILabel using the face's exact PostScript name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Card(title: "Styles") {
                    ForEach(StyleRow.styles, id: \.self) { style in
                        StyleRow(family: family, style: style, stored: FontLibrary.isStored(family, style: style))
                    }
                    Text("A style the family lacks draws its regular face.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    private var regularFace: String? {
        library.face(family, style: .regular)?.postScriptName
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                PhasePill(phase: phase, retry: retry).fixedSize()
            }
            Text("Aa")
                .font(web: family, size: 140) { phase = $0 }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .redacted(reason: phase == .loading ? .placeholder : [])
                .shimmer(phase == .loading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: heroHeight)
                .accessibilityLabel("Aa in \(family)")
            StoredFaceLine(family: family, style: .regular, phase: phase)
        }
        .padding(22)
        .surface(cornerRadius: 30)
    }
}

/// One waterfall line: a size label, and the sample running off the edge rather than shrinking.
private struct WaterfallRow: View {
    let family: String
    let size: CGFloat
    let loading: Bool
    @ScaledMetric(relativeTo: .caption2) private var labelWidth: CGFloat = 24
    /// The modifier scales sizes relative to body, so the row's height does too.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(Int(size))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            // Its natural width in an overlay, so a long line never widens the card.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: size * scale * 1.4)
                .overlay(alignment: .leading) {
                    Text("Sphinx of black quartz, judge my vow")
                        .font(web: family, size: size)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .redacted(reason: loading ? .placeholder : [])
                }
                .clipped()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample at \(Int(size)) points")
    }
}

/// One style, loading on its own, with its own status.
private struct StyleRow: View {
    static let styles: [FontStyle] = [.regular, .italic, .bold, .boldItalic]

    let family: String
    let style: FontStyle
    @State private var phase: WebFontPhase
    @ScaledMetric(relativeTo: .caption) private var nameWidth: CGFloat = 84
    @ScaledMetric(relativeTo: .body) private var sampleHeight: CGFloat = 36

    init(family: String, style: FontStyle, stored: Bool) {
        self.family = family
        self.style = style
        _phase = State(initialValue: stored ? .loaded : .loading)
    }

    var body: some View {
        HStack(spacing: 12) {
            PhaseIcon(phase: phase).font(.caption)
            Text(style.displayName).font(.caption).foregroundStyle(.secondary)
                .frame(width: nameWidth, alignment: .leading)
            Text("Handgloves")
                .font(web: family, size: 26, weight: style.weight >= 700 ? .bold : .regular, italic: style.isItalic) { phase = $0 }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .redacted(reason: phase == .loading ? .placeholder : [])
                .frame(height: sampleHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.displayName)
        .accessibilityValue(phase.label)
        .motion(.easeInOut(duration: 0.3), value: phase)
    }
}

/// The stored face behind a preview: its exact name and size, or why there is none.
struct StoredFaceLine: View {
    let family: String
    let style: FontStyle
    let phase: WebFontPhase
    @Environment(FontLibrary.self) private var library

    var body: some View {
        let exact = phase == .loaded ? library.face(family, style: style) : nil
        // A style the family lacks draws its regular face; say which.
        let standIn = phase == .loaded && exact == nil && style != .regular ? library.face(family, style: .regular) : nil
        HStack(spacing: 10) {
            Image(systemName: (exact ?? standIn) == nil ? "circle.dashed" : "internaldrive")
                .accessibilityHidden(true)
            Text(text(exact: exact, standIn: standIn))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .motion(.easeInOut(duration: 0.3), value: exact?.postScriptName ?? standIn?.postScriptName)
    }

    private func text(exact: DownloadedFont?, standIn: DownloadedFont?) -> String {
        if let exact {
            return "\(exact.postScriptName) · \(Int64(exact.byteCount).formatted(.byteCount(style: .file)))"
        }
        if let standIn {
            return "No \(style.displayName.lowercased()) face · \(standIn.postScriptName) stands in"
        }
        switch phase {
        case .loading: return "Not stored yet"
        case .loaded: return "Drawn from a system font"
        case .failed: return "Nothing stored"
        }
    }
}

/// A plain UIKit label drawing the stored face by its exact PostScript name.
private struct UIKitLabel: UIViewRepresentable {
    let postScriptName: String?

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.textColor = .white
        label.text = "Hello from UILabel"
        label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let font = postScriptName.flatMap { UIFont(name: $0, size: 26) } ?? .preferredFont(forTextStyle: .title2)
        label.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: font)
    }

    /// The offered width, never the text's own, so a wide face can't widen the card.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: height)
    }
}
