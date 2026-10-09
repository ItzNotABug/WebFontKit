import SwiftUI
import WebFontKit

/// The Try screen's state: what is previewed and how it is styled. The family and the
/// sample text are remembered across launches.
@MainActor
@Observable
final class TryModel {
    static let weights: [(weight: Font.Weight, css: Int)] = [
        (.thin, 200), (.light, 300), (.regular, 400), (.medium, 500), (.semibold, 600), (.bold, 700), (.black, 900),
    ]
    static let suggestions = ["Lobster", "Pacifico", "Inter", "Playfair Display", "Caveat", "Bebas Neue", "Noto Sans Kannada"]
    private static let defaultSample = "The quick brown fox jumps over the lazy dog"

    var input: String
    private(set) var family: String {
        didSet { defaults.set(family, forKey: "try.family") }
    }
    var sample: String {
        didSet { defaults.set(sample, forKey: "try.sample") }
    }
    var weight: Font.Weight = .regular
    var italic = false
    var size: Double = 38
    var phase: WebFontPhase
    /// Bumped by Retry: a new identity for the preview restarts its load.
    private(set) var attempt = 0

    private let defaults: UserDefaults

    /// `isStored` tells whether a family's regular face is registered, so the status is right on the first frame.
    init(defaults: UserDefaults = .standard, isStored: (String) -> Bool) {
        self.defaults = defaults
        let family = defaults.string(forKey: "try.family") ?? "Lobster"
        self.family = family
        input = family
        sample = defaults.string(forKey: "try.sample") ?? Self.defaultSample
        phase = isStored(family) ? .loaded : .loading
    }

    /// The style the preview asks for, as the library names it.
    var style: FontStyle {
        FontStyle(weight: Self.weights.first { $0.weight == weight }?.css ?? 400, italic: italic)
    }

    /// The family typed in the field, trimmed.
    var pendingFamily: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasPendingInput: Bool {
        !pendingFamily.isEmpty && pendingFamily != family
    }

    /// What VoiceOver announces once a load settles. It names the family, so switching
    /// between two stored families is announced too.
    var announcement: String? {
        phase == .loading ? nil : "\(family): \(phase.label)"
    }

    /// `stored` is whether the new family's face is already registered: a stored one is ready at once.
    func submit(stored: Bool) {
        let name = pendingFamily
        guard !name.isEmpty, name != family else { return }
        family = name
        phase = stored ? .loaded : .loading
    }

    func choose(_ name: String, stored: Bool) {
        input = name
        submit(stored: stored)
    }

    func retry() {
        attempt += 1
    }
}

/// Type a family name and watch it swap in, with any weight, style and size.
struct TryView: View {
    enum Field { case family, sample }

    @State private var model: TryModel
    @State private var showsAbout = false
    @FocusState private var focus: Field?

    // Untracked, so ShowcaseView's body doesn't re-render on every font event.
    init() {
        _model = State(initialValue: TryModel { FontLibrary.isStored($0, style: .regular) })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PreviewCard(model: model, focus: $focus)
                FamilyCard(model: model, focus: $focus)
                StyleCard(model: model)
                Text("A style the family lacks draws its regular face: iOS never fakes bold or italic for a downloaded font.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .screen("WebFontKit")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showsAbout = true } label: { Label("About", systemImage: "info.circle") }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }.fontWeight(.semibold)
            }
        }
        .sheet(isPresented: $showsAbout) { AboutView() }
        .sensoryFeedback(.selection, trigger: model.family)
        .sensoryFeedback(.selection, trigger: model.weight)
        // Only on arrival: success when it draws, an error when it can't; nothing when a load starts.
        .sensoryFeedback(trigger: model.phase) { _, phase in
            switch phase {
            case .loaded: .success
            case .failed: .error
            case .loading: nil
            }
        }
        .onChange(of: model.announcement) { _, announcement in
            if let announcement { AccessibilityNotification.Announcement(announcement).post() }
        }
    }
}

