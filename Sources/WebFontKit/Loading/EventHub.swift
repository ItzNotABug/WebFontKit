import Foundation

/// Fans events out to every listener. Each listener keeps the newest 256; the
/// latest `.warmedUp` is replayed first to a new one.
final class EventHub: Sendable {
    private struct State {
        var listeners: [UUID: AsyncStream<WebFontEvent>.Continuation] = [:]
        var lastWarmedUp: WebFontEvent?
    }

    private let state = Locked(State())

    func stream() -> AsyncStream<WebFontEvent> {
        let (stream, continuation) = AsyncStream<WebFontEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        let replay = state.withLock { state -> WebFontEvent? in
            state.listeners[id] = continuation
            return state.lastWarmedUp
        }
        if let replay {
            continuation.yield(replay)
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.listeners.removeValue(forKey: id) }
        }
        return stream
    }

    func emit(_ events: [WebFontEvent]) {
        guard !events.isEmpty else { return }
        let listeners = state.withLock { state -> [AsyncStream<WebFontEvent>.Continuation] in
            if let warmedUp = events.last(where: { if case .warmedUp = $0 { true } else { false } }) {
                state.lastWarmedUp = warmedUp
            }
            return Array(state.listeners.values)
        }
        for event in events {
            for listener in listeners {
                listener.yield(event)
            }
        }
    }

    func emit(_ event: WebFontEvent) {
        emit([event])
    }
}
