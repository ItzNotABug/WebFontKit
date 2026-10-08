import Foundation
import os

/// A canned answer for one stubbed request.
public struct StubResponse: Sendable {
    /// Where the stub pauses until the test calls `release`.
    public enum Hold: Sendable, Equatable {
        case none
        /// Nothing is sent until release.
        case beforeResponse
        /// The headers and the first `n` body bytes are sent; the rest waits for release.
        case afterBytes(Int)
    }

    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    /// When set, the request fails with this error instead of answering.
    public var error: URLError.Code?
    public var hold: Hold
    public var chunkSize: Int

    public init(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data(),
        error: URLError.Code? = nil,
        hold: Hold = .none,
        chunkSize: Int = 64 * 1024
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.error = error
        self.hold = hold
        self.chunkSize = chunkSize
    }

    public static func failure(_ code: URLError.Code) -> StubResponse {
        StubResponse(error: code)
    }

    public static func font(_ data: Data, hold: Hold = .none) -> StubResponse {
        StubResponse(headers: ["Content-Type": "font/ttf"], body: data, hold: hold)
    }

    public static func css(_ text: String, hold: Hold = .none) -> StubResponse {
        StubResponse(headers: ["Content-Type": "text/css; charset=utf-8"], body: Data(text.utf8), hold: hold)
    }

    public static func html(statusCode: Int, _ text: String) -> StubResponse {
        StubResponse(statusCode: statusCode, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(text.utf8))
    }
}

/// What the stub saw of one request.
public struct StubRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let cachePolicy: URLRequest.CachePolicy
    /// True when the request arrived on a `URLSessionDownloadTask`.
    public let isDownloadTask: Bool
}

/// One entry of the stub's ordered log.
public enum StubEvent: Sendable {
    case started(StubRequest)
    case released(URL)
    /// `stopLoading` arrived; `beforeFinish` is true when the response was not complete,
    /// which is how a test sees a cancel (URLSession also stops a finished request).
    case stopped(URL, beforeFinish: Bool)
    case finished(URL)

    public var url: URL {
        switch self {
        case .started(let request): request.url
        case .released(let url), .stopped(let url, _), .finished(let url): url
        }
    }
}

/// One test's stubbed server. Its sessions carry a unique token header, so the
/// stub routes each request to this server's table: tests never share state,
/// and `URLProtocol.registerClass` is never used.
public final class StubServer: Sendable {
    static let tokenHeader = "X-WebFontKit-Stub-Token"

    public let token = UUID().uuidString
    /// Every request's start, release, stop and finish, in order.
    public let events = AsyncRecorder<StubEvent>()

    private struct State {
        var routes: [String: StubResponse] = [:]
        var fallback: (@Sendable (URLRequest) -> StubResponse)?
        var held: [(url: URL, release: @Sendable () -> Void)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {
        StubURLProtocol.register(self)
    }

    deinit {
        StubURLProtocol.unregister(token)
    }

    /// A configuration that routes through this server. `base` defaults to `.ephemeral`.
    public func configuration(base: URLSessionConfiguration = .ephemeral) -> URLSessionConfiguration {
        let configuration = base
        configuration.protocolClasses = [StubURLProtocol.self]
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers[Self.tokenHeader] = token
        configuration.httpAdditionalHeaders = headers
        return configuration
    }

    public func makeSession(
        base: URLSessionConfiguration = .ephemeral,
        delegateQueue: OperationQueue? = nil
    ) -> URLSession {
        URLSession(configuration: configuration(base: base), delegate: nil, delegateQueue: delegateQueue)
    }

    public func respond(to url: String, with response: StubResponse) {
        state.withLock { $0.routes[url] = response }
    }

    public func respond(to url: URL, with response: StubResponse) {
        respond(to: url.absoluteString, with: response)
    }

    /// Answers every request no route matches. Without one, such a request gets 404.
    public func respondToOthers(with handler: @escaping @Sendable (URLRequest) -> StubResponse) {
        state.withLock { $0.fallback = handler }
    }

    /// Every request the stub has started, in order.
    public var requests: [StubRequest] {
        events.elements.compactMap {
            if case .started(let request) = $0 { return request }
            return nil
        }
    }

    public func requestCount(for url: String) -> Int {
        requests.count { $0.url.absoluteString == url }
    }

    /// Waits until `count` requests have started whose URL satisfies `matching`.
    @discardableResult
    public func waitForRequests(
        count: Int = 1,
        matching: @escaping @Sendable (URL) -> Bool = { _ in true }
    ) async throws -> [StubRequest] {
        let events = try await events.wait { events in
            events.count {
                if case .started(let request) = $0 { return matching(request.url) }
                return false
            } >= count
        }
        return events.compactMap {
            if case .started(let request) = $0, matching(request.url) { return request }
            return nil
        }
    }

    /// Waits until `stopLoading` arrived for a request to `url` before its response finished.
    public func waitForCancel(of url: String) async throws {
        try await events.wait { events in
            events.contains {
                if case .stopped(let stopped, true) = $0 { return stopped.absoluteString == url }
                return false
            }
        }
    }

    /// Sends the rest of every held response to `url`.
    public func release(_ url: String) {
        let releases = state.withLock { state -> [@Sendable () -> Void] in
            let matching = state.held.filter { $0.url.absoluteString == url }
            state.held.removeAll { $0.url.absoluteString == url }
            return matching.map(\.release)
        }
        for release in releases {
            release()
        }
    }

    /// Sends the rest of every held response.
    public func releaseAll() {
        let releases = state.withLock { state -> [@Sendable () -> Void] in
            defer { state.held = [] }
            return state.held.map(\.release)
        }
        for release in releases {
            release()
        }
    }

    func response(for request: URLRequest) -> StubResponse {
        state.withLock { state in
            if let url = request.url?.absoluteString, let response = state.routes[url] {
                return response
            }
            return state.fallback?(request) ?? StubResponse(statusCode: 404)
        }
    }

    func hold(_ url: URL, release: @escaping @Sendable () -> Void) {
        state.withLock { $0.held.append((url, release)) }
    }
}

/// The `URLProtocol` behind `StubServer`. It never blocks in `startLoading`:
/// every protocol instance in the process shares one CFNetwork thread, so a held
/// response is delivered later on the run loop that started it.
public final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct WeakServer {
        weak var server: StubServer?
    }

