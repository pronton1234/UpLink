# Wireless bearer for UpLink

**Status:** design, awaiting review
**Branch:** `wireless`
**Date:** 2026-08-20

Replace the USB cable with a wireless link of equivalent capability, so a Mac
carried in the back of a car reaches the internet through a phone in the front
with no cable, no laptop interaction, and no recurring cost.

## The requirement

A Mac with no network of its own must browse and work normally over the phone's
unthrottled cellular data. Setup is one time on the Mac and a couple of button
presses on the phone. Speeds comparable to the cable's measured 116-153 Mbps.
Reliable, robust, free forever. The Mac never sleeps, so the bridge must come up
on demand. Personal Hotspot is excluded: it is the friction this product exists
to remove and the metered path it exists to avoid.

Three facts about the deployment, confirmed with the operator 2026-08-20:

- **The Mac has no other network.** In the car its only uplink is the phone.
  There is no home Wi-Fi to preserve and no radio conflict to arbitrate.
- **The phone is in use but may lock or sleep at any moment.** The phone side
  must survive backgrounding and locking.
- **Internet Sharing cannot be toggled from an app.** There is no public API.
  Any design that flips it per session is dead on arrival.

## Decision

**The Mac hosts a 5 GHz WPA2 access point with nothing behind it. The phone
joins that access point and dials out over cellular.**

This is Personal Hotspot inverted. The phone associates to the Mac rather than
the reverse, so the laptop is never opened and the carrier never sees a tethered
client — the phone's own app socket originates every flow, exactly as it does
over the cable today.

Internet Sharing is enabled **once, by hand, at setup** and left on. That is
within the stated budget of "a one time set-up for the mac app," and it is the
only part of the system that touches System Settings. Because the Mac never
sleeps and has no other network to return to, there is nothing to toggle.

The access point is sourced from `RouteProvider` — the product's own always-up
dead-end tunnel — so it comes up with **no internet behind it**. The Mac's live
configuration already records this from the 2026-08-15 run:

```
"PrimaryInterface" => { "PrimaryUserReadable" => "UpLink Route" }
"PrimaryService"   => "5F2E593C-4D8D-4175-AC49-2A8C56C10587"
```

Proven on this hardware 2026-08-15: macOS hosted the access point, a phone
joined it, and the phone reported "no internet" — the required result.

### Why not AWDL, despite it looking ideal

AWDL needs no access point, no association and no Internet Sharing, and
`docs/device-test-log.md:498` records it carrying a full session inside an
`NEPacketTunnelProvider` on 2026-08-14. It was the obvious answer and it is
wrong, for one reason recorded in `docs/REGRESSIONS.md:406`:

```
awdl0: interfaceStateChange: Infra link down, disable dynamic SDB
disableWorkQueueSources: Disable all AWDL timers
```

**macOS schedules AWDL around the infrastructure Wi-Fi link.** With the Mac
associated to nothing, the kernel disables AWDL's timers. A live session died
within 400 ms of that line and the phone took roughly 100 seconds to get back
in. Every AWDL session that ever worked here worked with the Mac associated to a
real network.

The deployment target is a Mac associated to nothing. That is the one
configuration AWDL cannot hold, which is what `README.md:33` and
`scripts/verify-cellular.sh:152` both assert. A related finding compounds it:
`PeerLinkInterfaceRegressionTests` records the peer link being satisfied over
cellular and *suppressing* the AWDL path, reporting `.ready` while moving no
data — a hang rather than an error.

AWDL is therefore not the bearer. It is retained only as an opportunistic
profile for the case where the Mac does have an association.

### Why not the others

**Wi-Fi Aware.** Verified against the macOS 26.5 SDK on 2026-08-20: the
framework ships and every symbol carries `@available(macOS, unavailable)`.
iOS-only. Compiler-proven dead.

**Personal Hotspot.** Excluded by requirement and by premise.

**Hardware dongle.** A USB-C stick presenting CDC-NCM Ethernet to the Mac with
its own access point would remove the Internet Sharing dependency entirely.
Nothing off the shelf meets the speed bar in that form factor — the thumb-drive
OpenWrt sticks are 802.11n at roughly 50 Mbps real, well under the cable's 116
Mbps — so it means a custom build. Held in reserve; unnecessary if the hosted
access point survives reboot.

## Architecture

The bearer is one endpoint. Everything above it is already bearer-agnostic.

`MacSessionClient.dial(port:parameters:)`
(`UpLinkKit/Sources/UpLinkKit/Transport/MacSessionClient.swift:281`) builds a
single `NWEndpoint.hostPort(host: .ipv4(.loopback), port:)` — the loopback port
`USBRelay` pumps the cable into. That endpoint is the entire coupling between
the product and its transport.

**The dial direction does not change.** The roles were inverted for `usbmuxd`,
which carries connections one way only. Plain IP over an access point imposes no
such constraint, so the Mac keeps dialling and the phone keeps listening.
`PhoneSessionHost`, `MacSessionClient`, the handshake order and the protocol
version are untouched. Only discovery and the parameters change.

### What changes

| Site | Today | After |
| --- | --- | --- |
| `MacSessionClient.dial` | loopback endpoint from `USBRelay` | the phone's address on the AP subnet, from Bonjour |
| `TransportParameters.listener` | `requiredLocalEndpoint` pinned to loopback | binds the AP interface, advertises `_uplink._tcp` |
| `CellularDialer` | `prohibitedInterfaceTypes = [.wiredEthernet]` | adds `.wifi` — see below |

