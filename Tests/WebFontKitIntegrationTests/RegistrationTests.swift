import CoreText
import Foundation
import SwiftUI
import Testing
@testable import WebFontKit
import WebFontKitTestSupport
#if canImport(UIKit)
import UIKit
#endif

extension IntegrationTests {
    @Suite
    final class RegistrationTests {
        let directory = TempDirectory()
        let logSink = RecordingLogSink()
        let registrar = CoreTextRegistrar()
        private var registered: [URL] = []

        init() throws {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        }

        deinit {
            // Unregister synchronously; the async call would land during the next test.
            for url in registered {
                CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            }
        }

        var store: Store { Store(directory: directory.store, files: DiskFileOperations()) }

        func registry() -> Registry {
            Registry(registrar: registrar, files: DiskFileOperations(), logSink: logSink)
        }

        /// Stores a fixture and remembers it, so `deinit` unregisters it whatever the test did.
        func copy(_ fixture: String, family: String, style: FontStyle = .regular, into directory: URL? = nil) throws -> StoredFace {
            let face = try Fixtures.storeFont(fixture, family: family, style: style, in: directory ?? store.directory)
            registered.append(face.url)
            return face
        }

        func resolvedFile(_ postScriptName: String) -> String? {
            let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
            guard CTFontCopyPostScriptName(font) as String == postScriptName else { return nil }
            return (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.resolvingSymlinksInPath().path
        }

        @Test("registering the same file twice answers 105 on both systems")
        func alreadyRegistered() async throws {
            let face = try copy(Fixtures.latoRegular, family: "Lato")
            #expect(await registrar.register(urls: [face.url]).isEmpty)
            #expect(await registrar.register(urls: [face.url]) == [face.url: CoreTextCode.alreadyRegistered])
        }

        @Test("a second copy and another version of a face: 305 on iOS, registered on macOS")
        func duplicatedName() async throws {
            let first = try copy(Fixtures.lobster, family: "Lobster")
            let duplicate = try copy(Fixtures.lobster, family: "Lobster", into: directory.url.appending(component: "second", directoryHint: .isDirectory))
            let older = try copy(Fixtures.lobsterV20, family: "Lobster", into: directory.url.appending(component: "third", directoryHint: .isDirectory))
            #expect(await registrar.register(urls: [first.url]).isEmpty)
            #if os(iOS)
            #expect(await registrar.register(urls: [duplicate.url]) == [duplicate.url: CoreTextCode.duplicatedName])
            #expect(await registrar.register(urls: [older.url]) == [older.url: CoreTextCode.duplicatedName])
            #expect(resolvedFile("Lobster-Regular") == first.url.resolvingSymlinksInPath().path)
            #else
            #expect(await registrar.register(urls: [duplicate.url]).isEmpty)
            #expect(await registrar.register(urls: [older.url]).isEmpty)
            #endif
        }

        @Test("through the registry, a second file with a held name is never registered")
        func registryCheckFirst() async throws {
            let registry = registry()
            let first = try copy(Fixtures.lobster, family: "Lobster")
            let second = try copy(Fixtures.lobsterV20, family: "lobster", into: directory.url.appending(component: "second", directoryHint: .isDirectory))
            _ = await registry.register(first, epochs: nil, store: store)
            let result = await registry.register(second, epochs: nil, store: store)
            #expect(result == .added(RegistryEntry(postScriptName: "Lobster-Regular", kind: .file(url: second.url, keyHash: second.keyHash, registeredHere: false))))
            #expect(resolvedFile("Lobster-Regular") == first.url.resolvingSymlinksInPath().path)
            #expect(!logSink.entries.contains { $0.message.contains("system font") })
            _ = try await registry.remove(family: nil, directories: [store.directory])
        }

        @Test("a file that is not a font fails registration")
        func notAFont() async throws {
            let url = store.url(for: "Lato@400n@0000000000000000.wfkfont")
            try Fixtures.data("Corrupt/NotFound.ttf").write(to: url)
            let failures = await registrar.register(urls: [url])
            // iOS reads the bytes and rejects them; macOS does not recognise the format at all.
            #if os(iOS)
            #expect(failures == [url: CTFontManagerError.invalidFontData.rawValue])
            #else
            #expect(failures == [url: CTFontManagerError.unrecognizedFormat.rawValue])
            #endif
        }

        #if os(iOS)
        // iOS only: macOS can drop the opened face under cache pressure and draw LastResort.
        @Test("a face opened once keeps drawing after its file is deleted")
        func deletedAfterOpen() async throws {
            let registry = registry()
            let face = try copy(Fixtures.latoBold, family: "Lato", style: .bold)
            _ = await registry.register(face, epochs: nil, store: store)
            let saved = try Data(contentsOf: face.url)
            try FileManager.default.removeItem(at: face.url)

            let font = CTFontCreateWithName("Lato-Bold" as CFString, 24, nil)
            #expect(CTFontGetGlyphCount(font) == 272)

            try saved.write(to: face.url)
            _ = try await registry.remove(family: nil, directories: [store.directory])
        }
        #endif

        @Test("a file deleted before its open is .storage, and nothing stays registered")
        func deletedBeforeOpen() async throws {
            let face = try copy(Fixtures.latoItalic, family: "Lato", style: .italic)
            let deleting = DeletingRegistrar(base: registrar)
            let registry = Registry(registrar: deleting, files: DiskFileOperations(), logSink: logSink)
            #expect(await registry.register(face, epochs: nil, store: store) == .failed(.storage))
            #if os(macOS)
            // macOS keeps a deleted file registered (unregister answers 201) until a file is back at its path.
            try Fixtures.data(Fixtures.latoItalic).write(to: face.url)
            _ = await registrar.unregister(urls: [face.url])
            #endif
            #expect(resolvedFile("Lato-Italic") == nil)
        }

        #if os(iOS)
        @Test("a system font with Google's PostScript name: a system-collision entry and a marker (305 mode)")
        func systemCollision305() async throws {
            let registry = registry()
            let face = try copy(Fixtures.notoSansKannada, family: "Noto Sans Kannada")

            let result = await registry.register(face, epochs: nil, store: store)

            #expect(result == .added(RegistryEntry(postScriptName: "NotoSansKannada-Regular", kind: .system)))
            #expect(!FileManager.default.fileExists(atPath: face.url.path))
            let marker = store.url(for: "Noto%20Sans%20Kannada@400n@system.wfkmark")
            #expect(store.markerName(at: marker) == "NotoSansKannada-Regular")
            #expect(!(resolvedFile("NotoSansKannada-Regular") ?? "").hasPrefix(TempDirectory.runRoot.path))
            #expect(logSink.entries.contains { $0.message.contains("Noto Sans Kannada") && $0.message.contains("same PostScript name") })
            #expect(registry.checkMarker(at: marker, store: store) == .valid(postScriptName: "NotoSansKannada-Regular"))
        }

        @Test("a system font whose name differs: registered, logged as silent, the family name still Apple's")
        func systemCollisionSilent() async throws {
            let registry = registry()
            let face = try copy(Fixtures.bebasNeue, family: "Bebas Neue")

            let result = await registry.register(face, epochs: nil, store: store)

            #expect(registry.entry(for: face.key)?.registeredHere == true, "\(result)")
            #expect(resolvedFile("BebasNeue-Regular") == face.url.resolvingSymlinksInPath().path)
            #expect(UIFont(name: "Bebas Neue", size: 24)?.fontName == "BebasNeue")
            #expect(logSink.entries.contains { $0.message.contains("Bebas Neue") && $0.message.contains("another PostScript name") })
            _ = try await registry.remove(family: nil, directories: [store.directory])
        }

        @MainActor
        @Test("with the four Lato faces registered, the family name reaches regular and bold")
        func lookupByFamilyName() async throws {
            let registry = registry()
            for (fixture, style) in [(Fixtures.latoRegular, FontStyle.regular), (Fixtures.latoBold, .bold), (Fixtures.latoItalic, .italic), (Fixtures.latoBoldItalic, .boldItalic)] {
                _ = await registry.register(try copy(fixture, family: "Lato", style: style), epochs: nil, store: store)
            }
            #expect(UIFont(name: "Lato", size: 24)?.fontName == "Lato-Regular")
            let bold = UIFontDescriptor(fontAttributes: [.family: "Lato"]).withSymbolicTraits(.traitBold)
            #expect(bold.map { UIFont(descriptor: $0, size: 24).fontName } == "Lato-Bold")
            #expect(render(Font.custom("Lato", size: 24).bold()) == render(Font.custom("Lato-Bold", size: 24)))
            _ = try await registry.remove(family: nil, directories: [store.directory])
        }

        @MainActor
        private func render(_ font: Font) -> Data? {
            let renderer = ImageRenderer(content: Text("Hamburgefonstiv").font(font).foregroundStyle(.black).padding())
            renderer.scale = 1
            return renderer.uiImage?.pngData()
        }
        #endif
    }
}

/// Deletes each file between its registration and the open, as another process's `remove` would.
private struct DeletingRegistrar: FontRegistrar {
    let base: CoreTextRegistrar

    func register(urls: [URL]) async -> [URL: Int] {
        let failures = await base.register(urls: urls)
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        return failures
    }

    func unregister(urls: [URL]) async -> [URL: Int] { await base.unregister(urls: urls) }
    func faceInfo(at url: URL) -> FaceInfo? { base.faceInfo(at: url) }
    func openFace(postScriptName: String) -> (postScriptName: String, fileURL: URL?, glyphCount: Int) { base.openFace(postScriptName: postScriptName) }
    func activeFace(postScriptName: String) -> (postScriptName: String, fileURL: URL?)? { base.activeFace(postScriptName: postScriptName) }
    func faceForFamily(_ family: String) -> (familyName: String, fileURL: URL?) { base.faceForFamily(family) }
}
