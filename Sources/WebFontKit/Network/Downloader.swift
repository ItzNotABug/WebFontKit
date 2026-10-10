import Foundation

/// The library's own session, used when the app configures none.
enum LibrarySession {
    /// No cache: `.ephemeral` brings an in-memory one. The request timeout is idle time between bytes.
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()
}

/// A data task, never a download task: a cancelled download task leaves a temp file we can't reach.
enum Downloader {
    /// Decoded bytes: gzip makes `Content-Length` meaningless.
    static let sizeCap = 64 * 1024 * 1024

    /// A body read into memory, with the status and content type it came with.
    struct Response: Sendable {
        var statusCode: Int
        var contentType: String?
        var body: Data
    }

    /// File work runs on the download's own queue; the delegate queue may be main.
    @concurrent
    static func download(
        _ request: URLRequest,
        session: URLSession,
        into directory: URL,
        fileOperations: any FileOperations,
        cap: Int = sizeCap
    ) async throws -> URL {
        let delegate = DataTaskDelegate(mode: .store(directory: directory, files: fileOperations), cap: cap)
        guard case .file(let url) = try await run(request, session: session, delegate: delegate) else {
            preconditionFailure("store mode always finishes with a file")
        }
        return url
    }

    /// For the public `fetch` helpers only.
    @concurrent
    static func data(for request: URLRequest, session: URLSession, cap: Int = sizeCap) async throws -> Data {
        let delegate = DataTaskDelegate(mode: .memory(acceptsAnyStatus: false), cap: cap)
        guard case .memory(let response) = try await run(request, session: session, delegate: delegate) else {
            preconditionFailure("memory mode always finishes in memory")
        }
        return response.body
    }

    /// Keeps any status, so a CSS2 400 page's title can be read.
    @concurrent
    static func response(for request: URLRequest, session: URLSession, cap: Int) async throws -> Response {
        let delegate = DataTaskDelegate(mode: .memory(acceptsAnyStatus: true), cap: cap)
        guard case .memory(let response) = try await run(request, session: session, delegate: delegate) else {
            preconditionFailure("memory mode always finishes in memory")
        }
        return response
    }

    private static func run(
        _ request: URLRequest,
        session: URLSession,
        delegate: DataTaskDelegate
    ) async throws -> DataTaskDelegate.Outcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation)
                let task = session.dataTask(with: request)
                task.delegate = delegate
                let cancelled = delegate.attach(task)
                task.resume()
                if cancelled {
                    task.cancel()
                }
            }
        } onCancel: {
            delegate.cancelByCaller()
        }
    }
}

/// Its callbacks may run on the main queue, so file work hops to its own serial queue.
final class DataTaskDelegate: NSObject, URLSessionDataDelegate, Sendable {
    enum Mode: Sendable {
        case store(directory: URL, files: any FileOperations)
        case memory(acceptsAnyStatus: Bool)
    }

    enum Outcome: Sendable {
        case file(URL)
        case memory(Downloader.Response)
    }

    /// URLSession reports every cancel as `.cancelled`, so record which one was ours.
    private enum CancelReason: Sendable {
        case status(Int)
        case cap
        case storage
    }

    private struct State: Sendable {
        var continuation: CheckedContinuation<Outcome, any Error>?
        var task: URLSessionDataTask?
        var callerCancelled = false
        var reason: CancelReason?
        var statusCode = 200
        var contentType: String?
        var received = 0
        var body = Data()
    }

    private final class Partial: @unchecked Sendable {
        var url: URL?
        var handle: FileHandle?
    }

    private let mode: Mode
    private let cap: Int
    private let state = Locked(State())
    private let queue = DispatchQueue(label: "WebFontKit.download")
    private let partial = Partial()

    init(mode: Mode, cap: Int) {
        self.mode = mode
        self.cap = cap
    }

