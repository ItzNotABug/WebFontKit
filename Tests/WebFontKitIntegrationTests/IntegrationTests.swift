import CoreText
import Foundation
import Testing
import WebFontKitTestSupport

/// The parent of every test that touches real CoreText registration. CoreText is
/// process-global and `.serialized` orders tests only within one suite, so every
/// other suite in this target joins this one through an extension.
@Suite(.serialized, .timeLimit(.minutes(1)), .registrationLeakCheck)
struct IntegrationTests {}

extension IntegrationTests {
    @Suite
    struct SmokeTests {
        @Test("a fixture copied into a run directory registers and unregisters for the process")
        func registersAndUnregisters() throws {
            let directory = TempDirectory()
            let file = directory.url.appendingPathComponent("Lato-Regular.wfkfont")
            try Fixtures.data(Fixtures.latoRegular).write(to: file)

            var error: Unmanaged<CFError>?
            #expect(CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error))
            let font = CTFontCreateWithName("Lato-Regular" as CFString, 12, nil)
            #expect(CTFontCopyPostScriptName(font) as String == "Lato-Regular")
            #expect((CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
            #expect(CTFontManagerUnregisterFontsForURL(file as CFURL, .process, &error))
        }
    }
}

/// Wraps the whole integration suite once. It fails the run if any test left a
/// font registered: the available family names must be unchanged, and no
/// fixture's PostScript name may resolve to a file under the run root.
struct RegistrationLeakCheck: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }

    static let fixturePostScriptNames = [
        "Lato-Regular", "Lato-Bold", "Lato-Italic", "Lato-BoldItalic",
        "Lobster-Regular", "NotoSansKannada-Regular", "BebasNeue-Regular",
    ]

    @concurrent
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable @concurrent () async throws -> Void
    ) async throws {
        let before = Self.familyNames()
        try await function()

        #expect(Self.familyNames() == before, "a test left a font family registered")
        let runRoot = TempDirectory.runRoot.path
        for name in Self.fixturePostScriptNames {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            let path = (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.resolvingSymlinksInPath().path ?? ""
            #expect(!path.hasPrefix(runRoot), "\(name) still resolves to \(path)")
        }
        #if os(macOS)
        let urls = (CTFontManagerCopyAvailableFontURLs() as? [URL]) ?? []
        let leaked = urls.filter { $0.resolvingSymlinksInPath().path.hasPrefix(runRoot) }
        #expect(leaked.isEmpty, "registered files under the run root: \(leaked)")
        #endif
    }

    private static func familyNames() -> [String] {
        ((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []).sorted()
    }
}

extension Trait where Self == RegistrationLeakCheck {
    static var registrationLeakCheck: Self { RegistrationLeakCheck() }
}
