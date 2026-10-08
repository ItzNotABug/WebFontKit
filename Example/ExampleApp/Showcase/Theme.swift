import SwiftUI

/// Colours and the backdrop every screen sits on.
enum Theme {
    static let accent = Color(red: 0.55, green: 0.78, blue: 1.0)
    static let loaded = Color(red: 0.42, green: 0.90, blue: 0.62)
    static let loading = Color(red: 1.0, green: 0.78, blue: 0.38)
    static let failed = Color(red: 1.0, green: 0.45, blue: 0.47)
    static let removed = Color(red: 0.75, green: 0.62, blue: 1.0)
}

/// A deep gradient with two soft glows, behind every screen.
struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.13), Color(red: 0.02, green: 0.02, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            // Radial gradients rather than blurred circles: the same glow without an offscreen blur.
            RadialGradient(colors: [Color(red: 0.25, green: 0.30, blue: 0.85).opacity(0.32), .clear],
                           center: UnitPoint(x: 0.05, y: 0.02), startRadius: 0, endRadius: 440)
            RadialGradient(colors: [Color(red: 0.75, green: 0.25, blue: 0.65).opacity(0.22), .clear],
                           center: UnitPoint(x: 0.95, y: 0.98), startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Groups glass shapes so they render and blend together (Apple's guidance for many glass elements).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// The content layer: a quiet raised surface. Liquid Glass stays on the controls above it, as the HIG asks.
private struct Surface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background {
            shape.fill(.white.opacity(0.06))
                .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.4 : 0.1)))
        }
    }
}

/// `animation(_:value:)` that stands still under Reduce Motion.
private struct MotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    func surface(cornerRadius: CGFloat = 24) -> some View {
        modifier(Surface(cornerRadius: cornerRadius))
    }

    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }

    /// Liquid Glass on iOS 26, a blurred material before it. For controls, not content.
    @ViewBuilder
    func glass(cornerRadius: CGFloat = 24, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.1)))
        }
    }

    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect((interactive ? Glass.regular.interactive() : .regular).tint(tint), in: .capsule)
        } else {
            background((tint ?? .white).opacity(tint == nil ? 0.08 : 0.25), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        }
    }

    /// A screen: the backdrop and a large title. The bars keep their system behaviour,
    /// so a scrolled title always has a backing.
    func screen(_ title: String) -> some View {
        background(Backdrop())
            .scrollContentBackground(.hidden)
            .navigationTitle(title)
    }
}

/// A card that answers a touch at once, before the push lands.
struct PressableCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}
