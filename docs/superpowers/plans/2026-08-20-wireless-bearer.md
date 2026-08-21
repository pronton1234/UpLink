# Wireless Bearer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the USB cable with a Mac-hosted Wi-Fi access point the phone joins, so a Mac with no network of its own reaches the internet through the phone's cellular data with no cable and no laptop interaction.

**Architecture:** The Mac hosts a 5 GHz WPA2 network with nothing behind it, sourced from the product's own dead-end `RouteProvider` tunnel. A privileged helper installed once with `SMAppService` owns that access point. The phone joins with `NEHotspotConfiguration`, its tunnel extension advertises `_uplink._tcp` on the link, and the Mac discovers and dials it. Everything above the byte pipe — TLS-PSK, multiplexer, pairing, flow control — is unchanged, because the bearer is coupled at exactly one endpoint.

**Tech Stack:** Swift 6 (strict concurrency), Network.framework, NetworkExtension, ServiceManagement, swift-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-20-wireless-bearer-design.md`

## Global Constraints

- Swift language mode v6, `SWIFT_STRICT_CONCURRENCY: complete`. Every new kit type is `Sendable`.
- Deployment targets: macOS 15.0, iOS 17.0 (`project.yml`). `SMAppService.daemon` needs macOS 13+, satisfied.
- Kit code is pure Swift and must run under `swift test` with no device, simulator, or `xcodebuild`.
- Every fixed defect gets a permanent test in `UpLinkKit/Tests/UpLinkRegressionTests/` and an entry in `docs/REGRESSIONS.md`. Read that file before fixing anything.
- Decisions belong in `UpLinkKit`, not in app targets. The Mac app has no test target, so logic placed there is unverifiable — this is why `LinkStatus` exists.
- `requiredInterfaceType = .cellular` in `CellularDialer` is never removed or weakened.
- Bundle IDs, keychain groups and log subsystems live only in `UpLinkIdentifiers`.
- Work happens on branch `wireless`. USB stays functional until Task 12.

---

## File Structure

**Created in `UpLinkKit/Sources/UpLinkKit/`:**
- `Transport/WirelessBearer.swift` — which bearer carries the peer link, and which interfaces destination dials must therefore refuse.
- `Transport/PeerDiscovery.swift` — Bonjour browse for the phone over the AP link, with an injectable staleness window.
- `AccessPoint/AccessPointConfiguration.swift` — pure model of the Internet Sharing configuration. No I/O.
- `AccessPoint/AccessPointRequest.swift` — the request/reply values the app and the helper exchange.

**Modified in `UpLinkKit/Sources/UpLinkKit/`:**
- `Transport/CellularDialer.swift` — egress prohibitions become bearer-derived.
- `Transport/NetworkTransport.swift` — listener binds the link rather than loopback.
- `Transport/MacSessionClient.swift:281` — dial a discovered endpoint.
- `Transport/LinkStatus.swift` — new presence and status cases for the access point.

**Created in `Sources/`:**
- `UpLinkHelper/main.swift` — root LaunchDaemon. Writes the NAT preferences, kickstarts `com.apple.NetworkSharing`, owns sleep policy.
- `UpLinkHelper/HelperListener.swift` — XPC surface.

**Modified in `Sources/`:**
- `UpLinkMac/MenuBarModel.swift`, `UpLinkMac/DevicesView.swift` — access-point states.
- `UpLinkiOS/BridgeController.swift`, `UpLinkiOS/PairingViews.swift` — the join.
- `UpLinkTunnelExtension/PacketTunnelProvider.swift` — advertise on the link.
- `project.yml` — the helper target.

---

### Task 1: The bearer, and what it forbids

The spec's one substantive addition. `CellularDialer` prohibits `.wiredEthernet` so the phone cannot egress back up the cable into the Mac. Once the phone is associated to a network the Mac hosts, `.wifi` is that same hazard on a different interface. Making this a property of the bearer means the rule cannot drift out of sync with the transport.

**Files:**
- Create: `UpLinkKit/Sources/UpLinkKit/Transport/WirelessBearer.swift`
- Test: `UpLinkKit/Tests/UpLinkKitTests/WirelessBearerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `WirelessBearer` (`.hostedAP`, `.peerToPeer`, `.usbmux`), `WirelessBearer.preferenceOrder: [WirelessBearer]`, `WirelessBearer.prohibitedEgressInterfaces: [NWInterface.InterfaceType]`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Network
@testable import UpLinkKit

@Suite("Which interfaces a bearer forbids for egress")
struct WirelessBearerTests {

    @Test("The hosted access point forbids Wi-Fi, because the peer link IS Wi-Fi")
    func hostedAPForbidsWiFi() {
        #expect(WirelessBearer.hostedAP.prohibitedEgressInterfaces.contains(.wifi))
    }

    @Test("Every bearer still forbids wired, which is the cable hazard")
    func everyBearerForbidsWired() {
        for bearer in WirelessBearer.allCases {
            #expect(bearer.prohibitedEgressInterfaces.contains(.wiredEthernet))
        }
    }

    @Test("No bearer forbids cellular, which is the only path that may carry data")
    func noBearerForbidsCellular() {
        for bearer in WirelessBearer.allCases {
            #expect(!bearer.prohibitedEgressInterfaces.contains(.cellular))
        }
    }

    @Test("No bearer forbids loopback, which the integration suites depend on")
    func noBearerForbidsLoopback() {
        for bearer in WirelessBearer.allCases {
            #expect(!bearer.prohibitedEgressInterfaces.contains(.loopback))
        }
    }

