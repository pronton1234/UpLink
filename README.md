# UpLink

Routes a Mac's traffic through an iPhone's cellular connection, so the carrier
sees ordinary app data rather than tethering.

Carriers commonly leave the phone's own data unthrottled while capping Personal
Hotspot. UpLink re-originates the Mac's traffic from an app socket on the phone,
so the TTL and DPI signatures that identify tethering never appear.

> Bypassing hotspot metering violates most carrier terms of service. Not
> illegal, widely done — but it is your call.

## How it works

```
Mac                                          iPhone
┌──────────────────────────────┐            ┌────────────────────────────┐
│ UpLinkMac (menu bar)         │            │ UpLinkiOS (SwiftUI)        │
│  Devices window + pairing    │            │  user turns the bridge on  │
│  USBRelay ──► /var/run/      │            │                            │
│               usbmuxd  ══════╪═ CABLE ════╪══► UpLinkTunnelExtension   │
├──────────────────────────────┤            │      NEPacketTunnelProvider│
│ UpLinkProxyExtension (sysex) │            │      listens on 127.0.0.1  │
│  transparent proxy captures  │◄─TLS-PSK──►│      dials out per stream  │
│  every flow ──► mux          │  end-to-end└──────────┬─────────────────┘
└──────────────────────────────┘                       ▼ cellular = app data
```

**The cable is the only transport.** `usbmuxd` — the same channel Xcode uses —
needs no network interface at all: no Wi-Fi association, no Bonjour, no
multicast, no Personal Hotspot. That is the point. The Mac's Wi-Fi radio can be
associated with nothing and the bridge still works, which is the configuration
this product exists for and the one AWDL could never hold.

`usbmuxd` carries connections in one direction only, so **the Mac dials and the
phone listens**. The Mac's proxy extension is sandboxed and cannot open
`/var/run/usbmuxd`, so the unsandboxed menu-bar app pumps the cable onto a
loopback port — carrying ciphertext it has no key for, since TLS-PSK runs end to
end between the extension and the phone. One consequence, stated plainly in the
UI: **quitting the menu-bar app drops the bridge.**

The single most important line in the codebase is
`parameters.requiredInterfaceType = .cellular` in `CellularDialer` — that is
what forces egress through the cellular radio.

## Honest status

| Area | State |
| --- | --- |
| Wire protocol, multiplexer, flow control | **Done**, 277 tests across the kit |
| Pairing crypto + Keychain storage | **Done**, verified on hardware |
| USB transport (`usbmuxd`) | **VERIFIED ON HARDWARE 2026-08-15** — Wi-Fi radio off, 116–153 Mbps, every traffic class bridged including IPv6, nothing leaked |
| TLS-PSK / cellular dialer | **Done**, verified on hardware |
| End-to-end proxying | **Proven** in-process and, for TCP, on hardware |
| iOS app + tunnel extension | **Builds**, UI complete |
| macOS menu bar app + transparent proxy extension | **Builds**, universal TCP/UDP capture |
| TCP over the bridge | **Verified on hardware** — carrier IP, cellular egress, 98 Mbps |
| UDP / DNS over the bridge | **Fixed off-device, not yet proven on hardware** |
| QUIC over the bridge | **Verified on hardware 2026-08-15** — 150 MB sustained at 88 Mbps, radio off; matches the no-bridge control, so the bridge is not the bottleneck |
| Running with no network of the Mac's own | **Works, with a setup step** — see below |
| Coverage harness | **Done** — measures leaks rather than assuming |
| Reconnect (keyed on identity, backoff) | **Done**, tested |
| Phase 0 spikes | **Written, not run** — needs a physical iPhone |

### The Mac needs a route before it needs a bridge

The product's whole premise is a Mac with no network but the phone. In exactly
that state it did nothing at all, and the reason is structural:

**`NETransparentProxyProvider` only receives flows the system was already going
to route.** With no default route, `connect()` fails before any policy match, so
`handleNewFlow` is never called and the bridge sits connected and idle while
every request dies in the socket layer. With no network service there is also no
resolver, so names cannot be looked up either.

Both are fixed by giving the Wi-Fi service a standing address, a gateway that
goes nowhere, and a public resolver:

```bash
sudo ./scripts/standalone-mode.sh on
```

Nothing is ever sent to that gateway; it exists so the flow does. Verified
carrying real traffic to the carrier's address with the Mac unable to reach its
own router. **Turn it off when not bridging**, or the Mac has no internet.

This belongs in the app, applied and removed with the session. It cannot be
today — the extension is sandboxed and the app is not root — so it needs a
privileged helper or a move to `NEPacketTunnelProvider`.

### What is not verified

Pairing, the TLS-PSK session, cellular egress and real TCP transfer have all
been observed working end to end on hardware with no hotspot. Still unproven:

- **UDP on hardware.** Three defects were found and fixed off-device — a
  destination killed by its own first reply, a stream closed when the client
  stopped sending, and a UDP session OPEN whose placeholder destination was
  dialled and closed the stream. All three are pinned by tests against real
  sockets, and UDP has now been confirmed on a phone — DNS and QUIC both crossed
  the bridge in the 2026-08-15 run.
- ~~**QUIC.**~~ **Done, 2026-08-15.** UDP 443 is the bulk-UDP case and a
  different shape from DNS — long-lived, high-rate, many datagrams per
  destination — and it carries: 150 MB sustained at 88 Mbps with the radio off,
  matching the no-bridge control.