    private static let servers = OSAllocatedUnfairLock(initialState: [String: WeakServer]())

    static func register(_ server: StubServer) {
        servers.withLock { $0[server.token] = WeakServer(server: server) }
    }

    static func unregister(_ token: String) {
        servers.withLock { $0[token] = nil }
    }

    private struct Progress {
        var stopped = false
        var finished = false
        var sentResponse = false
        var bytesSent = 0
    }

    private let progress = OSAllocatedUnfairLock(initialState: Progress())

    override public class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func startLoading() {
        guard let url = request.url else { return }
        let token = request.value(forHTTPHeaderField: StubServer.tokenHeader)
        guard let token, let server = Self.servers.withLock({ $0[token]?.server }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let seen = StubRequest(
            url: url,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            cachePolicy: request.cachePolicy,
            isDownloadTask: task is URLSessionDownloadTask
        )
        let response = server.response(for: request)
        if let code = response.error {
            server.events.append(.started(seen))
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        // A held request is registered before its start is recorded, so a test
        // that releases as soon as it sees the start always finds the hold. The
        // release runs on this run loop, after this method returns.
        switch response.hold {
        case .none:
            server.events.append(.started(seen))
            deliver(response, upTo: response.body.count, server: server)
        case .beforeResponse:
            holdRest(of: response, server: server)
            server.events.append(.started(seen))
        case .afterBytes(let count):
            holdRest(of: response, server: server)
            deliver(response, upTo: min(count, response.body.count), server: server)
            server.events.append(.started(seen))
        }
    }

    override public func stopLoading() {
        let finished = progress.withLock { progress in
            progress.stopped = true
            return progress.finished
        }
        if let url = request.url, let server = server() {
            server.events.append(.stopped(url, beforeFinish: !finished))
        }
    }

    private func server() -> StubServer? {
        guard let token = request.value(forHTTPHeaderField: StubServer.tokenHeader) else { return nil }
        return Self.servers.withLock { $0[token]?.server }
    }

    private func holdRest(of response: StubResponse, server: StubServer) {
        guard let url = request.url else { return }
        let runLoop = RunLoopBox(CFRunLoopGetCurrent())
        server.hold(url) { [self] in
            CFRunLoopPerformBlock(runLoop.runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
                server.events.append(.released(url))
                deliver(response, upTo: response.body.count, server: server)
            }
            CFRunLoopWakeUp(runLoop.runLoop)
        }
    }

    /// Sends the headers (once) and the body up to `end`, finishing when `end`
    /// is the whole body. Runs on the protocol's own thread.
    private func deliver(_ response: StubResponse, upTo end: Int, server: StubServer) {
        guard let url = request.url, let client else { return }
        let start = progress.withLock { progress -> Int? in
            if progress.stopped { return nil }
            return progress.bytesSent
        }
        guard let start else { return }

        let sendHeaders = progress.withLock { progress in
            defer { progress.sentResponse = true }
            return !progress.sentResponse
        }
        if sendHeaders {
            let http = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: response.headers)!
            client.urlProtocol(self, didReceive: http, cacheStoragePolicy: .allowed)
        }

        var offset = start
        while offset < end {
            if progress.withLock({ $0.stopped }) { return }
            let next = min(offset + max(response.chunkSize, 1), end)
            client.urlProtocol(self, didLoad: response.body.subdata(in: offset..<next))
            offset = next
            let sent = offset
            progress.withLock { $0.bytesSent = sent }
        }

        guard end == response.body.count else { return }
        let shouldFinish = progress.withLock { progress -> Bool in
            if progress.stopped { return false }
            progress.finished = true
            return true
        }
        if shouldFinish {
            client.urlProtocolDidFinishLoading(self)
            server.events.append(.finished(url))
        }
    }
}

private struct RunLoopBox: @unchecked Sendable {
    let runLoop: CFRunLoop

    init(_ runLoop: CFRunLoop) {
        self.runLoop = runLoop
    }
}