    @Test("The hosted access point is preferred, and the cable is last")
    func preferenceOrder() {
        #expect(WirelessBearer.preferenceOrder == [.hostedAP, .peerToPeer, .usbmux])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd UpLinkKit && swift test --filter WirelessBearerTests`
Expected: FAIL — "cannot find 'WirelessBearer' in scope"

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import Network

/// Which link carries the peer connection between the Mac and the phone.
///
/// The bearer owns one decision beyond its own name: **the interface it rides
/// on is the interface destination dials must refuse.**
///
/// `CellularDialer` has always prohibited `.wiredEthernet`, because plugging
/// the phone into the Mac gives the phone a wired interface and a Mac with any
/// route to share turns the bridge into a loop — Mac to phone and straight back
/// to the Mac. The wireless bearer recreates that hazard exactly, one interface
/// over: the phone is now associated to a network the Mac hosts.
///
/// Keeping the rule here rather than as a literal in the dialer is what stops
/// the two from drifting apart when a bearer is added.
public enum WirelessBearer: String, Sendable, CaseIterable, Equatable {
    /// The Mac hosts an access point with nothing behind it. The target.
    case hostedAP
    /// AWDL. Opportunistic only — the kernel disables its timers when the Mac
    /// has no infrastructure association, which is the deployment target. See
    /// docs/REGRESSIONS.md.
    case peerToPeer
    /// The cable. Retained until the wireless path passes the traffic matrix.
    case usbmux

    public static var preferenceOrder: [WirelessBearer] { [.hostedAP, .peerToPeer, .usbmux] }

    /// Interfaces a proxied destination connection may never use.
    ///
    /// Loopback is deliberately absent: a destination on the phone's own
    /// loopback is not a way around the bridge, and banning it breaks every
    /// integration test that points "the internet" at a local server.
    public var prohibitedEgressInterfaces: [NWInterface.InterfaceType] {
        switch self {
        case .hostedAP, .peerToPeer:
            // The peer link is Wi-Fi. Egress over Wi-Fi is egress back into the
            // Mac, or onto a network the user did not ask to be on.
            [.wifi, .wiredEthernet]
        case .usbmux:
            [.wiredEthernet]
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd UpLinkKit && swift test --filter WirelessBearerTests`
Expected: PASS, 5 tests

- [ ] **Step 5: Commit**

```bash
git add UpLinkKit/Sources/UpLinkKit/Transport/WirelessBearer.swift UpLinkKit/Tests/UpLinkKitTests/WirelessBearerTests.swift
git commit -m "Make the forbidden egress interface a property of the bearer"
```

---

### Task 2: The dialer honours the bearer

`CellularDialer.parameters(for:requiredInterface:)` is already `internal` rather than private specifically so the product's central claim can be asserted directly — the existing comment says a test that rebuilt these parameters itself would prove nothing. Extend that seam rather than adding a new one.

**Files:**
- Modify: `UpLinkKit/Sources/UpLinkKit/Transport/CellularDialer.swift`
- Test: `UpLinkKit/Tests/UpLinkRegressionTests/EgressLoopRegressionTests.swift`

**Interfaces:**
- Consumes: `WirelessBearer.prohibitedEgressInterfaces` from Task 1.
- Produces: `CellularDialer.init(queue:requiredInterface:bearer:)` with `bearer` defaulting to `.hostedAP`; `CellularDialer.parameters(for:requiredInterface:bearer:)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Network
@testable import UpLinkKit

// SYMPTOM (anticipated, and the reason this test exists before the bug):
// with the phone associated to an access point the Mac hosts, a destination
// dial satisfied over Wi-Fi leaves the phone, crosses the AP, and arrives back
// at the Mac. The user bypasses nothing, and the egress report says `.wifi`
// only after the fact.
//
// `requiredInterfaceType` does not prevent this. It is documented as a
// preference Network.framework may fall back from, which is exactly how a
// Wi-Fi fallback was once observed being reported as a successful cellular
// dial. Prohibiting the interface is the half that cannot be negotiated away.

@Suite("Regression: a destination dial can never re-enter the Mac")
struct EgressLoopRegressionTests {

    private let destination = StreamOpen(proto: .tcp, host: "example.com", port: 443)

    @Test("Over the hosted access point, Wi-Fi is prohibited outright")
    func hostedAPProhibitsWiFi() {
        let parameters = CellularDialer.parameters(
            for: destination, requiredInterface: .cellular, bearer: .hostedAP
        )
        #expect(parameters.prohibitedInterfaceTypes?.contains(.wifi) == true)
    }

    @Test("Cellular is still required, which is the product's whole claim")
    func cellularIsStillRequired() {
        let parameters = CellularDialer.parameters(
            for: destination, requiredInterface: .cellular, bearer: .hostedAP
        )
        #expect(parameters.requiredInterfaceType == .cellular)
    }

    @Test("Loopback stays reachable, so the integration suites still run")
    func loopbackIsNotProhibited() {
        let parameters = CellularDialer.parameters(
            for: destination, requiredInterface: nil, bearer: .hostedAP
        )
        #expect(parameters.prohibitedInterfaceTypes?.contains(.loopback) != true)
    }

    @Test("The cable's prohibition is unchanged, so nothing regresses on USB")
    func cableStillProhibitsWiredOnly() {
        let parameters = CellularDialer.parameters(
            for: destination, requiredInterface: .cellular, bearer: .usbmux
        )
        #expect(parameters.prohibitedInterfaceTypes?.contains(.wiredEthernet) == true)
        #expect(parameters.prohibitedInterfaceTypes?.contains(.wifi) != true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd UpLinkKit && swift test --filter EgressLoopRegressionTests`
Expected: FAIL — extra argument 'bearer' in call

- [ ] **Step 3: Write minimal implementation**

In `CellularDialer`, add a stored `bearer` and thread it through. Replace the hard-coded prohibition:

```swift
    private let bearer: WirelessBearer

    /// - Parameter bearer: which link carries the peer connection. Determines
    ///   the interfaces a destination dial must refuse — see ``WirelessBearer``.
    public init(
        queue: DispatchQueue,
        requiredInterface: NWInterface.InterfaceType? = .cellular,
        bearer: WirelessBearer = .hostedAP
    ) {
        self.queue = queue
        self.requiredInterface = requiredInterface
        self.bearer = bearer
    }
```

In `connect(to:)`, pass it:

```swift
        let parameters = Self.parameters(
            for: destination, requiredInterface: requiredInterface, bearer: bearer
        )
```

And in `parameters`, replace the literal `parameters.prohibitedInterfaceTypes = [.wiredEthernet]` with:

```swift
    static func parameters(
        for destination: StreamOpen,
        requiredInterface: NWInterface.InterfaceType?,
        bearer: WirelessBearer
    ) -> NWParameters {
```

```swift
        // The hazard is structural, not specific to any one cable or radio: the
        // peer link's own interface is a path from the phone back into the Mac.
        // `WirelessBearer` owns which interface that is, so adding a bearer
        // cannot leave this line behind. Loopback is deliberately absent — see
        // WirelessBearer.prohibitedEgressInterfaces.
        parameters.prohibitedInterfaceTypes = bearer.prohibitedEgressInterfaces
```

Keep the existing explanatory comment above it; extend rather than delete it.

- [ ] **Step 4: Run the full suite**

Run: `cd UpLinkKit && swift test`
Expected: PASS. Existing callers of `CellularDialer(queue:)` compile unchanged because `bearer` defaults.

- [ ] **Step 5: Record the regression and commit**

Add to `docs/REGRESSIONS.md` under a new heading, following the file's existing table format: the shape is "the peer link's own interface is an egress path back into the Mac", guarded by `EgressLoopRegressionTests`.

```bash
git add UpLinkKit/Sources/UpLinkKit/Transport/CellularDialer.swift UpLinkKit/Tests/UpLinkRegressionTests/EgressLoopRegressionTests.swift docs/REGRESSIONS.md
git commit -m "Refuse egress on whatever interface the peer link is riding"
```

---

### Task 3: "Not bridging" learns the access point

`LinkStatus` exists because "not bridging" had four causes with different remedies and collapsing them made the menu bar say "Waiting for iPhone" at a user whose iPhone was plugged in. The wireless bearer adds two more causes, and one of them — the access point being down — is the only one in the whole matrix the user can personally fix.

**Files:**
- Modify: `UpLinkKit/Sources/UpLinkKit/Transport/LinkStatus.swift`
- Test: `UpLinkKit/Tests/UpLinkKitTests/LinkStatusAccessPointTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `LinkPresence.accessPointDown`, `LinkPresence.noPeerDiscovered`, `LinkStatus.accessPointDown`, `LinkStatus.waitingForPhone`. `LinkStatus.resolve` keeps its signature.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import UpLinkKit

@Suite("Not bridging, over the air")
struct LinkStatusAccessPointTests {

    @Test("An access point that is down outranks everything the user cannot fix")
    func accessPointDownIsReported() {
        let status = LinkStatus.resolve(
            presence: .accessPointDown, isPaired: true, userDisconnected: false
        )
        #expect(status == .accessPointDown)
    }

    @Test("Access point down is reported even when the user switched off")
    func accessPointDownOutranksSwitchedOff() {
        // Switched-off is only meaningful once there is something to switch off.
        let status = LinkStatus.resolve(
            presence: .accessPointDown, isPaired: true, userDisconnected: true
        )
        #expect(status == .accessPointDown)
    }

    @Test("An access point that is up with no phone on it is a distinct state")
    func noPeerDiscovered() {
        let status = LinkStatus.resolve(
            presence: .noPeerDiscovered, isPaired: true, userDisconnected: false
        )
        #expect(status == .waitingForPhone)
    }

    @Test("Every status has a headline, so a case cannot be added silently")
    func everyStatusHasAHeadline() {
        let all: [LinkStatus] = [
            .accessPointDown, .waitingForPhone, .waitingForCable,
            .deviceNotResponding, .deviceNotPaired, .connecting,
            .pairingLost, .switchedOff, .failed("x"),
        ]
        for status in all {
            #expect(!status.headline.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd UpLinkKit && swift test --filter LinkStatusAccessPointTests`
Expected: FAIL — type 'LinkPresence' has no member 'accessPointDown'

- [ ] **Step 3: Write minimal implementation**

Add to `LinkPresence`:

```swift
    /// The Mac is not hosting its access point, so there is no link at all.
    case accessPointDown
    /// The access point is up and no phone has been discovered on it.
    case noPeerDiscovered
```

Add to `LinkStatus`:

```swift
    /// The one state in this matrix the user can personally fix.
    case accessPointDown
    case waitingForPhone
```

In `resolve`, ahead of the `userDisconnected` check:

```swift
        // Ahead of everything, including an explicit switch-off. With no access
        // point there is no link to switch off, and "Switched off" would send
        // the user looking at the wrong thing entirely.
        if case .accessPointDown = presence { return .accessPointDown }
```

And in the `switch presence`:

```swift
        case .accessPointDown:
            return .accessPointDown
        case .noPeerDiscovered:
            return .waitingForPhone
```

Add headlines:

```swift
        case .accessPointDown: "UpLink network is not running"
        case .waitingForPhone: "Waiting for iPhone to join"
```

- [ ] **Step 4: Run the full suite**

Run: `cd UpLinkKit && swift test`
Expected: PASS. Existing `LinkStatus` tests are unaffected — no existing case changed meaning.

- [ ] **Step 5: Commit**

```bash
git add UpLinkKit/Sources/UpLinkKit/Transport/LinkStatus.swift UpLinkKit/Tests/UpLinkKitTests/LinkStatusAccessPointTests.swift
git commit -m "Give the access point its own name in the not-bridging matrix"
```

---

### Task 4: The Internet Sharing configuration, as a value

The helper must write `/Library/Preferences/SystemConfiguration/com.apple.nat.plist`. Building that dictionary is the part that can be wrong in ways only a reboot reveals, and it is pure data — so it belongs in the kit where `swift test` can hold it, not in a root daemon where every check costs a radio outage.

**Blocked on Phase 0.** The exact `SharingDevices` value for an access point that is genuinely up must come from a captured on-state snapshot; this Mac reads `SharingDevices => []` with sharing off. Task 4 encodes the shape and the fields that are known; Phase 0 supplies the one value and this task's test is updated with it.

**Files:**
- Create: `UpLinkKit/Sources/UpLinkKit/AccessPoint/AccessPointConfiguration.swift`
- Test: `UpLinkKit/Tests/UpLinkKitTests/AccessPointConfigurationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AccessPointConfiguration(ssid:passphrase:sourceServiceID:sharingDeviceKey:)`, `.natPreferences() -> [String: Any]`, `AccessPointConfiguration.preferencesPath: String`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import UpLinkKit

@Suite("The Internet Sharing configuration this Mac will be given")
struct AccessPointConfigurationTests {

    private var config: AccessPointConfiguration {
        AccessPointConfiguration(
            ssid: "UpLink",
            passphrase: "correct-horse-battery",
            sourceServiceID: "5F2E593C-4D8D-4175-AC49-2A8C56C10587",
            sharingDeviceKey: "en0"
        )
    }

    @Test("NAT is enabled, which is the whole point of writing the file")
    func natIsEnabled() {
        let nat = config.natPreferences()["NAT"] as? [String: Any]
        #expect(nat?["Enabled"] as? Int == 1)
    }

    @Test("The radio is enabled and carries the SSID we chose")
    func airportCarriesTheSSID() {
        let nat = config.natPreferences()["NAT"] as? [String: Any]
        let airport = nat?["AirPort"] as? [String: Any]
        #expect(airport?["Enabled"] as? Int == 1)
        #expect(airport?["NetworkName"] as? String == "UpLink")
    }

    @Test("The source is the dead-end route tunnel, never a real network")
    func sourceIsTheRouteTunnel() {
        let nat = config.natPreferences()["NAT"] as? [String: Any]
        #expect(nat?["PrimaryService"] as? String == "5F2E593C-4D8D-4175-AC49-2A8C56C10587")
    }

    @Test("The Wi-Fi device is listed as the sharing device")
    func sharingDeviceIsListed() {
        let nat = config.natPreferences()["NAT"] as? [String: Any]
        let devices = nat?["SharingDevices"] as? [String]
        #expect(devices == ["en0"])
    }

    @Test("The passphrase is carried as data, which is how the key is stored")
    func passphraseIsData() {
        let nat = config.natPreferences()["NAT"] as? [String: Any]
        let airport = nat?["AirPort"] as? [String: Any]
        #expect(airport?["NetworkPassword"] as? Data == Data("correct-horse-battery".utf8))
    }

    @Test("The path is the system location, not a per-user one")
    func pathIsSystemWide() {
        #expect(AccessPointConfiguration.preferencesPath
            == "/Library/Preferences/SystemConfiguration/com.apple.nat.plist")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd UpLinkKit && swift test --filter AccessPointConfigurationTests`
Expected: FAIL — cannot find 'AccessPointConfiguration' in scope

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The Internet Sharing configuration the helper writes.
///
/// **This is a value, not an action.** Internet Sharing has no public API, so
/// the helper drives it by writing this file and kickstarting
/// `com.apple.NetworkSharing`. Every field here is a place the design can be
/// wrong in a way that only a reboot or a radio outage would reveal, so the
/// shape lives in the kit where `swift test` can hold it and the daemon is left
/// with nothing but I/O.
///
/// **The plist is input, not output.** A prior run recorded
/// `:NAT:AirPort:Enabled` reading `0` with the access point fully up and
/// concluded "never test that field". That is correct and it is about reading:
/// configd consumes this file into live state and does not write back. Reading
/// it proves nothing about what is running; it says nothing about whether a
/// write is honoured.
public struct AccessPointConfiguration: Sendable, Equatable {

    public static let preferencesPath =
        "/Library/Preferences/SystemConfiguration/com.apple.nat.plist"

    public let ssid: String
    public let passphrase: String
    /// The SystemConfiguration service UUID of the source. In production this
    /// is the product's own `RouteProvider` tunnel, so the access point comes
    /// up with no internet behind it.
    public let sourceServiceID: String
    /// BSD name of the interface hosting the radio.
    public let sharingDeviceKey: String

    public init(ssid: String, passphrase: String, sourceServiceID: String, sharingDeviceKey: String) {
        self.ssid = ssid
        self.passphrase = passphrase
        self.sourceServiceID = sourceServiceID
        self.sharingDeviceKey = sharingDeviceKey
    }

    public func natPreferences() -> [String: Any] {
        [
            "NAT": [
                "Enabled": 1,
                "AirPort": [
                    "Enabled": 1,
                    "NetworkName": ssid,
                    "NetworkPassword": Data(passphrase.utf8),
                    "40BitEncrypt": 1,
                    "Channel": 0,
                ] as [String: Any],
                "PrimaryService": sourceServiceID,
                "SharingDevices": [sharingDeviceKey],
                "NatPortMapDisabled": false,
            ] as [String: Any],
        ]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd UpLinkKit && swift test --filter AccessPointConfigurationTests`
Expected: PASS, 6 tests

- [ ] **Step 5: Commit**

```bash
git add UpLinkKit/Sources/UpLinkKit/AccessPoint/ UpLinkKit/Tests/UpLinkKitTests/AccessPointConfigurationTests.swift
git commit -m "Model the sharing configuration as a value the tests can hold"
```

---

### Task 5: Finding the phone on the link

Over the cable the Mac dialled a fixed loopback port and discovery was `usbmuxd`'s job. Over the access point the phone has a DHCP address the Mac does not know, so the phone advertises and the Mac browses.

Two failures from the deleted AWDL-era discovery are permanent lessons and must not be reintroduced, both recorded in `docs/REGRESSIONS.md:420-425`: a browser with no `stateUpdateHandler` is undetectably wedged, and a cached endpoint from before a path change is returned instantly and costs the full connect timeout on every retry. The staleness window is injectable so both are testable without a radio.

**Files:**
- Create: `UpLinkKit/Sources/UpLinkKit/Transport/PeerDiscovery.swift`
- Test: `UpLinkKit/Tests/UpLinkRegressionTests/PeerDiscoveryRegressionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PeerDiscovery(stalenessWindow:)`, `PeerDiscovery.record(_ endpoint: NWEndpoint, at: Date)`, `PeerDiscovery.current(now: Date) -> NWEndpoint?`, `UpLinkIdentifiers.bonjourServiceType` (`"_uplink._tcp"`).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import Network
@testable import UpLinkKit

// SYMPTOM (2026-08-14, and the reason this is a regression suite rather than a
// unit suite): a result cached from before the radio was reconfigured was
// returned unconditionally and treated as current. Every retry then spent the
// full 12s connect timeout dialling an endpoint that no longer existed — at
// exactly the moment the device was trying to recover.

@Suite("Regression: a stale peer is not a peer")
struct PeerDiscoveryRegressionTests {

    private let endpoint = NWEndpoint.hostPort(host: "192.168.2.2", port: 51820)
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("A fresh observation is returned")
    func freshIsReturned() {
        let discovery = PeerDiscovery(stalenessWindow: 10)
        discovery.record(endpoint, at: start)
        #expect(discovery.current(now: start.addingTimeInterval(1)) != nil)
    }

    @Test("An observation older than the window is not returned")
    func staleIsWithheld() {
        let discovery = PeerDiscovery(stalenessWindow: 10)
        discovery.record(endpoint, at: start)
        #expect(discovery.current(now: start.addingTimeInterval(11)) == nil)
    }

    @Test("Re-observing the same endpoint refreshes it rather than ageing out")
    func reobservationRefreshes() {
        let discovery = PeerDiscovery(stalenessWindow: 10)
        discovery.record(endpoint, at: start)
        discovery.record(endpoint, at: start.addingTimeInterval(9))
        #expect(discovery.current(now: start.addingTimeInterval(11)) != nil)
    }

    @Test("With nothing ever observed there is no peer, not a crash")
    func nothingObserved() {
        #expect(PeerDiscovery(stalenessWindow: 10).current(now: start) == nil)
    }

    @Test("The service type is the one both sides agree on")
    func serviceType() {
        #expect(UpLinkIdentifiers.bonjourServiceType == "_uplink._tcp")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd UpLinkKit && swift test --filter PeerDiscoveryRegressionTests`
Expected: FAIL — cannot find 'PeerDiscovery' in scope

- [ ] **Step 3: Write minimal implementation**

Add to `UpLinkIdentifiers`:

```swift
    /// The Bonjour service the phone advertises on the link and the Mac
    /// browses for. One constant, because a mismatch here is silent on both
    /// sides — the Mac simply never finds a phone that is advertising happily.
    public static let bonjourServiceType = "_uplink._tcp"
```

```swift
import Foundation
import Network

/// The most recently observed endpoint for the phone, with an expiry.
///
/// **Deliberately holds only the decision, not the browser.** The wiring to
/// `NWBrowser` lives in the app; what is testable — and what was wrong on
/// hardware — is whether an old observation counts as current. See
/// docs/REGRESSIONS.md: a cached endpoint from before a path change was
/// returned instantly and cost the full connect timeout on every retry.
public final class PeerDiscovery: @unchecked Sendable {

    private let stalenessWindow: TimeInterval
    private let lock = NSLock()
    private var latest: (endpoint: NWEndpoint, seen: Date)?

    /// - Parameter stalenessWindow: how long an observation stays current.
    ///   Injectable so the expiry is provable in milliseconds rather than by
    ///   reconfiguring a radio.
    public init(stalenessWindow: TimeInterval = 15) {
        self.stalenessWindow = stalenessWindow
    }

    public func record(_ endpoint: NWEndpoint, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        latest = (endpoint, date)
    }

    public func current(now: Date = Date()) -> NWEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest else { return nil }
        guard now.timeIntervalSince(latest.seen) < stalenessWindow else { return nil }
        return latest.endpoint
    }

    public func forget() {
        lock.lock()
        defer { lock.unlock() }
        latest = nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd UpLinkKit && swift test --filter PeerDiscoveryRegressionTests`
Expected: PASS, 5 tests

- [ ] **Step 5: Commit**

```bash
git add UpLinkKit/Sources/UpLinkKit/Transport/PeerDiscovery.swift UpLinkKit/Sources/UpLinkKit/Support/Identifiers.swift UpLinkKit/Tests/UpLinkRegressionTests/PeerDiscoveryRegressionTests.swift
git commit -m "Refuse to hand back a peer observed before the path changed"
```

---

### Task 6: The Mac dials a discovered endpoint

The one line the whole bearer swap turns on. `MacSessionClient.dial(port:parameters:)` currently hard-codes `NWEndpoint.hostPort(host: .ipv4(.loopback), port:)`.

**Files:**
- Modify: `UpLinkKit/Sources/UpLinkKit/Transport/MacSessionClient.swift:281`
- Test: `UpLinkKit/Tests/UpLinkKitTests/MacSessionClientEndpointTests.swift`

**Interfaces:**
- Consumes: `PeerDiscovery` from Task 5.
- Produces: `MacSessionClient.dial(endpoint:parameters:)`. Public entry points gain an `endpoint: NWEndpoint` parameter in place of `relayPort: UInt16`: `runSession(endpoint:with:)`, `pair(endpoint:code:udid:)`, `deliverUnpairNotice(endpoint:to:)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Network
@testable import UpLinkKit

@Suite("The Mac dials where the phone actually is")
struct MacSessionClientEndpointTests {

    @Test("A loopback port still builds the loopback endpoint, so USB is unaffected")
    func loopbackEndpointForCable() {
        let endpoint = MacSessionClient.loopbackEndpoint(port: 51820)
        #expect(endpoint == .hostPort(host: .ipv4(.loopback), port: 51820))
    }

    @Test("A discovered endpoint is used verbatim rather than rewritten to loopback")
    func discoveredEndpointIsUsedVerbatim() {
        let discovered = NWEndpoint.hostPort(host: "192.168.2.2", port: 51820)
        let discovery = PeerDiscovery(stalenessWindow: 10)
        discovery.record(discovered)
        #expect(discovery.current() == discovered)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd UpLinkKit && swift test --filter MacSessionClientEndpointTests`
Expected: FAIL — type 'MacSessionClient' has no member 'loopbackEndpoint'

- [ ] **Step 3: Write minimal implementation**

Replace the private `dial(port:parameters:)` with an endpoint-taking form, and add the loopback constructor so the cable path keeps a name:

```swift
    /// The cable's endpoint. Kept as a named constructor rather than a literal
    /// so the USB path stays legible while both bearers exist.
    public static func loopbackEndpoint(port: UInt16) -> NWEndpoint {
        .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
    }

    private func dial(endpoint: NWEndpoint, parameters: NWParameters) async throws -> FrameChannel {
        let channel = NWConnectionChannel(connection: NWConnection(to: endpoint, using: parameters))
        try await channel.start(on: queue)
        return channel
    }
```

Change `runSession`, `pair` and `deliverUnpairNotice` to take `endpoint: NWEndpoint` and pass it down. At each call site in `Sources/UpLinkMac/`, pass `MacSessionClient.loopbackEndpoint(port: relayPort)` for the cable and `discovery.current()` for the access point.

- [ ] **Step 4: Run the full suite**

Run: `cd UpLinkKit && swift test`
Expected: PASS. Fix any call sites the compiler reports in `Sources/UpLinkMac/`.

- [ ] **Step 5: Commit**

```bash
git add -A UpLinkKit Sources/UpLinkMac
git commit -m "Dial the endpoint the phone is on, instead of assuming loopback"
```

---

### Task 7: The phone advertises on the link

`TransportParameters.listener` pins the bind to loopback because `usbmuxd`'s device side dials `127.0.0.1`. The existing comment names this as the one line to change if the muxer is ever seen dialling a non-loopback address — that is now the case, and `acceptLocalOnly` must go with it, since the connection is no longer local.

Keep the measured warning attached: `acceptLocalOnly` was once removed as redundant and the end-to-end test immediately stopped establishing a session. It is being removed here because the bearer genuinely changed, not because it looked redundant again.

**Files:**
- Modify: `UpLinkKit/Sources/UpLinkKit/Transport/NetworkTransport.swift`
- Test: `UpLinkKit/Tests/UpLinkKitTests/ListenerBindingTests.swift`

**Interfaces:**
- Consumes: `WirelessBearer` from Task 1.
- Produces: `TransportParameters.listener(sessionKeys:pairingKey:port:bearer:)`, `bearer` defaulting to `.hostedAP`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Network
import CryptoKit
@testable import UpLinkKit

@Suite("Where the phone's listener binds")
struct ListenerBindingTests {

    private var keys: [(identity: String, key: SymmetricKey)] {
        [("abc123", SymmetricKey(size: .bits256))]
    }

    @Test("Over the cable it still pins loopback, which usbmuxd requires")
    func cablePinsLoopback() {
        let parameters = TransportParameters.listener(
            sessionKeys: keys, pairingKey: nil, port: 51820, bearer: .usbmux
        )
        #expect(parameters.requiredLocalEndpoint != nil)
        #expect(parameters.acceptLocalOnly == true)
    }

    @Test("Over the access point it does not pin loopback, or the Mac cannot reach it")
    func accessPointDoesNotPinLoopback() {
        let parameters = TransportParameters.listener(
            sessionKeys: keys, pairingKey: nil, port: 51820, bearer: .hostedAP
        )
        #expect(parameters.requiredLocalEndpoint == nil)
        #expect(parameters.acceptLocalOnly == false)
    }

    @Test("Port reuse survives either way, because the extension restarts")
    func portReuseAlways() {
        for bearer in WirelessBearer.allCases {
            let parameters = TransportParameters.listener(
                sessionKeys: keys, pairingKey: nil, port: 51820, bearer: bearer
            )
            #expect(parameters.allowLocalEndpointReuse == true)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd UpLinkKit && swift test --filter ListenerBindingTests`
Expected: FAIL — extra argument 'bearer' in call

- [ ] **Step 3: Write minimal implementation**

```swift
    public static func listener(
        sessionKeys: [(identity: String, key: SymmetricKey)],
        pairingKey: (identity: String, key: SymmetricKey)?,
        port: UInt16,
        bearer: WirelessBearer = .hostedAP
    ) -> NWParameters {
```

Replace the loopback pinning block with:

```swift
        // Over the cable BOTH of these are required, and that is measured, not
        // assumed: `acceptLocalOnly` was once removed as redundant and the
        // end-to-end test immediately stopped establishing a session at all.
        //
        // Over the access point they are both wrong. The Mac dials the phone's
        // address on the shared link, so a listener pinned to loopback is
        // unreachable and one accepting local connections only refuses it. This
        // is the change the original comment anticipated — the muxer is no
        // longer what dials — rather than the same redundancy argument again.
        if bearer == .usbmux {
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!
            )
            parameters.acceptLocalOnly = true
        }
        parameters.allowLocalEndpointReuse = true
        return parameters
```

- [ ] **Step 4: Run the full suite**

Run: `cd UpLinkKit && swift test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add UpLinkKit
git commit -m "Let the phone's listener be reachable from the link that now carries it"
```

---

### Task 8: The tunnel extension advertises, the Mac browses

Wiring the two previous tasks to real Network.framework objects. Not unit-testable — there is no test target for the extensions — so the kit types carry the decisions and these files carry only I/O.

**Files:**
- Modify: `Sources/UpLinkTunnelExtension/PacketTunnelProvider.swift`
- Modify: `Sources/UpLinkMac/MenuBarModel.swift`
- Modify: `UpLinkKit/Sources/UpLinkKit/Transport/PhoneSessionHost.swift`

**Interfaces:**
- Consumes: `UpLinkIdentifiers.bonjourServiceType`, `PeerDiscovery`, `TransportParameters.listener(…bearer:)`.
- Produces: `PhoneSessionHost.start(bearer:)` advertising when `bearer != .usbmux`.

- [ ] **Step 1: Advertise from the phone**

In `PhoneSessionHost`, when building the `NWListener`, set the service so the Mac can find it:

```swift
        // The phone advertises and the Mac browses. Over the cable this was
        // usbmuxd's job; over the access point there is nothing that knows the
        // phone's DHCP address but the phone.
        if bearer != .usbmux {
            listener.service = NWListener.Service(
                name: deviceName, type: UpLinkIdentifiers.bonjourServiceType
            )
        }
```

- [ ] **Step 2: Browse from the Mac**

In `MenuBarModel`, hold a `PeerDiscovery` and an `NWBrowser`. The browser MUST have a `stateUpdateHandler` that rebuilds on a terminal state — a browser with none was undetectably wedged on hardware and `firstMatch` returned nil for the life of the tunnel (`docs/REGRESSIONS.md:422`).

```swift
    private func startBrowsing() {
        let browser = NWBrowser(
            for: .bonjour(type: UpLinkIdentifiers.bonjourServiceType, domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let endpoint = results.first?.endpoint else { return }
            self?.discovery.record(endpoint)
        }
        // Without this the browser can fail when its interface is reconfigured
        // and never be noticed. Measured on hardware 2026-08-14.
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.rebuildBrowser()
            default: break
            }
        }
        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }
```

- [ ] **Step 3: Build both targets**

Run: `xcodegen generate && xcodebuild -scheme UpLinkMac -configuration Debug build`
Run: `xcodebuild -scheme UpLinkiOS -configuration Debug build`
Expected: both succeed

- [ ] **Step 4: Run the kit suite**

Run: `cd UpLinkKit && swift test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A Sources UpLinkKit
git commit -m "Have the phone announce itself, and the Mac keep looking"
```

---

### Task 9: The helper that owns the access point

**Files:**
- Create: `Sources/UpLinkHelper/main.swift`
- Create: `Sources/UpLinkHelper/HelperListener.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `AccessPointConfiguration` from Task 4.
- Produces: a `com.uplink.app.helper` LaunchDaemon registered with `SMAppService.daemon(plistName:)`, exposing `raiseAccessPoint(_:)` and `lowerAccessPoint()` over XPC.

- [ ] **Step 1: Add the target to `project.yml`**

```yaml
  UpLinkHelper:
    type: tool
    platform: macOS
    sources:
      - path: Sources/UpLinkHelper
    dependencies:
      - package: UpLinkKit
        product: UpLinkKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.uplink.app.helper
        PRODUCT_NAME: com.uplink.app.helper
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "Developer ID Application"
```

Embed it in `UpLinkMac` under `Contents/MacOS`, and add the launchd plist to
`Contents/Library/LaunchDaemons/com.uplink.app.helper.plist` with `RunAtLoad`
set — that is what makes the access point survive a reboot without depending on
macOS restoring Internet Sharing itself.

- [ ] **Step 2: Write the helper's work**

```swift
// Writes the configuration and kickstarts the daemon. Nothing else: every
// decision that could be wrong lives in AccessPointConfiguration, where
// `swift test` can hold it without costing a radio outage.
func raise(_ config: AccessPointConfiguration) throws {
    let dictionary = config.natPreferences() as NSDictionary
    guard dictionary.write(
        toFile: AccessPointConfiguration.preferencesPath, atomically: true
    ) else { throw HelperError.writeFailed }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = ["kickstart", "-k", "system/com.apple.NetworkSharing"]
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw HelperError.kickstartFailed }
}
```

- [ ] **Step 3: Register it once from the app**

In `AppDelegate`, alongside the existing system-extension activation:

```swift
    // One more approval in a flow that already has one — the app is already
    // unsandboxed and already installs a system extension.
    let service = SMAppService.daemon(plistName: "com.uplink.app.helper.plist")
    if service.status != .enabled { try? service.register() }
```

- [ ] **Step 4: Own the sleep policy**

`pmset` is root-only, and Internet Sharing sets no-sleep **only on AC power** —
it says so in the panel — so a Mac hosting the access point on battery still
sleeps. The helper is the only process that can fix that, and it is the reason
this task exists even if the write-and-kickstart mechanism turns out not to
work.

```swift
// Internet Sharing covers the AC case itself. This covers the other one, which
// is the case where the Mac is in the back of a car.
func holdAwake(_ awake: Bool) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    task.arguments = ["-b", "disablesleep", awake ? "1" : "0"]
    try task.run()
    task.waitUntilExit()
}
```

Call it from `raise` and its inverse from `lower`, so the setting never outlives
the access point it was taken for.

- [ ] **Step 5: Build and verify registration**

Run: `xcodegen generate && ./scripts/release-mac.sh`
Run: `launchctl print system/com.uplink.app.helper | head -5`
Expected: the job exists.

**Do not raise the access point from an unattended session.** It seizes the
Mac's only radio and cuts the connection driving the test.

- [ ] **Step 6: Commit**

```bash
git add -A Sources/UpLinkHelper project.yml Sources/UpLinkMac
git commit -m "Give the access point an owner that outlives a reboot"
```

---

### Task 10: The phone joins with one button

**Files:**
- Modify: `Sources/UpLinkiOS/BridgeController.swift`
- Modify: `Sources/UpLinkiOS/PairingViews.swift`
- Modify: `Sources/UpLinkiOS/UpLinkiOS.entitlements`

**Interfaces:**
- Consumes: the SSID and passphrase agreed at pairing.
- Produces: `BridgeController.join() async throws`, called before the tunnel starts.

- [ ] **Step 1: Add the entitlement**

```xml
<key>com.apple.developer.networking.HotspotConfiguration</key>
<true/>
```

- [ ] **Step 2: Join before starting the tunnel**

```swift
    // Verified present on iOS 11+ in the 26.5 SDK. This is what makes the whole
    // flow one button: no Settings trip, no password typed, no SSID picked out
    // of a list. `joinOnce = false` so the phone re-joins on its own next time.
    func join(ssid: String, passphrase: String) async throws {
        let configuration = NEHotspotConfiguration(SSID: ssid, passphrase: passphrase, isWEP: false)
        configuration.joinOnce = false
        try await NEHotspotConfigurationManager.shared.apply(configuration)
    }
```

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild -scheme UpLinkiOS -configuration Debug build`
Expected: succeeds. If the entitlement is rejected, the App ID needs the Hotspot capability — add it in the developer portal and rebuild.

- [ ] **Step 4: Install and confirm the button appears**

Run: `xcodebuild -scheme UpLinkiOS` then `xcrun devicectl device install app`
Confirm which build is on the phone before drawing conclusions: `xcrun devicectl device info processes` prints the bundle UUID, and installing does not restart an already-running NE extension.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/UpLinkiOS
git commit -m "Join the Mac's network from the app, so the trip to Settings is gone"
```

---

### Task 11: Say which state it is in, and rewrite the check

**Files:**
- Modify: `Sources/UpLinkMac/DevicesView.swift`, `Sources/UpLinkMac/MenuBarModel.swift`
- Modify: `scripts/verify-cellular.sh`

- [ ] **Step 1: Surface the new states**

Render `LinkStatus.accessPointDown` and `.waitingForPhone` with their headlines. `accessPointDown` is the only state in the matrix the user can personally fix, so it gets an action rather than a sentence.

- [ ] **Step 2: Re-invert the verification script**

`scripts/verify-cellular.sh:150-176` currently requires `usbmux` in the log and fails if `awdl` appears anywhere. Replace both conditions: the pass condition is a session accepted from the access-point subnet, and the failure conditions are a session over loopback (the cable came back) or over `%awdl0`. Keep the comment style — say what it used to check and why it changed, so the next inversion is a decision rather than a shrug.

- [ ] **Step 3: Run the script against a live bridge**

Run: `./scripts/verify-cellular.sh --full`
Expected: passes with the access point carrying the link. Requires the operator.

- [ ] **Step 4: Commit**

```bash
git add -A Sources/UpLinkMac scripts/verify-cellular.sh
git commit -m "Check for the bearer that is actually carrying the link"
```

---

### Task 12: Delete the cable

**Only after Phase 5's traffic matrix passes over the access point.** Until then the cable is the working reference a wireless failure is measured against.

**Files:**
- Delete: `Sources/UpLinkMac/USBRelay.swift`, `UpLinkKit/Sources/UpLinkKit/Transport/USBMux.swift`, `USBMuxProtocol.swift`, `RelayReconciler.swift`
- Modify: `WirelessBearer` — drop `.usbmux`; `TransportParameters.listener` — drop the loopback branch; `MacSessionClient` — drop `loopbackEndpoint`.
- Modify: `README.md` — the architecture diagram, the transport claims, and the standing note that quitting the menu-bar app drops the bridge, which stops being true.

- [ ] **Step 1: Delete and let the compiler find the callers**

Run: `cd UpLinkKit && swift build`

- [ ] **Step 2: Delete the tests that only covered the cable**

Regression tests for usbmux framing and the byte-swapped `PortNumber` guard code that no longer ships. Deleting them is correct; deleting a regression test for a defect that can still occur is not. Check each against `docs/REGRESSIONS.md` before removing.

- [ ] **Step 3: Run the full suite**

Run: `cd UpLinkKit && swift test`
Expected: PASS

- [ ] **Step 4: Update the README**

The menu-bar app no longer owns a relay, so "quitting the menu-bar app drops the bridge" needs re-deriving rather than deleting — state what is true after the change.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Take out the cable, now that the air carries it"
```

---

## Operator-gated work

These cannot run unattended. Hosting the access point seizes the Mac's only
radio, so an agent driving the test goes blind exactly when there is something
to see — the same trap as the device-testing constraints.

**Phase 0, before Task 4's test is finalised:**
1. Does writing `com.apple.nat.plist` and kickstarting `com.apple.NetworkSharing` raise the access point on macOS 26? Capture the on-state to a file, switch sharing off, then read the file.
2. What is `SharingDevices` with the access point genuinely up? Task 4's test hard-codes `en0` and must be corrected to whatever is measured.
3. Does it survive a reboot?
4. Does the phone hold a no-internet association for hours rather than minutes?

**Phase 5, after Task 11:**
The full traffic matrix over the access point — TCP, TCP by IP with no DNS,
UDP, IPv6, QUIC/HTTP-3 — each confirmed egressing on the carrier's address,
with a baseline taken **before** the bridge comes up. `scripts/coverage-test.sh`
runs it. HTTP/3 needs `/opt/homebrew/opt/curl/bin/curl --http3-only`; `--http3`
falls back to TCP silently and proves nothing. Turn off the commercial VPN
first, or the matrix cannot distinguish UpLink from it.