- ~~**The whole wired transport, on hardware.**~~ **Done, 2026-08-15** — see
  `docs/device-test-log.md`. Re-run any time with `./scripts/verify-wired.sh`.
- **The phone locked, under sustained load.** The extension port answering says
  it should hold, but it has not been left locked with traffic running. Every part of it is proven off
  device against a fake `usbmuxd` — framing, the byte-swapped `PortNumber`,
  attach/detach, the Wi-Fi-device filter, refusal, and the byte pipe — but the
  cable itself has not been run since the change.
- ~~**`usbmux Connect` reaching a listener inside a Network Extension**~~ —
  **ANSWERED on hardware, 2026-08-15: it does.** The preferred path works, so
  the bridge survives the phone being locked. The app-port fallback stays as
  insurance but is not what carries the link.
- **Multi-PSK TLS selection.** The phone's listener offers one pre-shared key
  per paired Mac plus one for an armed pairing code, and relies on TLS
  selecting by the identity the client presents. That is what the API is for,
  but it has not been observed working.
- **Route-less packet tunnel.** iOS may reject empty `includedRoutes`, or reap
  an extension it considers idle. Spike 2 covers it.
- **Cellular egress and background survival** — the two claims the product
  exists to make.

## Getting started

```bash
./scripts/test.sh
```

That runs the kit's 238 unit, regression, and loopback integration tests in
about ten seconds — nearly all of it one deliberate timeout test that proves a
stalled peer fails a write rather than blocking forever. `--all` additionally
regenerates the Xcode project and builds both app targets.

```bash
xcodegen generate && open UpLink.xcodeproj
```

To run the Mac app:

```bash
./scripts/release-mac.sh      # build, notarize, staple, install, launch
./scripts/coverage-test.sh    # prove what actually goes through the phone
```

The Mac app contains a system extension, which macOS activates only when the
build is Developer ID signed and notarized. One-time credential setup is in
[docs/device-test-log.md](docs/device-test-log.md); after that it is one
command per build.

Before running on hardware, work through the setup section of
[docs/device-test-log.md](docs/device-test-log.md). It is short: set the Team on
each of the four targets and Xcode registers the App IDs and entitlements for
you on first build.

## Layout

- `UpLinkKit/` — a standalone SwiftPM package holding everything that carries
  real correctness risk. Pure Swift, so `swift test` exercises it in under a
  second with no simulator, device, or `xcodebuild`.
- `Sources/UpLinkMac`, `Sources/UpLinkProxyExtension` — the passive Mac side.
- `Sources/UpLinkiOS`, `Sources/UpLinkTunnelExtension` — the phone side.
- `docs/REGRESSIONS.md` — every bug fixed gets a permanent test. Read this
  before fixing anything.
- `docs/device-test-log.md` — the checks only hardware can answer.

## Design notes

**Why a system extension, despite the cost.** An interim build used a SOCKS
proxy, which is an ordinary app and trivial to run. It only captured
proxy-aware apps, and could not carry UDP at all — so QUIC and DNS bypassed the
bridge entirely, and DNS bypassing it defeats much of the point. Universal
coverage requires `NETransparentProxyProvider`, and that requires notarizing
every build. The SOCKS code has now been deleted: it had no call sites, and the
README claimed for some time that it "survives as a test fixture", which was
not true of the shipping tree.

**Why the relay lives in the app.** The proxy extension is sandboxed
(`com.apple.security.app-sandbox`), and the sandbox does not permit opening
`/var/run/usbmuxd`. The menu-bar app is deliberately unsandboxed — it has to be,
to install a system extension at all — so it is the only process that can speak
to `usbmuxd`. It relays bytes and nothing else: the TLS-PSK session is end to
end between the phone and the extension, so the app holds no key and can read
nothing. The cost is that the bridge needs the app running, which the menu bar
says out loud rather than leaving to be discovered.

**What "universal" does not include.** The transparent proxy intercepts TCP and
UDP flows. ICMP, raw IP sockets, and traffic from other system extensions are
outside the API and continue to use the Mac's own interface. `scripts/block-icmp.sh`
closes the ICMP path by blocking it rather than letting it leak silently, and
the coverage harness reports the situation either way.

**Why a Network Extension on the phone.** iOS suspends ordinary apps within
seconds of backgrounding, which would drop the bridge the moment the screen
locks. A Network Extension is a separate process the system keeps running. The
tunnel deliberately routes nothing (`includedRoutes` is empty) — it exists as a
process host, not to capture the phone's own traffic.

**Why the UI insists on saying "Cellular".** A bridge that silently falls back
to the phone's Wi-Fi looks identical to one that works. The phone reports the
interface each stream *actually* egressed on, read from
`NWConnection.currentPath` rather than assumed from what was requested, and the
Mac displays that verbatim — degrading loudly to
`⚠ routing via Wi-Fi, not cellular` when it must.

**Why identifiers live in one Swift file.** `UpLinkIdentifiers` holds every
bundle ID, keychain group, and log subsystem. They were previously literals
scattered across four targets, two Info.plists, and four entitlement files —
which is exactly how the app and its extension ended up reading two different
keychains without anyone noticing.

**Why pairing exists at all.** The original spec called for no authentication
handshake, for latency. On a shared network that is an open proxy onto your
cellular plan. A TLS-PSK handshake costs one round trip on a sub-millisecond
link.
