import CoreText
import Foundation
import os
@testable import WebFontKit

/// An in-memory stand-in for CoreText registration. It registers nothing
/// process-wide, but reads PostScript names and glyph counts from the real
/// files, and answers lookups of names it does not hold from real CoreText
/// (which registers nothing either).
///
/// It behaves like iOS: a second file with a PostScript name it already holds
/// gets 305, and so does a file whose name a font outside the fake answers to
/// on iOS (a system font, or another process's registration).
public final class FakeRegistrar: FontRegistrar, Sendable {
    public enum Method: String, Sendable {
        case register, unregister, postScriptName, openFace, activeFace, faceForFamily
    }

    public struct Call: Sendable {
        public let method: Method
        public let urls: [URL]
        public let postScriptName: String?
        public let onMainThread: Bool
        /// The library's table at the moment of the call, if the test observes it.
        public let table: Set<String>?
    }

    /// CoreText's codes (`CTFontManagerError`).
    public enum Code {
        public static let fileNotFound = Int(CTFontManagerError.fileNotFound.rawValue)
        public static let invalidFontData = Int(CTFontManagerError.invalidFontData.rawValue)
        public static let alreadyRegistered = Int(CTFontManagerError.alreadyRegistered.rawValue)
        public static let notRegistered = Int(CTFontManagerError.notRegistered.rawValue)
        public static let duplicatedName = Int(CTFontManagerError.duplicatedName.rawValue)
    }

    private struct Face {
        var postScriptName: String
        var glyphCount: Int
    }

    private struct State {
        var calls: [Call] = []
        var registered: [URL: Face] = [:]
        var holdsRegister = false
        var heldRelease: AsyncLatch?
        var scriptedRegisterCodes: [URL: Int] = [:]
        var scriptedFaces: [URL: Face] = [:]
        var scriptedActiveFaces: [String: (postScriptName: String, fileURL: URL?)?] = [:]
        var failingOpens: Set<String> = []
        var tableProbe: (@Sendable () -> Set<String>)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Signalled each time a held `register(urls:)` arrives.
    public let heldRegisterArrivals = AsyncRecorder<[URL]>()

    public init() {}

    public var calls: [Call] {
        state.withLock { $0.calls }
    }

    public func calls(_ method: Method) -> [Call] {
        calls.filter { $0.method == method }
    }

    /// The files the fake currently holds as registered.
    public var registeredURLs: Set<URL> {
        state.withLock { Set($0.registered.keys) }
    }

    /// The registered file that answers to `postScriptName`, if any.
    public func registeredURL(for postScriptName: String) -> URL? {
        state.withLock { state in
            state.registered.first { $0.value.postScriptName == postScriptName }?.key
        }
    }

    /// Holds every later `register(urls:)` until `releaseRegister()`. A held call
    /// suspends; it never blocks a thread.
    public func holdRegister() {
        state.withLock {
            $0.holdsRegister = true
            $0.heldRelease = AsyncLatch()
        }
    }

    /// Lets held `register(urls:)` calls finish, registering the files as they are on disk now.
    public func releaseRegister() {
        let latch = state.withLock { state -> AsyncLatch? in
            state.holdsRegister = false
            return state.heldRelease
        }
        latch?.open()
    }

    /// Makes `register(urls:)` report `code` for `url`. Code 0 reports success even if
    /// the file is gone by then, with the face read now, as if CoreText registered it first.
    public func scriptRegister(_ url: URL, code: Int) {
        let face = CoreTextFonts.descriptorInfo(at: url).map { Face(postScriptName: $0.postScriptName, glyphCount: $0.glyphCount) }
        state.withLock {
            $0.scriptedRegisterCodes[url] = code
            if let face { $0.scriptedFaces[url] = face }
        }
    }

    /// Real CoreText answers for a file in this test run come from the integration
    /// suite's registrations in the same process, never from this fake's; they are ignored.
    private static func isRunFile(_ url: URL?) -> Bool {
        guard let path = url?.resolvingSymlinksInPath().path else { return false }
        return path.hasPrefix(TempDirectory.runRoot.resolvingSymlinksInPath().path)
    }

    /// Makes `activeFace(postScriptName:)` answer `answer` for `name`.
    public func scriptActiveFace(_ name: String, answer: (postScriptName: String, fileURL: URL?)?) {
        state.withLock { $0.scriptedActiveFaces[name] = .some(answer) }
    }

