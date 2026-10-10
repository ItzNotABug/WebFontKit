import Foundation
@testable import WebFontKit
import WebFontKitTestSupport

extension Harness {
    /// A fresh, unconfigured instance on this harness's fakes, temporary root and stub session.
    func makeFonts(source: any FontSource = .default, storage: WebFonts.Configuration.Storage = .persistent,
                   catalog: GoogleFontsCatalog? = nil) -> WebFonts {
        WebFonts(
            configuration: WebFonts.Configuration(source: source, storage: storage, session: session),
            registrar: registrar, fileOperations: files, root: directory.url, logSink: logSink, catalog: { catalog }
        )
    }

    /// Records every event an instance emits, from its first access on.
    func listen(to fonts: WebFonts) -> AsyncRecorder<WebFontEvent> {
        let recorder = AsyncRecorder<WebFontEvent>()
        let stream = fonts.events
        Task { for await event in stream { recorder.append(event) } }
        return recorder
    }

    /// Starts the instance's warm-up through `events` and waits for its `.warmedUp`.
    @discardableResult
    func warmUp(_ fonts: WebFonts) async throws -> AsyncRecorder<WebFontEvent> {
        let events = listen(to: fonts)
        try await events.wait { $0.contains { if case .warmedUp = $0 { true } else { false } } }
        return events
    }

    /// Signals each join of shared work, so a test can act only after a call has joined.
    func joins(on fonts: WebFonts) -> AsyncRecorder<String> {
        let joins = AsyncRecorder<String>()
        fonts.hooks.onJoin = { joins.append($0) }
        return joins
    }

    /// Lets an absence check run only once everything owed for `family` has been emitted:
    /// the family's work settles, then a sentinel load's `.loading` arrives behind it.
    func sentinel(_ fonts: WebFonts, _ events: AsyncRecorder<WebFontEvent>, after family: String) async throws {
        await fonts.quiesce(family: family)
        let sentinel = Task { try await fonts.load(WebFontEvent.sentinelFamily) }
        try await events.wait { $0.contains(.loading(family: WebFontEvent.sentinelFamily, styles: [.regular])) }
        sentinel.cancel()
        _ = try? await sentinel.value
    }

    func isCSS2(_ url: URL) -> Bool { url.host == "fonts.googleapis.com" }
    func isFontFile(_ url: URL) -> Bool { url.host == "fonts.gstatic.com" }

    var css2Requests: Int { server.requests.count { isCSS2($0.url) } }
    func css2Requests(for family: String) -> Int {
        server.requests.count { isCSS2($0.url) && $0.url.query?.hasPrefix("family=\(family):") == true }
    }
    var fileRequests: Int { server.requests.count { isFontFile($0.url) } }
}

extension AsyncRecorder<WebFontEvent> {
    /// Every event but `.warmedUp` and the sentinel's, which may still close with `.failed`.
    var loadEvents: [WebFontEvent] {
        elements.filter { event in
            switch event {
            case .warmedUp: false
            case .loading(let family, _), .loaded(let family, _), .failed(let family, _, _), .removed(let family):
                family != WebFontEvent.sentinelFamily
            }
        }
    }
}

extension WebFontEvent {
    static let sentinelFamily = "Roboto"
}
