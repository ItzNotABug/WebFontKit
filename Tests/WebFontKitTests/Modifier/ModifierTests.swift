import Foundation
import SwiftUI
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

/// Drives a live view through an `ImageRenderer`: every change goes through this model.
@MainActor
@Observable
final class ModifierModel {
    var family = "Lobster"
    /// Never 24: SwiftUI caches a font name it could not resolve, process-wide, per size,
    /// and the integration target renders the real face at 24 in the same process.
    var size: CGFloat = 19
    var weight: Font.Weight = .regular
    var italic = false
    var shown = true
}

@MainActor
struct ModifierHarness {
    let fonts: WebFonts
    let model: ModifierModel
    let choices = AsyncRecorder<FontChoice>()
    let phases = AsyncRecorder<WebFontPhase>()
    let renderer: ImageRenderer<AnyView>

    init(fonts: WebFonts, model: ModifierModel = ModifierModel(), fallback: Font? = nil) {
        self.fonts = fonts
        self.model = model
        let choices = choices
        let phases = phases
        renderer = ImageRenderer(content: AnyView(
            ModifierProbe(model: model, fallback: fallback) { phase in
                MainActor.assertIsolated()
                #expect(!WebFontModifier.isEvaluatingBody)
                phases.append(phase)
            }
            .environment(\.webFonts, fonts)
            .environment(\.webFontChoiceRecorder) { choices.append($0) }
        ))
        renderer.scale = 1
        _ = renderer.cgImage
    }

    func render() {
        _ = renderer.cgImage
    }

    /// Every phase so far, once `count` of them are `.loaded` or `.failed`.
    func settledPhases(count: Int = 1) async throws -> [WebFontPhase] {
        try await phases.wait { $0.count { $0 != .loading } >= count }
    }
}

struct ModifierProbe: View {
    let model: ModifierModel
    let fallback: Font?
    let onPhase: @MainActor (WebFontPhase) -> Void

    var body: some View {
        if model.shown {
            Text("Hamburgefonstiv")
                .font(web: model.family, size: model.size, weight: model.weight, italic: model.italic,
                      fallback: fallback, onPhase: onPhase)
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ModifierTests {
    @Test("a registered font draws on the first body, and no fallback is ever recorded")
    func firstFrame() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        try await fonts.load("Lobster")

        let view = ModifierHarness(fonts: fonts)
        #expect(try await view.settledPhases() == [.loaded])
        view.render()
        #expect(view.choices.elements.first == .postScriptName("Lobster-Regular"))
        #expect(!view.choices.elements.contains { if case .fallback = $0 { true } else { false } })
    }

    @Test("another family's face re-renders nothing; a change to the view's own family does")
    func otherFamilyDoesNotRerender() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        try await fonts.load("Lobster")
        let view = ModifierHarness(fonts: fonts)
        #expect(try await view.settledPhases() == [.loaded])
        view.render()
        let bodies = view.choices.elements.count

        try await fonts.load("Inter", styles: [.regular, .bold])
        view.render()
        #expect(view.choices.elements.count == bodies)

        try await fonts.remove("Lobster")
        view.render()
        try await view.choices.wait { $0.count > bodies }
    }

    @Test("not registered: the fallback first, then the PostScript name once loaded, with .loading then .loaded")
    func swap() async throws {
        let harness = Harness()
        harness.server.serveGoogle(holdFiles: true)
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)

        let view = ModifierHarness(fonts: fonts)
        #expect(view.choices.elements.first == .fallback(.system(size: 19, weight: .regular)))
        try await harness.server.waitForRequests { harness.isFontFile($0) }
        harness.server.releaseAll()
        #expect(try await view.settledPhases() == [.loading, .loaded])
        view.render()
        try await view.choices.wait { $0.last == .postScriptName("Lobster-Regular") }
    }

