# Wireless bearer for UpLink

**Status:** design, awaiting review
**Branch:** `wireless`
**Date:** 2026-08-20

Replace the USB cable with a wireless link of equivalent capability, so a Mac
carried in the back of a car reaches the internet through a phone in the front
with no cable, no laptop interaction, and no recurring cost.

## The requirement

A Mac with no network of its own must browse and work normally over the
phone's unthrottled cellular data. Setup is one time on the Mac and a couple of
button presses on the phone. Speeds comparable to the cable's measured
116-153 Mbps. Reliable, robust, free forever. The Mac never sleeps, so the
bridge must come up on demand. Personal Hotspot is excluded: it is the friction
this product exists to remove, and it is the metered path the product exists to
avoid.

Two facts about the deployment, confirmed 2026-08-20:

- **The Mac has no other network.** In the car its only uplink is the phone.
  There is no home Wi-Fi to preserve and no radio conflict to arbitrate.
- **The phone is in use but may lock or sleep at any moment.** The phone side
  must survive backgrounding and locking. This is a requirement, not a
  nice-to-have.

## The bearer: AWDL peer-to-peer

`includePeerToPeer` on `NWParameters`. Both radios on, associated with nothing.
Apple Wireless Direct Link brings up a direct radio link between the two
devices — the same transport AirDrop rides on.

This touches none of the mechanisms the deployment cannot script or tolerate:
no access point, no Personal Hotspot, no Internet Sharing, no SSID to join, no
System Settings trip, no hardware.

### Why not the alternatives

**Wi-Fi Aware.** Verified against the macOS 26.5 SDK on 2026-08-20: the
framework ships, and every symbol in
`WiFiAware.framework/.../arm64e-apple-macos.swiftinterface` carries
`@available(macOS, unavailable)`. iOS-only. Compiler-proven dead.

**Mac-hosted access point via Internet Sharing.** Proven on this hardware
2026-08-15 to come up with no internet behind it, shared from the product's own
always-up `RouteProvider` tunnel. Rejected as the primary bearer because
**Internet Sharing has no public API and cannot be toggled programmatically.**
A prior hardware run also found the live AP configuration is not in
`com.apple.nat.plist` — `:NAT:AirPort:Enabled` reads `0` with the AP fully up,
and the gateway lives on `bridge100` with the radio on a dedicated `ap1`
interface. Scripted attempts to read or drive that state produced confident
wrong answers three times. It survives here only as a fallback profile, enabled
once by hand.

**Personal Hotspot.** Excluded by the requirement and by the product premise:
it is the metered, DPI-visible path UpLink exists to avoid.

**Hardware dongle.** A USB-C stick presenting CDC-NCM Ethernet to the Mac with
its own access point for the phone would sidestep both problems. Nothing
off-the-shelf meets the speed bar in that form factor — the thumb-drive OpenWrt
sticks are 802.11n at roughly 50 Mbps real — so it means a custom build with
cost and lead time. Held in reserve; not needed unless AWDL and the hosted AP
both fail.

### What is already proven

`docs/device-test-log.md:498`, measured on hardware 2026-08-14:

> Does AWDL (`includePeerToPeer`) survive inside an `NEPacketTunnelProvider`?
> **yes** — carried a full session, `peer=…%awdl0`

That run bridged real traffic over a direct radio link with cellular egress.
AWDL was subsequently deleted, but the commit that did it (`1aa0ed9`) states the
reason: adopting `usbmuxd` inverted the dial direction, which "leaves AWDL with
nothing to do." **It was removed as redundant, not as failed.**

`nw_parameters_set_include_peer_to_peer` is present and undeprecated in both the
macOS 26.5 and iOS 26.5 SDKs, verified 2026-08-20.

### What is not proven

| Question | State |
| --- | --- |
| AWDL with the phone **locked** | never run |
| AWDL with the app **backgrounded** | never run |
| **Sustained** AWDL throughput | never measured |
| An iOS Network Extension **advertising** Bonjour over AWDL | never run |

The first three are why Phase 0 exists. The fourth is the mirror image of what
was proven — the Mac advertised and the phone dialled — and symmetry is expected
but will be measured rather than assumed.

## Architecture

The bearer is one endpoint. Everything above it is already bearer-agnostic.

`MacSessionClient.dial(port:parameters:)`
(`UpLinkKit/Sources/UpLinkKit/Transport/MacSessionClient.swift:281`) builds a
single `NWEndpoint.hostPort(host: .ipv4(.loopback), port:)` — the loopback port
`USBRelay` pumps the cable into. That endpoint is the entire coupling between
the product and its transport.

**The dial direction does not change.** The 4,400 deleted lines inverted the
roles because `usbmuxd` carries connections in one direction only. AWDL is plain
IP and imposes no such constraint, so the Mac keeps dialling and the phone keeps
listening. `PhoneSessionHost`, `MacSessionClient`, the handshake order and the
protocol version are all untouched. Only discovery and the parameters change.

### What changes

| Site | Today | After |
| --- | --- | --- |
| `MacSessionClient.dial` | loopback endpoint from `USBRelay` | endpoint from an `NWBrowser` over AWDL |
| `TransportParameters.listener` | `requiredLocalEndpoint` pinned to loopback | `includePeerToPeer`, advertises `_uplink._tcp` |
| `TransportParameters.session` | plain TCP to loopback | `includePeerToPeer`, pinned to IPv6 |

