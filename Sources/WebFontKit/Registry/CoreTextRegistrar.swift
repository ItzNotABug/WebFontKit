import CoreText
import Foundation

/// The real registrar: process-scope registration from files.
struct CoreTextRegistrar: FontRegistrar {
    /// One CoreText error code and the files it applies to.
    struct Failure: Sendable {
        var code: Int
        var urls: [URL]
    }

    /// The handler may run several times, then once more with `done` true.
    typealias BatchCall = @Sendable (
        _ urls: [URL],
        _ handler: @escaping @Sendable (_ failures: [Failure], _ done: Bool) -> Void
    ) -> Void

    private static let registerAll: BatchCall = { urls, handler in
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { errors, done in
            handler(Self.failures(errors), done)
            return true
        }
    }

    private static let unregisterAll: BatchCall = { urls, handler in
        CTFontManagerUnregisterFontURLs(urls as CFArray, .process) { errors, done in
            handler(Self.failures(errors), done)
            return true
        }
    }

    func register(urls: [URL]) async -> [URL: Int] {
        await Self.bridge(urls, Self.registerAll)
    }

    func unregister(urls: [URL]) async -> [URL: Int] {
        await Self.bridge(urls, Self.unregisterAll)
    }

    func faceInfo(at url: URL) -> FaceInfo? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return CoreTextFonts.descriptorInfo(at: url)
    }

    func openFace(postScriptName: String) -> (postScriptName: String, fileURL: URL?, glyphCount: Int) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return CoreTextFonts.openFace(postScriptName: postScriptName)
    }

    func activeFace(postScriptName: String) -> (postScriptName: String, fileURL: URL?)? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return CoreTextFonts.activeFace(postScriptName: postScriptName)
    }

    func faceForFamily(_ family: String) -> (familyName: String, fileURL: URL?) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return CoreTextFonts.faceForFamily(family)
    }

    /// Resumes exactly once, on `done`; failures keyed by the caller's own URL spelling.
    static func bridge(_ urls: [URL], _ call: BatchCall) async -> [URL: Int] {
        guard !urls.isEmpty else { return [:] }
        let byPath = Dictionary(urls.map { ($0.resolvingSymlinksInPath().path(percentEncoded: false), $0) }, uniquingKeysWith: { first, _ in first })
        let collected = Locked((failures: [URL: Int](), resumed: false))
        return await withCheckedContinuation { continuation in
            call(urls) { failures, done in
                let finished = collected.withLock { state -> [URL: Int]? in
                    for failure in failures {
                        for url in failure.urls {
                            let own = byPath[url.resolvingSymlinksInPath().path(percentEncoded: false)] ?? url
                            state.failures[own] = failure.code
                        }
                    }
                    guard done, !state.resumed else { return nil }
                    state.resumed = true
                    return state.failures
                }
                if let finished {
                    continuation.resume(returning: finished)
                }
            }
        }
    }

    private static func failures(_ errors: CFArray) -> [Failure] {
        (errors as? [CFError] ?? []).map { error in
            let info = CFErrorCopyUserInfo(error) as? [String: Any] ?? [:]
            let urls = info[kCTFontManagerErrorFontURLsKey as String] as? [URL] ?? []
            return Failure(code: CFErrorGetCode(error), urls: urls)
        }
    }
}
