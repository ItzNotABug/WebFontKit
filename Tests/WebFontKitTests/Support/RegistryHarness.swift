import Foundation
@testable import WebFontKit
import WebFontKitTestSupport

extension Harness {
    var store: Store {
        Store(directory: directory.store, files: files)
    }

    /// A registry on this harness's fakes. A second one on the same directory is a simulated relaunch.
    func makeRegistry() -> Registry {
        Registry(registrar: registrar, files: files, logSink: logSink)
    }

    /// Writes a fixture into the store under the name a load would give it.
    @discardableResult
    func storeFont(
        _ fixture: String, family: String, style: FontStyle = .regular,
        cacheKey: String? = nil, version: String? = nil, modified: Date? = nil
    ) throws -> StoredFace {
        let key = cacheKey ?? TestDataSource { _ in Data() }.cacheKey(for: FontRequest(family: family, style: style))
        let url = store.url(for: StoredFileName.font(family: family, style: style, cacheKey: key, version: version))
        try Fixtures.data(fixture).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        let info = CoreTextFonts.descriptorInfo(at: url)!
        return StoredFace(
            key: FaceKey(family: family, style: style), url: url,
            keyHash: StoredFileName.keyHash(family: family, style: style, cacheKey: key),
            postScriptName: info.postScriptName, glyphCount: info.glyphCount, familyName: info.familyName
        )
    }

    /// The default `cacheKey` of any source that does not override it.
    static let defaultKey: @Sendable (FaceKey) -> String = { key in
        TestDataSource { _ in Data() }.cacheKey(for: FontRequest(family: key.family, style: key.style))
    }
}
