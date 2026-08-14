import Foundation

/// Resumes a continuation exactly once.
///
/// `NWConnection.stateUpdateHandler` is not a one-shot callback: a connection
/// can report `.failed` and then `.cancelled`, and the handler runs on a
/// dispatch queue rather than an actor. Resuming a `CheckedContinuation` twice
/// is a hard crash, so the guard has to be genuinely thread-safe — a captured
/// `var resumed` flag would be both a data race and, under Swift 6, a compile
/// error.
final class OneShot<Value: Sendable>: @unchecked Sendable {

    private var continuation: CheckedContinuation<Value, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }
}
