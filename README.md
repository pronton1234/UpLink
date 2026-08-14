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
Mac (one ordinary app)                       iPhone
┌──────────────────────────────┐            ┌────────────────────────────┐
│ UpLinkMac                    │            │ UpLinkiOS (SwiftUI)        │
│  menu bar + Devices window   │            │   user taps Connect / Stop │
│  SOCKS5 on 127.0.0.1:1080    │◄──TLS 1.3──┤                            │
│  Bonjour listener            │  mux over  ├────────────────────────────┤
│  session host                │  Bonjour   │ UpLinkTunnelExtension      │
│                              │            │  NEPacketTunnelProvider    │
│  system proxy ──► itself     │            │  dials out per stream      │
└──────────────────────────────┘            └──────────┬─────────────────┘
                                                       ▼ cellular = app data
```

The **phone drives every session**; the Mac is entirely passive, which is what
lets it work without you opening the lid or clicking anything.

The single most important line in the codebase is
`parameters.requiredInterfaceType = .cellular` in `CellularDialer` — that is
what forces egress through the cellular radio.

## Honest status

| Area | State |
| --- | --- |
| Wire protocol, multiplexer, flow control | **Done**, 100 tests across the kit |
| Pairing crypto + Keychain storage | **Done**, tested |
| Transport / TLS-PSK / discovery / cellular dialer | **Done**, compiles clean under Swift 6 strict concurrency |
| End-to-end proxying | **Proven** by the loopback integration suite |
| iOS app + tunnel extension | **Builds**, UI complete |
| macOS menu bar app + transparent proxy extension | **Builds**, universal TCP/UDP capture |
| UDP / QUIC / DNS over the bridge | **Done**, 151 tests |
| Coverage harness | **Done** — measures leaks rather than assuming |
| Mac-side session establishment | **Done and verified live** — Bonjour advertising, SOCKS5 answering |
| Reconnect (keyed on identity, backoff) | **Done**, tested |
| Phase 0 spikes | **Written, not run** — needs a physical iPhone |
| Anything on real hardware | **Unverified** |

### What is not verified

Every line compiles and the protocol is proven end to end in-process, but no
byte has crossed a real radio. Specifically unproven:

- **AWDL inside a Network Extension** — the Phase 0 question. `spike/` holds the
  instrument and the procedure; if it fails, drop `.peerToPeer` from
  `TransportProfile.preferenceOrder` and everything else still works.
- **Multi-PSK TLS selection.** The Mac's listener offers one pre-shared key per
  paired phone plus one for an active pairing code, and relies on TLS 1.3
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

That runs the kit's 100 unit, regression, and loopback integration tests in well
under a second. `--all` additionally regenerates the Xcode project and builds
both app targets.

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
every build. The SOCKS server survives as a test fixture in the kit, which is
what keeps the off-device test loop under a second.

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