    @Test("the default fallback matches weight and italic")
    func defaultFallback() async throws {
        let harness = Harness()
        harness.server.serveGoogle(holdFiles: true)
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        let model = ModifierModel()
        model.weight = .bold
        model.italic = true
        let view = ModifierHarness(fonts: fonts, model: model)
        #expect(view.choices.elements.first == .fallback(.system(size: 19, weight: .bold).italic()))

        // Lobster has no bold italic, so the regular face is fetched and drawn in its place.
        try await harness.server.waitForRequests { harness.isFontFile($0) }
        harness.server.releaseAll()
        #expect(try await view.settledPhases() == [.loading, .loaded])
    }

    @Test("a caller's fallback is drawn instead")
    func customFallback() async throws {
        let harness = Harness()
        harness.server.serveGoogle(holdFiles: true)
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        let view = ModifierHarness(fonts: fonts, fallback: .title)
        #expect(view.choices.elements.first == .fallback(.title))
        try await harness.server.waitForRequests { harness.isFontFile($0) }
        harness.server.releaseAll()
        #expect(try await view.settledPhases() == [.loading, .loaded])
    }

    @Test(
        "the weight maps to the CSS weight Apple's visual order gives",
        arguments: [(Font.Weight.ultraLight, 100), (.thin, 200), (.light, 300), (.regular, 400), (.medium, 500),
                    (.semibold, 600), (.bold, 700), (.heavy, 800), (.black, 900)]
    )
    func weightMapping(weight: Font.Weight, css: Int) {
        #expect(WebFontModifier.cssWeight(weight) == css)
    }

    @Test("a failing font reports .loading then .failed and keeps the fallback")
    func failing() async throws {
        let harness = Harness()
        harness.server.respondToOthers { _ in .failure(.notConnectedToInternet) }
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        let view = ModifierHarness(fonts: fonts)
        #expect(try await view.settledPhases() == [.loading, .failed(.offline)])
    }

    @Test("a name the source rejects fails once, without trying its regular face")
    func rejectedNameFailsOnce() async throws {
        let harness = Harness()
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        let model = ModifierModel()
        model.family = "Lob$ter"
        model.weight = .bold
        let view = ModifierHarness(fonts: fonts, model: model)
        try await view.phases.wait { $0.last == .failed(.notFound) }
        #expect(harness.logSink.entries.count { $0.message.contains("Rejected the family name") } == 1)
    }

    @Test("a style the family lacks draws the regular face, reports .loaded, and a second view draws it at once")
    func styleFallback() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        let first = ModifierHarness(fonts: fonts)
        first.model.weight = .bold
        first.render()
        try await first.phases.wait { $0.last == .loaded }
        #expect(fonts.downloaded.map(\.style) == [.regular])
        #expect(harness.logSink.entries.contains { $0.message.contains("Lobster has no 700 face") })

        let requests = harness.server.requests.count
        let second = ModifierHarness(fonts: fonts)
        second.model.weight = .bold
        second.render()
        try await second.choices.wait { $0.last == .postScriptName("Lobster-Regular") }
        #expect(harness.server.requests.count == requests)

        try await fonts.remove("Lobster")
        #expect(fonts.postScriptName(family: "Lobster", style: .bold) == nil)
    }

    @Test("changing only the size never reloads")
    func sizeChange() async throws {
        let harness = Harness()
        harness.server.serveGoogle()
        let fonts = harness.makeFonts()
        try await harness.warmUp(fonts)
        let view = ModifierHarness(fonts: fonts)
        #expect(try await view.settledPhases() == [.loading, .loaded])
        view.model.size = 40
        view.render()

        // A reload from the size change would land before the second family's phases.
        view.model.family = "Inter"
        view.render()
        #expect(try await view.settledPhases(count: 2) == [.loading, .loaded, .loading, .loaded])
        #expect(harness.css2Requests(for: "Lobster") == 1)
    }

    @Test("the modifier can be called from nonisolated code")
    nonisolated func nonisolatedCall() {
        _ = Text("x").font(web: "Lobster", size: 12)
    }
}
