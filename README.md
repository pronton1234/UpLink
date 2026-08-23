# UpLink

Routes a Mac's traffic through an iPhone's cellular connection over a wireless
link the Mac itself hosts. The Mac needs no network of its own; the phone is
never asked to share one.

Traffic leaves the phone from an ordinary app socket pinned to the cellular
radio, so the carrier sees app data with the phone's own TTL and APN.

> Bypassing hotspot metering violates most carrier terms of service. Not
> illegal, widely done — but it is your call.

---

## Status

| Area | State |
| --- | --- |
| Wireless bearer (Mac-hosted access point) | **Verified on hardware 2026-08-21** — 156.46 Mbps down, 36.55 Mbps up, 4.33 ms to destination |
| Bluetooth LE control channel | **Verified** — the phone raises the Mac's access point while that network is down |
| Traffic carried | **Verified** — 277 flows in one session across Chrome, Discord, Firefox, VS Code, Notion, Claude; IPv4 and IPv6 |
| Cellular egress | **Verified** — carrier address, not the local ISP |
| Range | **Verified in a car** on a 2.4 GHz channel, Mac in the boot, phone in the front seat |
| Pairing crypto, Keychain storage | Done, verified on hardware |
| Multiplexer, framing, flow control | Done — 418 tests, 78 suites |
| Reconnect, stranding guards | Done, verified |
| Sustained multi-hour operation | Not yet measured |

Throughput was measured with `scripts/throughput-test.sh` against
`speed.cloudflare.com`, with the Mac's own Wi-Fi given over to hosting.

---

## Architecture

```
Mac                                            iPhone
┌──────────────────────────────────┐          ┌────────────────────────────┐
│ UpLinkMac (menu bar)             │          │ UpLinkiOS (SwiftUI)        │
│  ├─ AccessPointBeacon  ◄─── BLE ─┼──────────┼─► AccessPointRemote        │
│  │    one command byte           │          │     "raise" / "lower"      │
│  ├─ AccessPointHost ──XPC──┐     │          │                            │
│  └─ MenuBarModel           │     │          │ UpLinkTunnelExtension      │
│       announces peer       │     │          │  NEPacketTunnelProvider    │
├────────────────────────────┼─────┤          │  PhoneSessionHost          │
│ UpLinkHelper (root daemon) │     │          │   listens :50505           │
│  SCPreferences → configd ──┘     │          │                            │
│  raises Internet Sharing         │          │  CellularDialer            │
├──────────────────────────────────┤          │   requiredInterfaceType    │
│ UpLinkProxyExtension (sysex)     │          │     = .cellular            │
│  ├─ TransparentProxyProvider     │          └──────────┬─────────────────┘
│  │    captures all TCP + UDP     │                     │
│  ├─ RouteProvider (utun5)        │                     ▼
│  │    default route + DNS        │              cellular = app data
│  └─ MacSessionClient ════════════╪══ 5GHz/2.4GHz AP ══► (TLS-PSK, muxed)
└──────────────────────────────────┘
```

### Components

| Target | Kind | Responsibility |
| --- | --- | --- |
| `UpLinkKit` | SwiftPM library | Everything with correctness risk: framing, multiplexer, pairing, capture policy, lease parsing, bearer rules. Pure Swift, testable without hardware. |
| `UpLinkMac` | menu bar app | Owns the beacon, the helper client, peer announcement, and the UI. Unsandboxed. |
| `UpLinkHelper` | root LaunchDaemon | The only component that can drive Internet Sharing. Reached over XPC. |
| `UpLinkProxyExtension` | system extension | Two providers: the transparent proxy that captures flows, and the route tunnel that gives the Mac a default route and resolvers. |
| `UpLinkiOS` | iOS app | Joins the Mac's network, rings the BLE doorbell, drives the tunnel. |
| `UpLinkTunnelExtension` | iOS network extension | Hosts the listener and the cellular dialer. Survives backgrounding and lock. |

---

## How it works

### 1. The Mac hosts a network with nothing behind it

`AccessPointHost` asks the root helper to raise an access point. The helper
writes the sharing configuration **through SystemConfiguration** —
`SCPreferencesCreate` → `Lock` → `SetValue` → `CommitChanges` →
`ApplyChanges` — and configd's `com.apple.SystemConfiguration.ISPreference`
plugin starts `InternetSharing`.

Three details are load-bearing:

- **Writing `com.apple.nat.plist` directly does nothing.** configd is never
  notified. `SCPreferencesApplyChanges` is the notification System Settings
  itself sends.
- **Restarting `com.apple.NetworkSharing` is impossible.** SIP owns Apple's
  daemons; `launchctl kickstart` returns *"Operation not permitted while System
  Integrity Protection is engaged"* even as root.
- **The configuration is merged, never rebuilt.** `PrimaryInterface` names the
  service being shared, and a from-scratch dictionary drops it — configd then
  reports `external interface: (null)` and shares on zero interfaces.

The source shared from is `UpLink Route`, the product's own always-up packet
tunnel. It routes nowhere, which is what makes the access point carry no
internet: the phone's cellular is the only way out.