/// The sample in the chosen font, its status, and the stored face behind it.
private struct PreviewCard: View {
    @Bindable var model: TryModel
    var focus: FocusState<TryView.Field?>.Binding
    @Environment(FontLibrary.self) private var library
    /// A fixed box: fonts differ wildly in metrics, so the sample shrinks to fit instead of moving the card.
    @ScaledMetric(relativeTo: .body) private var boxHeight: CGFloat = 200

    private struct PreviewID: Hashable {
        var family: String
        var attempt: Int
        var generation: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(model.family).font(.headline).lineLimit(1)
                Spacer(minLength: 12)
                PhasePill(phase: model.phase, retry: model.retry).fixedSize()
            }
            .frame(minHeight: 38)
            Text(model.sample)
                .font(web: model.family, size: model.size, weight: model.weight, italic: model.italic) { model.phase = $0 }
                .foregroundStyle(.white)
                .lineLimit(4)
                .minimumScaleFactor(0.35)
                // A skeleton while loading, rather than the system-font fallback; a failure keeps the readable fallback.
                .redacted(reason: model.phase == .loading ? .placeholder : [])
                .shimmer(model.phase == .loading)
                .motion(.easeInOut(duration: 0.35), value: model.phase == .loading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(height: boxHeight)
                .id(PreviewID(family: model.family, attempt: model.attempt, generation: library.generation(of: model.family)))
                .accessibilityLabel("Preview in \(model.family): \(model.sample)")
            StoredFaceLine(family: model.family, style: model.style, phase: model.phase)
            TextField("Sample text", text: $model.sample, axis: .vertical)
                .focused(focus, equals: .sample)
                .font(.callout)
                .lineLimit(1...3)
                .padding(12)
                .glass(cornerRadius: 14, interactive: true)
        }
        .padding(22)
        .surface(cornerRadius: 30)
    }
}

/// The family field and one-tap suggestions, each drawn in its own font.
private struct FamilyCard: View {
    @Bindable var model: TryModel
    var focus: FocusState<TryView.Field?>.Binding

    var body: some View {
        Card(title: "Family") {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Any family on fonts.google.com", text: $model.input)
                    .focused(focus, equals: .family)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .accessibilityLabel("Font family")
                if model.hasPendingInput {
                    Button {
                        submit()
                        focus.wrappedValue = nil
                    } label: {
                        Text("Load").frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .glass(cornerRadius: 14, interactive: true)
            ScrollView(.horizontal, showsIndicators: false) {
                GlassGroup {
                    HStack(spacing: 10) {
                        ForEach(TryModel.suggestions, id: \.self) { name in
                            FontChip(family: name, selected: name == model.family) {
                                model.choose(name, stored: FontLibrary.isStored(name, style: model.style))
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func submit() {
        model.submit(stored: FontLibrary.isStored(model.pendingFamily, style: model.style))
    }
}

/// Weight, italic and size. Its own view, so a slider drag redraws only what reads the size.
private struct StyleCard: View {
    @Bindable var model: TryModel

    var body: some View {
        Card(title: "Style") {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassGroup {
                    HStack(spacing: 8) {
                        ForEach(TryModel.weights, id: \.css) { option in
                            let selected = model.weight == option.weight
                            Button { model.weight = option.weight } label: {
                                Text(FontStyle(weight: option.css).displayName)
                                    .font(.system(.subheadline, weight: option.weight))
                            }
                            .buttonStyle(ChipButtonStyle(selected: selected))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Weight")
            Toggle(isOn: $model.italic) { Label("Italic", systemImage: "italic") }
                .tint(Theme.accent)
            HStack(spacing: 12) {
                Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $model.size, in: 14...72, step: 1) { Text("Size") }
                    .tint(Theme.accent)
                    .accessibilityValue("\(Int(model.size)) points")
                Text("\(Int(model.size)) pt").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 50, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}
