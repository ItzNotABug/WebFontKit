import Foundation
import os

/// A one-shot latch. `wait()` returns once `open()` has been called, and throws
/// `CancellationError` if the waiting task is cancelled first, so a test that
/// hits its time limit ends instead of hanging the process.
public final class AsyncLatch: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var isOpen: Bool {
        state.withLock { $0.isOpen }
    }

    public func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.isOpen = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    public func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    if state.isOpen { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// An append-only record that tests can wait on: `wait(until:)` returns once the
/// recorded elements satisfy the condition, and honours cancellation.
public final class AsyncRecorder<Element: Sendable>: Sendable {
    private struct Waiter {
        var condition: @Sendable ([Element]) -> Bool
        var continuation: CheckedContinuation<[Element], any Error>
    }

    private struct State {
        var elements: [Element] = []
        var waiters: [UUID: Waiter] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var elements: [Element] {
        state.withLock { $0.elements }
    }

    public func append(_ element: Element) {
        let ready = state.withLock { state -> [(CheckedContinuation<[Element], any Error>, [Element])] in
            state.elements.append(element)
            var ready: [(CheckedContinuation<[Element], any Error>, [Element])] = []
            for (id, waiter) in state.waiters where waiter.condition(state.elements) {
                ready.append((waiter.continuation, state.elements))
                state.waiters[id] = nil
            }
            return ready
        }
        for (continuation, elements) in ready {
            continuation.resume(returning: elements)
        }
    }

    /// Waits until `condition` holds for the elements recorded so far, and returns them.
    @discardableResult
    public func wait(until condition: @escaping @Sendable ([Element]) -> Bool) async throws -> [Element] {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Element], any Error>) in
                let immediate: Result<[Element], any Error>? = state.withLock { state in
                    if condition(state.elements) { return .success(state.elements) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.waiters[id] = Waiter(condition: condition, continuation: continuation)
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}
