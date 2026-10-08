import SwiftUI
import WebFontKit

/// The app's view of the store, kept current from `events`: the saved faces, and a removal
/// count per family so views showing a removed family start over.
@MainActor
@Observable
final class FontLibrary {
    private(set) var fonts: [DownloadedFont] = []
    private(set) var error: WebFontError?
    private var removals: [String: Int] = [:]

    var totalBytes: Int64 { Int64(fonts.reduce(0) { $0 + $1.byteCount }) }
    var familyCount: Int { Set(fonts.map(\.family)).count }

    /// Changes when `family` is removed. A view keyed by it gets a new identity, so its
    /// `.font(web:)` loads again instead of reporting "Ready" over the system font.
    func generation(of family: String) -> Int {
        removals[family.lowercased(), default: 0]
    }

    /// Read live, so a view asking as its phase turns `.loaded` never sees the list one event
    /// behind; `fonts` is read too, so the view updates again on the next event.
    func face(_ family: String, style: FontStyle) -> DownloadedFont? {
        _ = fonts
        return WebFonts.shared.downloaded.first {
            $0.family.caseInsensitiveCompare(family) == .orderedSame && $0.style == style
        }
    }

    /// One subscription for the app's lifetime. `downloaded` is served from memory, so
    /// refreshing on every event is cheap.
    func listen() async {
        refresh()
        for await event in WebFonts.shared.events {
            if case .removed(let family) = event {
                removals[family.lowercased(), default: 0] += 1
            }
            refresh()
        }
    }

    func remove(_ family: String) async {
        await perform { try await WebFonts.shared.remove(family) }
    }

    func removeAll() async {
        await perform { try await WebFonts.shared.removeAll() }
    }

    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
            error = nil
        } catch let failure as WebFontError {
            error = failure
        } catch {
            // Cancelled: nothing to report.
        }
        refresh()
    }

    private func refresh() {
        let latest = WebFonts.shared.downloaded
        if latest != fonts { fonts = latest }
    }
}
