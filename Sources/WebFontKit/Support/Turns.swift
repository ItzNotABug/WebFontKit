import Foundation

/// First-come turns per key. Not cancellable: a holder always finishes its insert or undo.
final class Turns<Key: Hashable & Sendable>: Sendable {
    private struct State {
        var held: Set<Key> = []
        var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]
    }

    private let state = Locked(State())

    func take(_ key: Key) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let granted = state.withLock { state -> Bool in
                if state.held.contains(key) {
                    state.waiters[key, default: []].append(continuation)
                    return false
                }
                state.held.insert(key)
                return true
            }
            if granted {
                continuation.resume()
            }
        }
    }

    /// Ascending order, so two multi-key holders can't deadlock.
    func take(all keys: [Key]) async where Key: Comparable {
        for key in Set(keys).sorted() {
            await take(key)
        }
    }

    func release(_ key: Key) {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            // Mutated in place: copying the queue out would copy it on every handoff.
            guard state.waiters[key]?.isEmpty == false else {
                state.held.remove(key)
                return nil
            }
            let next = state.waiters[key]!.removeFirst()
            if state.waiters[key]!.isEmpty { state.waiters[key] = nil }
            return next
        }
        next?.resume()
    }

    func release(all keys: [Key]) {
        for key in Set(keys) {
            release(key)
        }
    }

    func with<Result: Sendable>(_ key: Key, _ body: () async throws -> Result) async rethrows -> Result {
        await take(key)
        defer { release(key) }
        return try await body()
    }
}
