import SwiftUI
import WebFontKit

// A preview, not part of the app. `.font(web:)` on a container styles every text inside it,
// like SwiftUI's `.font`, and an inner `.font(web:)` overrides it for that view only.

/// The arguments of one `.font(web:)` call.
private struct Face {
    let family: String
    let size: CGFloat
    let weight: Font.Weight
    let italic: Bool

    init(_ family: String, _ size: CGFloat, _ weight: Font.Weight = .regular, italic: Bool = false) {
        self.family = family
        self.size = size
        self.weight = weight
        self.italic = italic
    }
}

/// The face each part of the essay sets; `nil` keeps the page's font.
private struct Typography {
    var kicker, title, subtitle, meta, body, quote, attribution: Face?
    var colophon: String

    /// The page sets Caveat. Some texts change its size; the subtitle and body inherit it as is.
    static let wholeView = Typography(
        kicker: Face("Caveat", 15, .bold),
        title: Face("Caveat", 44, .bold),
        subtitle: nil,
        meta: Face("Caveat", 15),
        body: nil,
        quote: Face("Caveat", 30, .bold),
        attribution: Face("Caveat", 15, .bold),
        colophon: "Set in Caveat, from one .font(web:) on the page."
    )

    static let perView = Typography(
        kicker: Face("Oswald", 13, .medium),
        title: Face("Playfair Display", 40, .bold),
        subtitle: Face("Lora", 19, italic: true),
        meta: Face("Oswald", 12),
        body: Face("Lora", 18),
        quote: Face("Playfair Display", 28, italic: true),
        attribution: Face("Oswald", 12, .medium),
        colophon: "Set in Playfair Display, Lora and Oswald, a font per view."
    )
}

private let page = Color(red: 0.06, green: 0.06, blue: 0.08)
private let amber = Color(red: 0.98, green: 0.73, blue: 0.42)

private struct Essay: View {
    let typography: Typography
    var visible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ON TYPOGRAPHY")
                .tracking(2.4)
                .foregroundStyle(amber)
                .face(typography.kicker)
                .reveal(visible, order: 0)

            Text("The Crystal Goblet")
                .foregroundStyle(.white)
                .face(typography.title)
                .padding(.top, 12)
                .reveal(visible, order: 1)

            Text("Why the best type is the type you never notice.")
                .foregroundStyle(.white.opacity(0.6))
                .face(typography.subtitle)
                .padding(.top, 10)
                .reveal(visible, order: 2)

            HStack(spacing: 8) {
                Circle().fill(amber).frame(width: 5, height: 5)
                Text("5 MIN READ")
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.4))
                    .face(typography.meta)
            }
            .padding(.top, 18)
            .reveal(visible, order: 3)

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                .padding(.vertical, 28)
                .reveal(visible, order: 4)

            VStack(alignment: .leading, spacing: 22) {
                paragraph("Nearly a century ago, the typographer Beatrice Warde asked a room full of printers to imagine two goblets of wine. One is solid gold, wrought in the most exquisite patterns. The other is crystal-clear glass, thin as a bubble.")
                    .reveal(visible, order: 5)
                paragraph("Which would a true lover of wine choose? The glass, she said, because everything about it is meant to reveal what's inside, not to show itself off. Type, she argued, should work the same way.")
                    .reveal(visible, order: 6)
                quote
                    .reveal(visible, order: 7)
                paragraph("That doesn't make the choice of typeface unimportant. It makes it quieter. A font sets the voice of a page before a single word is read: a warm serif for a long essay, a crisp sans for an interface, a looser hand for a note meant to feel personal.")
                    .reveal(visible, order: 8)
                paragraph("Choose the voice, then get out of the way, and let the words do the talking.")
                    .reveal(visible, order: 9)
            }

            colophon
                .reveal(visible, order: 10)
        }
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
    }

    private var quote: some View {
        HStack(alignment: .top, spacing: 18) {
            Capsule().fill(amber).frame(width: 3)
            VStack(alignment: .leading, spacing: 10) {
                Text("Printing should be invisible.")
                    .foregroundStyle(.white)
                    .face(typography.quote)
                Text("BEATRICE WARDE")
                    .tracking(1.6)
                    .foregroundStyle(amber.opacity(0.8))
                    .face(typography.attribution)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 10)
    }

    private var colophon: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule().fill(amber.opacity(0.6)).frame(width: 28, height: 2)
            Text(typography.colophon)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.top, 44)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .lineSpacing(7)
            .foregroundStyle(.white.opacity(0.8))
            .face(typography.body)
    }
}

/// Both versions stay laid out, so switching never waits on a download and keeps the scroll position.
private struct FontCascadeDemo: View {
    @State private var wholeView = true

    var body: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                Essay(typography: .wholeView, visible: wholeView)
                    .font(web: "Caveat", size: 22)  // the one call the whole page inherits
                Essay(typography: .perView, visible: !wholeView)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(page.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            styleSwitch
                .frame(maxWidth: .infinity)
                .padding(.top, 56)
                .background {
                    // Fades the text out above the button.
                    LinearGradient(stops: [.init(color: page.opacity(0), location: 0),
                                           .init(color: page.opacity(0.9), location: 0.3),
                                           .init(color: page, location: 0.42)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                        .allowsHitTesting(false)
                }
        }
        .sensoryFeedback(.selection, trigger: wholeView)
        .preferredColorScheme(.dark)
    }

    private var styleSwitch: some View {
        Button {
            withAnimation(.smooth(duration: 0.4)) { wholeView.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: wholeView ? "doc.text" : "textformat")
                    .foregroundStyle(amber)
                    .contentTransition(.symbolEffect(.replace))
                Text(wholeView ? "Whole view" : "Per view")
                    .contentTransition(.interpolate)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .symbolEffect(.bounce, value: wholeView)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassPill()
        .padding(.bottom, 24)
        .accessibilityLabel(wholeView ? "Showing one font for the page" : "Showing a font per view")
        .accessibilityHint("Switches the styling")
    }
}

/// Shows or hides a block, staggered by its order on the page. The outgoing text fades fast and
/// the incoming one starts a little later, so the two fonts don't overlap. Reduce Motion gets a plain fade.
private struct Reveal: ViewModifier {
    let visible: Bool
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .blur(radius: visible || reduceMotion ? 0 : 6)
            .offset(y: visible || reduceMotion ? 0 : 10)
            .animation(animation, value: visible)
    }

    private var animation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.3) }
        let stagger = Double(order) * 0.04
        return visible ? .smooth(duration: 0.6).delay(0.12 + stagger) : .easeOut(duration: 0.25).delay(stagger)
    }
}

private extension View {
    /// Applies the face, or leaves the inherited font when there is none.
    @ViewBuilder
    func face(_ face: Face?) -> some View {
        if let face {
            font(web: face.family, size: face.size, weight: face.weight, italic: face.italic)
        } else {
            self
        }
    }

    func reveal(_ visible: Bool, order: Int) -> some View {
        modifier(Reveal(visible: visible, order: order))
    }

    /// Liquid Glass on iOS 26, a material before it.
    @ViewBuilder
    func glassPill() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        }
    }
}

#Preview("Font cascade") {
    FontCascadeDemo()
}