Because that tunnel is the sharing source, **its mode is pinned while
hosting**. Any reconfiguration of `utun5` makes macOS rebuild the access point
underneath it and drop every client. The pin follows *intent* — set before the
raise call, not after the interface appears — because during startup the
interface does not exist yet.

### 2. The phone asks for it over Bluetooth

Starting the access point cannot travel over the access point: the phone's only
path to the Mac is the network being asked for.

`AccessPointBeacon` (macOS, `CBPeripheralManager`) advertises a service whose
one writable characteristic accepts a **single byte**. `RemoteCommand.decode`
rejects anything that is not exactly one known byte — there is no length field,
no payload, and no framing, so the channel cannot become a data path.
Advertising stops entirely while a session is live.

BLE is 2.4 GHz and short-range; the bridge is a separate Wi-Fi association. They
do not contend for the same airtime, and no traffic ever crosses BLE.

**The doorbell is an accelerator, not a dependency.** The Mac hosts on its own
whenever it has no network of its own to lose — which is the case in a car — so
a doorbell that cannot reach the boot costs nothing.

### 3. The phone joins by prefix

`NEHotspotConfiguration(ssidPrefix:passphrase:isWEP:)` joins any network whose
name begins with `UpLink`.

Prefix matching is forced, not preferred: the hosted network's name **cannot be
set or read**. `NAT:AirPort:NetworkName` is written and ignored, and the live
configuration lives in `com.apple.airport.preferences.plist`, which SIP makes
unreadable even to root. Neither device can learn the name, so neither needs to.

The passphrase is asked for once, on the phone, for the same reason: nothing can
read it to send it.

Joining is retried while the access point comes up — roughly ten seconds from
the helper being asked to `bridge100` appearing. A single attempt lands in that
gap and fails with an error that reads like a wrong password.

### 4. The Mac finds the phone in its own DHCP leases

The Mac is the DHCP server for the network it hosts, so it already knows every
address it handed out. `/var/db/dhcpd_leases` is world-readable and updated as
clients join.

No Bonjour, no service resolution, no local-network permission prompt.

iOS randomises its MAC per join, so each join leaves another lease behind.
`DHCPLease.mostRecent` selects by **expiry**, not file order — a file commonly
holds entries days old sitting after the live one.

The address is announced to the proxy extension over IPC as
`peer:<address>:50505:<udid>`. Announcement is gated on the access point being
up, decided by `TransportParameters.hostedNetworkAddressExists` — one predicate,
shared with the dial binding, the route-mode pin and the hosting failsafe.

### 5. The session

`MacSessionClient` dials the phone at `:50505` with TLS-PSK. The dial **binds
its source** to the Mac's own address on the hosted network; otherwise the
address falls through to the default route and the SYN goes to whatever gateway
the Mac last had, failing with `ETIMEDOUT`.

`PhoneSessionHost` accepts, completes the handshake, and reads the first frame.
One listener serves both purposes: each paired Mac contributes a PSK keyed by
its fingerprint, and an armed pairing code contributes one more.

Above the byte pipe sits a multiplexer. Frames:

| Kind | Purpose |
| --- | --- |
| `hello` / `helloAck` | Opening handshake, protocol version |
| `open` / `close` | Stream lifecycle |
| `data` | Stream payload, up to 1 MiB per frame |
| `window` | Per-stream flow control |
| `datagram` | UDP, with its own envelope |
| `ping` / `pong` | Liveness |
| `egressReport` | Which interface a stream actually left on |
| `pairRequest` / `pairResponse` | Pairing, over the same listener |

### 6. Capture and egress

`TransparentProxyProvider` includes two network rules — all outbound TCP, all
outbound UDP. Which flows actually cross the bridge is decided per flow by
`CapturePolicy`, which excludes:

- loopback and link-local
- private networks the user is on
- **every network this Mac is attached to**, read from the interfaces at session
  start rather than inferred by prefix — a home LAN holds a globally routable
  IPv6 `/64`, so a neighbour looks exactly like a server abroad
- the peer endpoint itself, and any app on the never-bridge list

On the phone, `CellularDialer` opens each destination with
`requiredInterfaceType = .cellular` and `prohibitedInterfaceTypes` covering the
interfaces the peer link rides. The interface a stream *actually* used is read
back from `NWConnection.currentPath` and reported to the Mac, which displays it
verbatim rather than assuming the request was honoured.

### 7. The Mac's own routing

`RouteProvider` is a packet tunnel that carries nothing. In capture mode it
installs a default route and public resolvers so that flows exist at all — with
no default route, `connect()` fails before any policy match and the transparent
proxy is never consulted.

DNS settings cannot be attached to a transparent proxy, so the proxy rewrites
each query's **destination** instead: the query goes to `1.1.1.1` across the
bridge, and the reply is handed back addressed as though it came from the
resolver the client asked.

### 8. Stopping

Stop has three steps, because starting had three:

1. the tunnel stops
2. the phone **leaves the network** — every configured SSID carrying the prefix
   is removed, asked of iOS rather than assumed
