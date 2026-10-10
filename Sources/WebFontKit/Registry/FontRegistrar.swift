import CoreText
import Foundation
import os

/// What a font file says about itself.
struct FaceInfo: Equatable {
    var postScriptName: String
    var glyphCount: Int
    var familyName: String
}

/// Behind a seam so unit tests never register fonts process-wide.
protocol FontRegistrar: Sendable {
    /// Returns the CoreText error code of each file that failed.
    func register(urls: [URL]) async -> [URL: Int]

    func unregister(urls: [URL]) async -> [URL: Int]

    /// Nil when CoreText finds no font in the file.
    func faceInfo(at url: URL) -> FaceInfo?

    /// Reads one glyph so CoreText opens the file while it exists.
    func openFace(postScriptName: String) -> (postScriptName: String, fileURL: URL?, glyphCount: Int)

    /// Nil when the name resolves to another font (CoreText's fallback).
    func activeFace(postScriptName: String) -> (postScriptName: String, fileURL: URL?)?

    /// What a family name resolves to: its family and file (silent system collisions, iOS).
    func faceForFamily(_ family: String) -> (familyName: String, fileURL: URL?)
}

extension FontRegistrar {
    /// Right after a register, CoreText can still answer a name with its
    /// fallback for a while under load (past 0.5 s once on macOS 26.4), so it retries with
    /// doubling waits, about 2 s in all; a healthy register never waits.
    func openRegisteredFace(postScriptName: String) async -> (postScriptName: String, fileURL: URL?, glyphCount: Int) {
        var opened = openFace(postScriptName: postScriptName)
        for delay in [2, 4, 8, 16, 32, 64, 128, 256, 512, 1024] where opened.postScriptName != postScriptName {
            try? await Task.sleep(for: .milliseconds(delay))
            opened = openFace(postScriptName: postScriptName)
        }
        return opened
    }
}

/// Direct CoreText reads, shared by the real registrar and the test fake.
enum CoreTextFonts {
    /// Concurrent lookups of unregistered names could block every cooperative thread in
    /// synchronous XPC to the font server, while fonts were being registered (macOS 26.4).
    private static let serial = OSAllocatedUnfairLock()

    static func descriptorInfo(at url: URL) -> FaceInfo? {
        serial.withLock {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let first = descriptors.first
            else { return nil }
            let font = CTFontCreateWithFontDescriptor(first, 12, nil)
            return FaceInfo(postScriptName: CTFontCopyPostScriptName(font) as String, glyphCount: CTFontGetGlyphCount(font),
                            familyName: CTFontCopyFamilyName(font) as String)
        }
    }

    static func openFace(postScriptName: String) -> (postScriptName: String, fileURL: URL?, glyphCount: Int) {
        serial.withLock {
            let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
            var glyph = CGGlyph(0)
            var character = UniChar(0x41)
            if !CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) {
                glyph = 0
            }
            _ = CTFontCreatePathForGlyph(font, glyph, nil)
            return (
                CTFontCopyPostScriptName(font) as String,
                CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
                CTFontGetGlyphCount(font)
            )
        }
    }

    static func faceForFamily(_ family: String) -> (familyName: String, fileURL: URL?) {
        serial.withLock {
            let font = CTFontCreateWithName(family as CFString, 12, nil)
            return (CTFontCopyFamilyName(font) as String, CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
        }
    }

    static func activeFace(postScriptName: String) -> (postScriptName: String, fileURL: URL?)? {
        serial.withLock {
            let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
            let resolved = CTFontCopyPostScriptName(font) as String
            guard resolved == postScriptName else { return nil }
            return (resolved, CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
        }
    }
}
