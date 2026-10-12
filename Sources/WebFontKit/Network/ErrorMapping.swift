import Foundation
import OSLog

/// Maps HTTP statuses, `URLError`s and custom-source errors to `WebFontError`.
enum ErrorMapping {
    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
    ]

    static func map(_ error: URLError) -> WebFontError {
        offlineCodes.contains(error.code) ? .offline : .network(error.code)
    }

    static func map(status: Int) -> WebFontError {
        status == 404 || status == 400 ? .notFound : .server(statusCode: status)
    }

    /// Cancellation is never mapped.
    static func mapSourceError(_ error: any Error, family: String, logSink: any LogSink) -> any Error {
        switch error {
        case let error as WebFontError:
            return error
        case is CancellationError:
            return error
        case let error as URLError:
            if error.code == .cancelled, Task.isCancelled {
                return CancellationError()
            }
            return map(error)
        default:
            logSink.log("source", .error, "A custom source for \(family) threw \(error), which is neither WebFontError nor URLError")
            return WebFontError.network(.unknown)
        }
    }
}

extension WebFontError {
    /// Google no longer has the file: a 400 or 404 (both `.notFound`), 403 or 410.
    var meansGone: Bool {
        switch self {
        case .notFound, .server(statusCode: 403), .server(statusCode: 410): true
        default: false
        }
    }
}
