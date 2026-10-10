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

    /// Writes a fixture into this harness's store under the name a load would give it.
    @discardableResult
    func storeFont(
        _ fixture: String, family: String, style: FontStyle = .regular,
        cacheKey: String? = nil, version: String? = nil, modified: Date? = nil
    ) throws -> StoredFace {
        try Fixtures.storeFont(fixture, family: family, style: style, in: directory.store,
                               cacheKey: cacheKey, version: version, modified: modified)
    }

    /// The default `cacheKey` of any source that does not override it.
    static let defaultKey: @Sendable (FaceKey) -> String = { key in
        TestDataSource { _ in Data() }.cacheKey(for: FontRequest(family: key.family, style: key.style))
    }
}
