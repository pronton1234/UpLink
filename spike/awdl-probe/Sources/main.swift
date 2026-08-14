import Foundation
import Network

// THROWAWAY SPIKE — see spike/README.md.
//
// The measurement instrument for Phase 0. Run it on the Mac; it advertises a
// peer-to-peer Bonjour service, accepts one connection, and then reports, once
// a second, whether the link is still alive and how fast it is moving bytes.
//
// The question it answers is not "does AWDL work" — it does — but "does an iOS
// Network Extension keep an AWDL link up once the phone is locked and the app
// is gone". That is why the interesting output is the GAP lines: every second
// of silence is a second the bridge would have been dead.

let serviceType = "_uplinkspike._tcp"
let queue = DispatchQueue(label: "spike")

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}

func log(_ message: String) {
    print("[\(timestamp())] \(message)")
    fflush(stdout)
}

/// Tracks liveness and throughput, and shouts about gaps.
final class LinkMonitor: @unchecked Sendable {

    private let lock = NSLock()
    private var bytesThisSecond = 0
    private var lastByteAt = Date()
    private var connectedAt: Date?
    private var longestGap: TimeInterval = 0
    private var totalBytes = 0

    func recordConnected() {
        lock.lock(); defer { lock.unlock() }
        connectedAt = Date()
        lastByteAt = Date()
    }

    func record(bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        let gap = Date().timeIntervalSince(lastByteAt)
        if gap > 2 {
            longestGap = max(longestGap, gap)
            log("GAP  \(String(format: "%.1f", gap))s of silence — link stalled and recovered")
        }
        bytesThisSecond += bytes
        totalBytes += bytes
        lastByteAt = Date()
    }

    func tick() {
        lock.lock()
        let bytes = bytesThisSecond
        bytesThisSecond = 0
        let silence = Date().timeIntervalSince(lastByteAt)
        let uptime = connectedAt.map { Date().timeIntervalSince($0) } ?? 0
        let total = totalBytes
        let worst = longestGap
        lock.unlock()

        guard connectedAt != nil else { return }

        if silence > 2 {
            log("DEAD \(String(format: "%.0f", silence))s since last byte — this is the failure mode we care about")
        } else {
            let mbps = Double(bytes * 8) / 1_000_000
            log(String(
                format: "LIVE up %.0fs · %.1f Mbps · %.1f MB total · worst gap %.1fs",
                uptime, mbps, Double(total) / 1_048_576, worst
            ))
        }
    }
}

let monitor = LinkMonitor()

func runListener() throws {
    let parameters = NWParameters.tcp
    // The whole point of the spike.
    parameters.includePeerToPeer = true

    let listener = try NWListener(using: parameters)
    listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: serviceType)

    listener.newConnectionHandler = { connection in
        log("CONN accepted from \(connection.endpoint)")
        monitor.recordConnected()

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // awdl0 here means the link really is peer-to-peer Wi-Fi and
                // not the local network quietly standing in for it — worth
                // checking, because a result over infrastructure Wi-Fi would
                // answer a different question than the one being asked.
                let interfaces = connection.currentPath?.availableInterfaces
                    .map(\.name).joined(separator: ",") ?? "?"
                log("READY interfaces: \(interfaces)")
                if !(interfaces.contains("awdl")) {
                    log("WARN no awdl interface — this link is NOT peer-to-peer, result will not answer the question")
                }
            case let .failed(error):
                log("FAIL \(error)")
            case .cancelled:
                log("GONE connection cancelled")
            default:
                break
            }
        }

        @Sendable func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    monitor.record(bytes: data.count)
                    // Echo, so the phone can measure the round trip too.
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
                if isComplete || error != nil {
                    log("GONE peer closed (\(error.map(String.init(describing:)) ?? "clean"))")
                    return
                }
                pump()
            }
        }

        connection.start(queue: queue)
        pump()
    }

    listener.stateUpdateHandler = { state in
        if case .ready = state {
            log("WAIT advertising \(serviceType) over peer-to-peer — start the phone side now")
        }
        if case let .failed(error) = state {
            log("FAIL listener: \(error)")
            exit(1)
        }
    }

    listener.start(queue: queue)
}

// MARK: - Entry

log("UpLink AWDL probe — throwaway Phase 0 instrument")
log("Leave this running for at least 10 minutes with the phone LOCKED.")
log("Record the worst gap in docs/device-test-log.md.")
log("")

do {
    try runListener()
} catch {
    log("FAIL could not start: \(error)")
    exit(1)
}

let ticker = DispatchSource.makeTimerSource(queue: queue)
ticker.schedule(deadline: .now() + 1, repeating: 1)
ticker.setEventHandler { monitor.tick() }
ticker.resume()

dispatchMain()
