import SwiftUI

extension View {
    /// Draws text in a web font that scales with Dynamic Type, showing `fallback`
    /// until the font is ready. A registered font draws on the first frame.
    ///
    /// ```swift
    /// Text("Hello").font(web: "Lobster", size: 24)
    /// Text("Hello").font(web: "Inter", size: 17, weight: .bold) { phase in print(phase) }
    /// ```
    nonisolated public func font(web family: String, size: CGFloat,
                                 weight: Font.Weight = .regular, italic: Bool = false,
                                 fallback: Font? = nil,
                                 onPhase: (@MainActor (WebFontPhase) -> Void)? = nil) -> some View {
        modifier(WebFontModifier(family: family, size: size, scales: true, weight: weight, italic: italic,
                                 fallback: fallback, onPhase: onPhase))
    }

    /// Draws text in a web font at a fixed size that never scales, like `Font.custom(_:fixedSize:)`.
    ///
    /// ```swift
    /// Text("12:45").font(web: "Bebas Neue", fixedSize: 64)
    /// ```
    nonisolated public func font(web family: String, fixedSize: CGFloat,
                                 weight: Font.Weight = .regular, italic: Bool = false,
                                 fallback: Font? = nil,
                                 onPhase: (@MainActor (WebFontPhase) -> Void)? = nil) -> some View {
        modifier(WebFontModifier(family: family, size: fixedSize, scales: false, weight: weight, italic: italic,
                                 fallback: fallback, onPhase: onPhase))
    }
}

extension EnvironmentValues {
    /// The instance the modifier loads through; tests and previews inject their own.
    @Entry var webFonts: WebFonts = .shared
}

#if DEBUG
/// What one `body` evaluation drew, recorded by tests of the first frame.
enum FontChoice: Equatable {
    case postScriptName(String)
    case fallback(Font)
}

extension EnvironmentValues {
    @Entry var webFontChoiceRecorder: (@MainActor @Sendable (FontChoice) -> Void)? = nil
}
#endif

/// The modifier behind `.font(web:)`.
struct WebFontModifier: ViewModifier {
    let family: String
    let size: CGFloat
    let scales: Bool
    let weight: Font.Weight
    let italic: Bool
    let fallback: Font?
    let onPhase: (@MainActor (WebFontPhase) -> Void)?

    @Environment(\.webFonts) private var fonts
    /// The fallback grows with Dynamic Type exactly as `Font.custom(_:size:)` does.
    @ScaledMetric private var scaledSize: CGFloat

    #if DEBUG
    @Environment(\.webFontChoiceRecorder) private var recordChoice
    /// True while any modifier's `body(content:)` runs, so tests can check `onPhase` never runs there.
    @MainActor static var isEvaluatingBody = false
    #endif

    nonisolated init(family: String, size: CGFloat, scales: Bool, weight: Font.Weight, italic: Bool,
         fallback: Font?, onPhase: (@MainActor (WebFontPhase) -> Void)?) {
        self.family = family
        self.size = size
        self.scales = scales
        self.weight = weight
        self.italic = italic
        self.fallback = fallback
        self.onPhase = onPhase
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    private var style: FontStyle {
        FontStyle(weight: Self.cssWeight(weight), italic: italic)
    }

    /// Apple's visual order: `.ultraLight` is lighter than `.thin`.
    static func cssWeight(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight: 100
        case .thin: 200
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }

    private var fallbackFont: Font {
        if let fallback { return fallback }
        let system = Font.system(size: scales ? scaledSize : size, weight: weight)
        return italic ? system.italic() : system
    }

    func body(content: Content) -> some View {
        #if DEBUG
        Self.isEvaluatingBody = true
        defer { Self.isEvaluatingBody = false }
        #endif
        _ = fonts.registry.generations.counter(for: family).value
        let name = fonts.postScriptName(family: family, style: style)
        #if DEBUG
        recordChoice?(name.map { .postScriptName($0) } ?? .fallback(fallbackFont))
        #endif
        let font = name.map { scales ? Font.custom($0, size: size) : .custom($0, fixedSize: size) } ?? fallbackFont
        return content
            .font(font)
            .task(id: LoadID(fonts: ObjectIdentifier(fonts), family: family, style: style)) { await load() }
    }

    /// A different instance from the environment is a different load.
    private struct LoadID: Hashable {
        var fonts: ObjectIdentifier
        var family: String
        var style: FontStyle
    }

    /// Runs in `.task`, never in `body`. A cancelled or overtaken load is never reported.
    private func load() async {
        // Read once, so one load never mixes two instances.
        let fonts = fonts
        if fonts.postScriptName(family: family, style: style) != nil {
            onPhase?(.loaded)
            return
        }
        onPhase?(.loading)
        do {
            try await fonts.load(family, styles: [style])
            onPhase?(.loaded)
        } catch WebFontError.notFound where style != .regular && fonts.acceptsFamilyName(family) {
            // A missing style; a rejected name has no regular face to fall back to either.
            await drawRegular(fonts: fonts)
        } catch let error as WebFontError {
            onPhase?(.failed(error))
        } catch {
            // Cancelled, or overtaken by `remove`: the view stays on its fallback.
        }
    }

    /// A style the family lacks draws the regular face plain; iOS synthesises no bold or italic.
    private func drawRegular(fonts: WebFonts) async {
        do {
            let epochs = try await fonts.loadRecordingEpochs(family, styles: [.regular])
            #if DEBUG
            await fonts.hooks.beforeAlias?()
            #endif
            if await fonts.registry.insertAlias(for: FaceKey(family: family, style: style), epochs: epochs) {
                fonts.log("modifier", .info, "\(family) has no \(style.logDescription) face; drawing its regular face")
                onPhase?(.loaded)
            }
        } catch let error as WebFontError {
            onPhase?(.failed(error))
        } catch {
            // Cancelled, or overtaken by `remove`.
        }
    }
}
