import Foundation

/// A downloaded face CoreText accepted, still an unrenamed `.wfkpart`.
struct ValidatedFace: Sendable, Equatable {
    var partialURL: URL
    var postScriptName: String
    var glyphCount: Int
    var familyName: String
    var version: String?
}

/// Shared work stops at a validated partial; committing is the loader's.
struct FaceFetcher: Sendable {
    var session: URLSession
    var directory: URL
    var files: any FileOperations
    var registrar: any FontRegistrar
    var logSink: any LogSink

    @concurrent
    func fetchResolved(_ url: URL) async throws -> ValidatedFace {
        guard url.scheme?.lowercased() == "https" else { throw WebFontError.invalidFont }
        let partial = try await Downloader.download(
            CSS2.request(for: url), session: session, into: directory, fileOperations: files
        )
        var face = try validate(partial)
        face.version = CSS2.version(of: url)
        return face
    }

    @concurrent
    func fetchCustom(_ font: FontRequest, from source: any FontSource) async throws -> ValidatedFace {
        // The default source goes through CSS2's `resolve`, then `fetchResolved`; never here.
        precondition(!(source is DefaultFontSource), "the default source is resolved, never fetched")
        let partial: URL
        if let remote = source as? any RemoteFontSource {
            let request: URLRequest
            do {
                request = try await remote.request(for: font)
            } catch {
                throw ErrorMapping.mapSourceError(error, family: font.family, logSink: logSink)
            }
            guard request.url?.scheme?.lowercased() == "https" else { throw WebFontError.invalidFont }
            partial = try await Downloader.download(request, session: session, into: directory, fileOperations: files)
        } else {
            let data: Data
            do {
                data = try await source.fetch(font)
            } catch {
                throw ErrorMapping.mapSourceError(error, family: font.family, logSink: logSink)
            }
            try Task.checkCancellation()
            partial = directory.appendingPathComponent(StoredFileName.partial())
            do {
                try files.write(data, to: partial)
            } catch {
                _ = try? files.delete(at: partial)
                throw WebFontError.storage
            }
        }
        return try validate(partial)
    }

    /// Excluded from backup before it is ever renamed.
    func validate(_ partial: URL) throws -> ValidatedFace {
        guard let info = registrar.faceInfo(at: partial) else {
            _ = try? files.delete(at: partial)
            throw WebFontError.invalidFont
        }
        do {
            try files.setExcludedFromBackup(at: partial)
        } catch {
            _ = try? files.delete(at: partial)
            throw WebFontError.storage
        }
        return ValidatedFace(partialURL: partial, postScriptName: info.postScriptName, glyphCount: info.glyphCount, familyName: info.familyName)
    }
}
