import Foundation
import Network

/// The part of an `NWPath` that matters for "do I need to re-advertise myself".
///
/// A raw `NWPath` fires far more often than it changes in any way we care
/// about — every DHCP renewal, every metric update. Rebuilding a Bonjour
/// advertisement on each of those is as harmful as never rebuilding it: the
/// phone's browser sees the service vanish and reappear, and the port changes
/// every time (`NWListener` will not rebind a port it just released).
///
/// So the trigger is a *signature*: the path's status plus the set of
/// interfaces it can actually use. When those are unchanged, nothing about the
/// Mac's reachability changed and there is nothing to re-advertise.
public struct PathSignature: Sendable, Equatable, CustomStringConvertible {

    public let status: String
    /// Sorted so ordering churn from the framework is not mistaken for change.
    public let interfaces: [String]

    public init(status: String, interfaces: [String]) {
        self.status = status
        self.interfaces = interfaces.sorted()
    }

    public init(path: NWPath) {
        self.init(
            status: String(describing: path.status),
            interfaces: path.availableInterfaces.map(\.name)
        )
    }

    public var description: String {
        "\(status) [\(interfaces.joined(separator: ","))]"
    }
}
