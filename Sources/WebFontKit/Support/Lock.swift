import OSLog

/// Not recursive: re-entering crashes. Only read or write state inside.
struct Locked<State: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<State>

    init(_ initialState: State) {
        lock = OSAllocatedUnfairLock(initialState: initialState)
    }

    func withLock<Result: Sendable>(_ body: @Sendable (inout State) throws -> Result) rethrows -> Result {
        try lock.withLock { state in
            #if DEBUG
            LockHolder.enter()
            defer { LockHolder.leave() }
            #endif
            return try body(&state)
        }
    }
}

#if DEBUG
/// Lets the test log sink check that nothing logs under the lock. Debug builds only.
enum LockHolder {
    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    static var isHeldByCurrentThread: Bool {
        depth > 0
    }

    fileprivate static func enter() {
        depth += 1
    }

    fileprivate static func leave() {
        depth -= 1
    }

    private static var depth: Int {
        get { Int(bitPattern: pthread_getspecific(key)) }
        set { pthread_setspecific(key, UnsafeRawPointer(bitPattern: newValue)) }
    }
}
#endif