### What does not change

`CellularDialer`, including `requiredInterfaceType = .cellular` and
`prohibitedInterfaceTypes` — the lines the product rests on. The transparent
proxy and its universal TCP/UDP capture. The multiplexer, framing and flow
control. Pairing and its Keychain storage. `RouteProvider`, which already gives
the Mac a default route so flows are generated at all. The egress-verification
UI that degrades loudly when a stream does not leave over cellular.

Because `CellularDialer` is untouched, the carrier-facing behaviour is
byte-identical to the cable: an ordinary app socket on the phone's normal APN.
The anti-throttling premise carries over intact.

### Flow

1. The Mac's menu-bar app browses for `_uplink._tcp` over AWDL, continuously.
2. The user taps **Connect** in the iOS app.
3. The tunnel extension starts and advertises the service over AWDL.
4. The Mac's browser resolves it and dials. TLS-PSK handshake, keyed by the
   pairing established once at setup.
5. Bridged. The proxy extension hands every captured flow across.

One-time setup is the existing six-digit pairing. In the car it is one button
and no laptop.

## Keeping the link alive

This is the part that decides whether the design holds, and there is a measured
finding in the recovered code that points straight at it.

The kernel schedules AWDL airtime from the count of **active AWDL sockets**. A
session that fell back to IPv4 left the peer link with `SocketsActive 0`, and
two seconds before it died the log read:

```
monitorAWDLState: Active Sockets false ... SocketsActive 0
setScheduleState: reason:DiscoveryTimeout sc:Idle and force:YES
LQM-WiFi:AWDL State #16 Idle(3)
```

Two mitigations follow, and both ship from the start:

- **Pin the peer link to IPv6.** Already learned once; it is why commit
  `041821a` exists. An IPv4 path is not an AWDL path and does not keep the
  radio scheduled.
- **A deliberate keepalive stream**, so the active-socket count never reaches
  zero while the phone is locked and idle.

The keepalive is the primary hypothesis for locked survival. It is a hypothesis
until Phase 0 reports.

## Degradation and fallback

One ordered list, not three architectures:

```
preferenceOrder = [.peerToPeer, .localLink, .usbmux]
```

- `.peerToPeer` — AWDL. The target.
- `.localLink` — any shared IP link, including a Mac-hosted access point
  enabled once by hand. The insurance if AWDL cannot hold a locked phone.
- `.usbmux` — the cable. Retained until the wireless path passes the full
  live-traffic matrix, then deleted.

Demoting AWDL is a one-line change to this array. No redesign.

Failures stay legible rather than collapsing into "not bridging", following the
precedent `LinkStatus` already sets: no peer discovered, discovered but not
answering, answering but unpaired, and switched off by hand are four states with
four different remedies.

## Testing

The unit and regression suites in `UpLinkKit` continue to carry the correctness
risk and must stay green; the transport seam is narrow enough that the
multiplexer, framing and pairing suites are unaffected by the bearer swap.

They are not the evidence that matters here. Per the standing rule on this
project, a wireless bearer is proven only by live traffic across a real link:
TCP, TCP by IP with no DNS, UDP, IPv6, and QUIC/HTTP-3, each confirmed to
egress on the carrier's address rather than the home ISP's, with a baseline
taken **before** the bridge comes up. `scripts/coverage-test.sh` runs the
matrix. HTTP/3 needs `/opt/homebrew/opt/curl/bin/curl --http3-only`; `--http3`
falls back to TCP silently and proves nothing.

IPv6 is the row that matters most: IPv4 can be bridged while IPv6 goes straight
out, so half the traffic tells one story and half tells the other.

`scripts/verify-cellular.sh` currently **fails if `awdl` appears anywhere** —
inverted during the cable era. It has to be inverted back as part of this work,
or every wireless run reports a false failure.

## Phases

**Phase 0 — spike.** Answer, on hardware, before anything is built on top:
does AWDL hold with the phone locked; does it hold backgrounded; what is
sustained throughput against the cable's 116-153 Mbps; can a Network Extension
advertise Bonjour over AWDL. Output is an answer recorded in
`docs/device-test-log.md`, not code to keep.

**Phase 1 — bearer.** Restore `TransportProfile`, move the three sites in the
table above, add IPv6 pinning and the keepalive.

**Phase 2 — surfacing.** Discovery states in the menu bar and the iOS app.
Re-invert `verify-cellular.sh`.

**Phase 3 — proof.** The full live-traffic matrix over AWDL, with baselines.

**Phase 4 — removal.** Delete `usbmuxd`, `USBRelay`, the loopback relay and the
menu-bar dependency it forced. Only after Phase 3 passes.

Phase 0 and Phase 3 need the operator and the iPhone in the same room. Every
other phase runs unattended.

## Risks

- **Locked AWDL is unproven.** The keepalive is a hypothesis. Mitigated by the
  `.localLink` fallback costing one line.
- **The machine under test is the machine driving the test.** A bearer fault
  takes down the connection used to diagnose it. Capture to a file, then read
  it, as with the access-point work.
- **Sustained throughput is unmeasured.** AWDL is designed for bursts. The car
  case is its best case — the phone is on cellular with Wi-Fi unassociated, so
  AWDL gets the full radio duty cycle rather than time-sharing with an
  infrastructure link.