3. the Mac is told to stop hosting, over BLE, held open with a background task

The Mac does not depend on step 3 arriving. A session ending re-arms a guard
that lowers the access point when nothing reconnects. With no network to go back
to — a car — it keeps hosting instead, because lowering there would leave the
phone no way in.

---

## Technical notes

**Hosting is on probation.** Raising the access point takes the Wi-Fi radio, so
until a session forms the Mac has no internet at all. If none appears within 50
seconds and there is a network to return to, hosting stops.

**Raising is not idempotent.** Each raise re-applies the sharing configuration
and macOS rebuilds the access point, dropping every client. Raises are debounced
with a cooldown longer than a raise takes to complete, and never happen during a
live session.

**One radio, two claimants.** macOS auto-joins known networks, and hosting needs
that radio exclusively. Beside a remembered network the two alternate. Turning
off Auto-Join for nearby networks removes the contention; in a car nothing
competes.

**Band is chosen in System Settings.** The channel is not settable in code — the
live configuration is in the SIP-protected store. 5 GHz is faster; **2.4 GHz is
what reaches from a car boot to the front seat.**

**A stale system extension or helper is invisible.** Replacing the app does not
restart a running LaunchDaemon or Network Extension, and nothing short of root
can restart one. The helper reports its build over XPC; the phone's log records
which build is listening.

---

## Setup

Once, on the Mac:

```bash
./scripts/release-mac.sh
```

Builds, signs with Developer ID, notarizes, staples, installs to
`/Applications`, and launches. A system extension is only activated by macOS
when the build is Developer ID signed and notarized.

Then, first run only:

1. **System Settings → General → Login Items & Extensions** — approve the
   network extension and the helper
2. **System Settings → General → Sharing → Internet Sharing → Wi-Fi Options…**
   - Network Name: anything beginning with `UpLink`
   - Security: WPA2/WPA3 Personal, and set a password
   - Channel: **2.4 GHz (1, 6 or 11) for range**, 5 GHz for speed
   - Leave the Internet Sharing toggle **off** — the app raises it
3. Menu bar → **Set Network Password…** — the same password
4. Menu bar → **Show Pairing Code…**, and type the six digits on the phone

On the phone:

```bash
xcodebuild -scheme UpLinkiOS -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/ios build
xcrun devicectl device install app --device <udid> \
  build/ios/Build/Products/Debug-iphoneos/UpLink.app
```

After that: **open the app.** With a paired Mac and a stored password it
connects on its own.

---

## Verifying

```bash
./scripts/verify-wireless.sh
```

Run it while connected. It answers three questions in order and refuses to
answer a later one before an earlier one has passed:

1. **The bearer** — access point up, phone holding a live lease, routed over
   `bridge100`, link quality
2. **Is traffic really crossing it** — egress address *and* claimed flows in the
   proxy log, because an address alone has been observed lying in both
   directions
3. **Traffic classes and speed** — system DNS, DNS direct to `1.1.1.1`, TCP by
   name, TCP by IP, IPv6, QUIC, then throughput

```bash
./scripts/test.sh              # 418 tests, ~10s, no hardware
./scripts/wireless-watch.sh &  # records a session to /tmp for reading afterwards
```

The Mac under test is the Mac driving the test, and hosting takes its radio, so
anything watching live goes blind exactly when there is something to see.
`wireless-watch.sh` writes to disk instead.

---

## Layout

- `UpLinkKit/` — standalone SwiftPM package holding everything with correctness
  risk. `swift test` exercises it in about ten seconds with no simulator,
  device, or `xcodebuild`.
- `Sources/UpLinkMac`, `Sources/UpLinkHelper`, `Sources/UpLinkProxyExtension` —
  the Mac side.
- `Sources/UpLinkiOS`, `Sources/UpLinkTunnelExtension` — the phone side.
- `docs/REGRESSIONS.md` — every bug fixed gets a permanent test and an entry.
  Read this before fixing anything.
- `docs/device-test-log.md` — the checks only hardware can answer, with numbers.

## Design notes

**Why a system extension.** `NETransparentProxyProvider` is the only API that
captures TCP *and* UDP for every process. A SOCKS proxy captures only
proxy-aware applications and no UDP at all, which puts QUIC and DNS outside the
bridge.

**Why a Network Extension on the phone.** iOS suspends ordinary apps within
seconds of backgrounding. A Network Extension is a separate process the system
keeps running, so the bridge survives the screen locking. The tunnel routes
nothing — it exists as a process host.

**Why the helper is a separate root daemon.** Driving Internet Sharing requires
writing system preferences and notifying configd. The app is unsandboxed but not
root, and the proxy extension is sandboxed.

**Why pairing exists.** The access point is reachable by anyone in range. A
TLS-PSK handshake costs one round trip on a sub-millisecond link and makes an
unpaired peer unable to open a single stream.

**What "universal" does not include.** ICMP, raw IP sockets, and traffic from
other system extensions are outside the transparent proxy API and continue to
use the Mac's own interface. `scripts/block-icmp.sh` closes the ICMP path rather
than letting it leak silently.