    func start(_ continuation: CheckedContinuation<Outcome, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func attach(_ task: URLSessionDataTask) -> Bool {
        state.withLock { state in
            state.task = task
            return state.callerCancelled
        }
    }

    func cancelByCaller() {
        let task = state.withLock { state in
            state.callerCancelled = true
            return state.task
        }
        task?.cancel()
    }

    private func cancel(_ reason: CancelReason) {
        let task = state.withLock { state in
            if state.reason == nil {
                state.reason = reason
            }
            return state.task
        }
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 200
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")
        state.withLock { state in
            state.statusCode = statusCode
            state.contentType = contentType
        }

        // An uncompressed body that declares a length over the cap fails before any of it arrives;
        // a compressed one is checked as it decodes, since the cap counts decoded bytes.
        let declared = response.expectedContentLength
        if http?.value(forHTTPHeaderField: "Content-Encoding") == nil, declared > Int64(cap) {
            state.withLock { $0.reason = .cap }
            completionHandler(.cancel)
            return
        }

        let succeeded = (200..<300).contains(statusCode)
        switch mode {
        case .memory(let acceptsAnyStatus):
            if !succeeded, !acceptsAnyStatus {
                state.withLock { $0.reason = .status(statusCode) }
                completionHandler(.cancel)
                return
            }
            if declared > 0 {
                state.withLock { $0.body.reserveCapacity(Int(declared)) }
            }
        case .store(let directory, let files):
            if !succeeded {
                state.withLock { $0.reason = .status(statusCode) }
                completionHandler(.cancel)
                return
            }
            queue.async { [partial] in
                let url = directory.appending(component: StoredFileName.partial())
                partial.url = url
                do {
                    partial.handle = try files.createPartial(at: url)
                } catch {
                    self.cancel(.storage)
                }
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let storesInMemory: Bool
        if case .memory = mode { storesInMemory = true } else { storesInMemory = false }
        let cap = cap
        let overCap = state.withLock { state -> Bool? in
            if state.reason != nil { return nil }
            state.received += data.count
            if state.received > cap {
                state.reason = .cap
                return true
            }
            if storesInMemory {
                state.body.append(data)
            }
            return false
        }
        guard let overCap else { return }
        if overCap {
            dataTask.cancel()
            return
        }
        if case .store(_, let files) = mode {
            queue.async { [partial] in
                guard let handle = partial.handle else { return }
                do {
                    try files.append(data, to: handle)
                } catch {
                    partial.handle = nil
                    try? files.close(handle)
                    self.cancel(.storage)
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        switch mode {
        case .memory:
            finish(error: error)
        case .store(_, let files):
            // After every chunk the queue already holds.
            queue.async { [partial] in
                var storageFailed = false
                if let handle = partial.handle {
                    partial.handle = nil
                    do {
                        try files.close(handle)
                    } catch {
                        storageFailed = true
                    }
                }
                let result = self.result(error: error, storageFailed: storageFailed)
                if case .failure = result, let url = partial.url {
                    _ = try? files.delete(at: url)
                }
                self.resume(with: result)
            }
        }
    }

    private func finish(error: (any Error)?) {
        resume(with: result(error: error, storageFailed: false))
    }

    private func result(error: (any Error)?, storageFailed: Bool) -> Result<Outcome, any Error> {
        let (reason, callerCancelled, statusCode, contentType, body) = state.withLock { state in
            (state.reason, state.callerCancelled, state.statusCode, state.contentType, state.body)
        }
        if let reason {
            switch reason {
            case .status(let status): return .failure(ErrorMapping.map(status: status))
            case .cap: return .failure(WebFontError.invalidFont)
            case .storage: return .failure(WebFontError.storage)
            }
        }
        if let error {
            guard let urlError = error as? URLError else { return .failure(WebFontError.network(.unknown)) }
            // Only the caller's own cancel is a cancellation. A cancel it did not ask for (a delegate
            // cancelling a challenge, an invalidated session) is a network failure, so the load ends.
            if urlError.code == .cancelled && callerCancelled { return .failure(CancellationError()) }
            return .failure(ErrorMapping.map(urlError))
        }
        if storageFailed {
            return .failure(WebFontError.storage)
        }
        switch mode {
        case .store:
            guard let url = partial.url else { return .failure(WebFontError.storage) }
            return .success(.file(url))
        case .memory:
            return .success(.memory(Downloader.Response(statusCode: statusCode, contentType: contentType, body: body)))
        }
    }

    private func resume(with result: Result<Outcome, any Error>) {
        let continuation = state.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}
