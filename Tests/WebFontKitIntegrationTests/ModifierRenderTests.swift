import CoreText
import Foundation
import SwiftUI
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

extension IntegrationTests {
    /// Every pixel comparison of a web font: real registration, so it lives here.
    @Suite
    @MainActor
    final class ModifierRenderTests {
        let directory = TempDirectory()
        let server = StubServer()

        init() {
            server.respondToOthers { request in
                let url = request.url!.absoluteString
                if url.contains("fonts.googleapis.com/css2") {
                    guard url.contains("family=Lobster:ital,wght@0,400") else {
                        return StubResponse(statusCode: 400, headers: ["Content-Type": "text/html"], body: Fixtures.css2("not-found"))
                    }
                    return .css(Fixtures.css2Text("lobster"))
                }
                return .font(Fixtures.data(Fixtures.lobster))
            }
        }

        func fonts() -> WebFonts {
            WebFonts(configuration: .init(session: server.makeSession()), registrar: CoreTextRegistrar(),
                     fileOperations: DiskFileOperations(), root: directory.url, logSink: RecordingLogSink())
        }

        func image(_ view: some View, fonts: WebFonts? = nil, sizeCategory: DynamicTypeSize = .large) -> CGImage? {
            let content = view.foregroundStyle(.black).padding().background(.white)
                .environment(\.dynamicTypeSize, sizeCategory)
            let renderer = ImageRenderer(content: AnyView(fonts.map { AnyView(content.environment(\.webFonts, $0)) } ?? AnyView(content)))
            renderer.scale = 1
            return renderer.cgImage
        }

        func pixels(_ image: CGImage?) -> Data? {
            guard let image, let data = image.dataProvider?.data else { return nil }
            return data as Data
        }

        @Test("a registered face renders exactly like Font.custom with its PostScript name, and unlike the fallback")
        func matchesPostScriptFace() async throws {
            let fonts = fonts()
            try await fonts.load("Lobster")
            let web = pixels(image(Text("Hamburgefonstiv").font(web: "Lobster", size: 24), fonts: fonts))
            #expect(web != nil)
            #expect(web == pixels(image(Text("Hamburgefonstiv").font(.custom("Lobster-Regular", size: 24)))))
            #expect(web != pixels(image(Text("Hamburgefonstiv").font(.system(size: 24)))))
            try await fonts.removeAll()
        }

        @Test("a style the family lacks draws the plain regular face; after remove it draws the fallback")
        func styleFallbackDrawn() async throws {
            let fonts = fonts()
            let loaded = AsyncLatch()
            let renderer = ImageRenderer(content: AnyView(
                Text("Hamburgefonstiv").font(web: "Lobster", size: 24, weight: .bold) { if $0 == .loaded { loaded.open() } }
                    .foregroundStyle(.black).padding().background(.white).environment(\.webFonts, fonts)
            ))
            renderer.scale = 1
            _ = renderer.cgImage
            try await loaded.wait()
            let bold = pixels(renderer.cgImage)
            #expect(bold == pixels(image(Text("Hamburgefonstiv").font(.custom("Lobster-Regular", size: 24)))))
            try await fonts.remove("Lobster")
            #expect(pixels(renderer.cgImage) == pixels(image(Text("Hamburgefonstiv").font(.system(size: 24, weight: .bold)))))
        }

        @Test("rendered once, as a widget does: configure, load, then one image with the web font")
        func widgetRender() async throws {
            let seed = fonts()
            try await seed.load("Lobster")
            let widget = WebFonts(configuration: .init(session: server.makeSession()), registrar: CoreTextRegistrar(),
                                  fileOperations: DiskFileOperations(), root: directory.url, logSink: RecordingLogSink())
            widget.configure(.init(session: server.makeSession()))
            let requests = server.requests.count
            try await widget.load("Lobster", styles: [.regular])
            #expect(server.requests.count == requests)
            let once = pixels(image(Text("Hamburgefonstiv").font(web: "Lobster", size: 24), fonts: widget))
            #expect(once == pixels(image(Text("Hamburgefonstiv").font(.custom("Lobster-Regular", size: 24)))))
            try await widget.removeAll()
            try await seed.removeAll()
        }

        #if os(iOS)
        @Test("the default fallback grows with Dynamic Type as the web font does; a fixed size does not")
        func dynamicType() async throws {
            let fonts = fonts()
            try await fonts.load("Lobster")
            func width(_ view: some View, _ size: DynamicTypeSize, _ fonts: WebFonts?) -> Int { image(view, fonts: fonts, sizeCategory: size)?.width ?? 0 }
            let web = Text("Hamburgefonstiv").font(web: "Lobster", size: 24)
            let webGrowth = Double(width(web, .accessibility5, fonts)) / Double(width(web, .large, fonts))
            let empty = WebFonts(configuration: .init(source: PreviewFontSource(behaviour: .neverAnswers)), registrar: CoreTextRegistrar(),
                                 fileOperations: DiskFileOperations(), root: TempDirectory().url)
            let fallback = Text("Hamburgefonstiv").font(web: "Lobster", size: 24)
            let fallbackGrowth = Double(width(fallback, .accessibility5, empty)) / Double(width(fallback, .large, empty))
            #expect(webGrowth > 2)
            #expect(abs(fallbackGrowth - webGrowth) < 0.35)
            let fixed = Text("Hamburgefonstiv").font(web: "Lobster", fixedSize: 24)
            #expect(width(fixed, .accessibility5, empty) == width(fixed, .large, empty))
            try await fonts.removeAll()
        }
        #endif
    }
}