### The one substantive addition

`CellularDialer` currently prohibits `.wiredEthernet` so the phone cannot egress
back up the USB cable into the Mac. The wireless bearer creates the identical
hazard on a different interface: the phone is now associated to a Wi-Fi network
hosted by the Mac, so `.wifi` must be prohibited for destination dials too.

Without it, a Mac that ever has a route to share turns the bridge into a loop —
Mac to phone and straight back to the Mac — and, as the existing comment
records, `requiredInterfaceType` alone does not prevent this. It is documented
as a preference Network.framework may fall back from, which is exactly how a
Wi-Fi fallback was once observed being reported as a successful cellular dial.

### What does not change

`requiredInterfaceType = .cellular` — the line the product rests on. The
transparent proxy and its universal TCP/UDP capture. The multiplexer, framing
and flow control. Pairing and its Keychain storage. `RouteProvider`.
`CapturePolicy`, `LocalNetworks` and `OnLinkNetwork`, which already keep on-link
traffic off the bridge and will carry the AP subnet without modification. The
egress-verification UI that degrades loudly when a stream does not leave over
cellular.

Because `CellularDialer` keeps its cellular pin, carrier-facing behaviour is
byte-identical to the cable: an ordinary app socket on the phone's normal APN.

### Flow

1. The Mac hosts its access point continuously. No interaction, ever.
2. The user taps **Connect** in the iOS app.
3. The app joins the Mac's network with
   `NEHotspotConfiguration(SSID:passphrase:isWEP:)` — verified present on
   iOS 11+ in the 26.5 SDK. No Settings trip, no password typed, no SSID chosen
   from a list.
4. The tunnel extension starts and advertises `_uplink._tcp` on that link.
5. The Mac resolves it and dials. TLS-PSK handshake against the existing pairing.
6. Bridged.

One-time setup is Internet Sharing plus the existing six-digit pairing. In the
car it is one button and no laptop.

## Degradation and fallback

One ordered list, not three architectures:

```
preferenceOrder = [.hostedAP, .peerToPeer, .usbmux]
```

- `.hostedAP` — the Mac's access point. The target.
- `.peerToPeer` — AWDL. Opportunistic only, for when the Mac does have an
  association and the access point is therefore not hosted.
- `.usbmux` — the cable. Retained until the wireless path passes the full
  live-traffic matrix, then deleted.

Failures stay legible rather than collapsing into "not bridging", following the
precedent `LinkStatus` sets: access point down, phone not associated, associated
but not answering, answering but unpaired, and switched off by hand are distinct
states with distinct remedies. "Access point down" is the new one, and it is the
one the user can act on.

## Testing

The `UpLinkKit` suites continue to carry the correctness risk and must stay
green; the transport seam is narrow enough that the multiplexer, framing and
pairing suites are unaffected by the bearer swap.

They are not the evidence that matters. A wireless bearer is proven only by live
traffic across a real link: TCP, TCP by IP with no DNS, UDP, IPv6, and
QUIC/HTTP-3, each confirmed to egress on the carrier's address rather than the
home ISP's, with a baseline taken **before** the bridge comes up.
`scripts/coverage-test.sh` runs the matrix. HTTP/3 needs
`/opt/homebrew/opt/curl/bin/curl --http3-only`; `--http3` falls back to TCP
silently and proves nothing.

IPv6 is the row that matters most: IPv4 can be bridged while IPv6 goes straight
out, so half the traffic tells one story and half tells the other.

`scripts/verify-cellular.sh` currently requires `usbmux` in the log and fails if
`awdl` appears anywhere. Both conditions have to be rewritten for the access
point, or every wireless run reports a false failure.

**Measurement hazard.** Hosting the access point takes the Mac's only radio, so
an agent driving the test remotely goes blind exactly when there is something to
see. Capture to a file, switch sharing off, then read the file. This is the same
trap as the device-testing constraints: the machine under test is the machine
driving the test.

## Phases

**Phase 0 — the two measurements that gate everything.** Does Internet Sharing
survive a reboot with `Enabled` restored, and does an iOS device stay associated
to a no-internet network for hours rather than minutes? Both need the operator
present. Output is an answer in `docs/device-test-log.md`, not code.

**Phase 1 — bearer.** `TransportProfile`, the three sites above, and the `.wifi`
prohibition.

**Phase 2 — the phone's join.** `NEHotspotConfiguration`, the
`com.apple.developer.networking.HotspotConfiguration` entitlement, and the
Connect button.

**Phase 3 — surfacing.** Access-point and association states in both apps.
Rewrite `verify-cellular.sh`.

**Phase 4 — proof.** The full live-traffic matrix over the access point.

**Phase 5 — removal.** Delete `usbmuxd`, `USBRelay`, the loopback relay and the
menu-bar dependency it forced. Only after Phase 4 passes.

Phases 0 and 4 need the operator and the iPhone in the same room. Every other
phase runs unattended.

## Risks

- **Reboot persistence is unmeasured.** If Internet Sharing does not come back
  automatically, the Mac needs one visit to System Settings per reboot. That is
  the difference between this design meeting the requirement and merely
  approaching it, and it is Phase 0's first question.
- **iOS may not hold a no-internet association indefinitely.** It joined on
  2026-08-15; that it *stays* for hours is unproven.
- **The machine under test is the machine driving the test.**
- **Throughput is unmeasured over this bearer**, though 5 GHz at 80 MHz on a 2x2
  M2 Air should exceed cellular by a wide margin, making the radio a
  non-bottleneck rather than a close call.
