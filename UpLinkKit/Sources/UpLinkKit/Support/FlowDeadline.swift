import Foundation

/// How long any single step of claiming a flow may take.
///
/// **Nothing on this path may wait forever.** `handleNewFlow` returning `true`
/// means the extension owns that connection; the system will not deliver it,
/// and the app has no timeout of its own beyond its own patience. A step that
/// hangs therefore produces a flow owned by us and serviced by nobody, which
/// the user experiences as "no connectivity" while both ends report a healthy
/// session. Failing fast is strictly better: the app sees a closed connection
/// and can retry or report an error.
///
/// This defect class has caused three separate outages — a TLS handshake that
/// resumed only on `.ready`, a destination dial that hung on `.waiting`, and a
/// channel send with no deadline. See `docs/REGRESSIONS.md`.
public let flowStepTimeout: Duration = .seconds(10)

public struct FlowTimeout: Error, CustomStringConvertible {
    public let step: String
    public init(step: String) { self.step = step }
    public var description: String { "timed out in \(step)" }
}

/// Runs `operation`, or throws if it does not finish in time.
public func withFlowDeadline<T: Sendable>(
    _ label: String,
    timeout: Duration = flowStepTimeout,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw FlowTimeout(step: label)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