    /// Records `probe()` with every later call, so a test can see the table at each CoreText call.
    public func observeTable(_ probe: @escaping @Sendable () -> Set<String>) {
        state.withLock { $0.tableProbe = probe }
    }

    /// Makes `openFace(postScriptName:)` answer with a fallback font for `name`.
    public func failOpen(_ name: String) {
        state.withLock { _ = $0.failingOpens.insert(name) }
    }

    private func record(_ method: Method, urls: [URL] = [], name: String? = nil) {
        let probe = state.withLock { $0.tableProbe }
        let call = Call(method: method, urls: urls, postScriptName: name, onMainThread: pthread_main_np() != 0, table: probe?())
        state.withLock { $0.calls.append(call) }
    }

    public func register(urls: [URL]) async -> [URL: Int] {
        record(.register, urls: urls)
        let held = state.withLock { $0.holdsRegister ? $0.heldRelease : nil }
        if let held {
            heldRegisterArrivals.append(urls)
            try? await held.wait()
        }

        var errors: [URL: Int] = [:]
        for url in urls {
            if let code = state.withLock({ $0.scriptedRegisterCodes[url] }) {
                if code == 0 {
                    state.withLock { state in
                        if let face = state.scriptedFaces[url] { state.registered[url] = face }
                    }
                } else {
                    errors[url] = code
                }
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                errors[url] = Code.fileNotFound
                continue
            }
            guard let info = CoreTextFonts.descriptorInfo(at: url) else {
                errors[url] = Code.invalidFontData
                continue
            }
            let code = state.withLock { state -> Int? in
                if state.registered[url] != nil { return Code.alreadyRegistered }
                if state.registered.values.contains(where: { $0.postScriptName == info.postScriptName }) {
                    return Code.duplicatedName
                }
                return nil
            }
            if let code {
                errors[url] = code
                continue
            }
            #if os(iOS)
            if CoreTextFonts.activeFace(postScriptName: info.postScriptName) != nil {
                errors[url] = Code.duplicatedName
                continue
            }
            #endif
            state.withLock { $0.registered[url] = Face(postScriptName: info.postScriptName, glyphCount: info.glyphCount) }
        }
        return errors
    }

    public func unregister(urls: [URL]) async -> [URL: Int] {
        record(.unregister, urls: urls)
        return state.withLock { state in
            var errors: [URL: Int] = [:]
            for url in urls where state.registered.removeValue(forKey: url) == nil {
                errors[url] = Code.notRegistered
            }
            return errors
        }
    }

    public func faceInfo(at url: URL) -> FaceInfo? {
        record(.postScriptName, urls: [url])
        return CoreTextFonts.descriptorInfo(at: url)
    }

    public func openFace(postScriptName: String) -> (postScriptName: String, fileURL: URL?, glyphCount: Int) {
        record(.openFace, name: postScriptName)
        let (failing, registered) = state.withLock { state in
            (
                state.failingOpens.contains(postScriptName),
                state.registered.first { $0.value.postScriptName == postScriptName }
            )
        }
        if failing {
            return CoreTextFonts.openFace(postScriptName: "WebFontKitFakeNoSuchFont")
        }
        let real = CoreTextFonts.openFace(postScriptName: postScriptName)
        if let (url, face) = registered {
            let lastResortGlyphCount = 7
            let exists = FileManager.default.fileExists(atPath: url.path)
            return (face.postScriptName, url, exists ? face.glyphCount : lastResortGlyphCount)
        }
        return Self.isRunFile(real.fileURL) ? CoreTextFonts.openFace(postScriptName: "WebFontKitFakeNoSuchFont") : real
    }

    public func activeFace(postScriptName: String) -> (postScriptName: String, fileURL: URL?)? {
        record(.activeFace, name: postScriptName)
        let (scripted, registered) = state.withLock { state in
            (
                state.scriptedActiveFaces[postScriptName],
                state.registered.first { $0.value.postScriptName == postScriptName }?.key
            )
        }
        if let scripted { return scripted }
        if let registered { return (postScriptName, registered) }
        let real = CoreTextFonts.activeFace(postScriptName: postScriptName)
        return Self.isRunFile(real?.fileURL) ? nil : real
    }

    public func faceForFamily(_ family: String) -> (familyName: String, fileURL: URL?) {
        record(.faceForFamily, name: family)
        return CoreTextFonts.faceForFamily(family)
    }
}
