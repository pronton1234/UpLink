# On-device test log

The Simulator has no cellular radio and no real Network Extension host, so none
of the checks below can be run by CI or by an agent. Record every pass here with
a date, so "it worked" is evidence rather than memory.

## VERIFIED — wired transport, 2026-08-15

iPhone 15 Plus `00008120-000000000000001E`, cable only, **Wi-Fi radio off**.
Mac app build 1786831860.

### The result

```
1. Is there any way out other than the bridge?
     no real IPv4 gateway
     no usable IPv6 path over en0
     no router answering ARP on en0
2. Is the bridge actually up?
     a session is live
     the cable is carrying the link (relaying 127.0.0.1:54634 → network extension)
     no AWDL anywhere in the log
3. Make a real request, and prove the bridge carried it
     open.spotify.com -> http=200  total=0.326s
     the proxy opened 10 flow(s) during that request
4. public IPv4: 216.77.46.31          (carrier; home is 203.0.113.21)
5. Throughput: 116.7 Mbps

PASS — no other way out, and the proxy carried the request.
```

### Coverage matrix — nothing leaked

| # | Class | Result |
| --- | --- | --- |
| 1 | TCP, proxy-aware | bridged ✓ 216.77.46.31 |
| 2 | TCP, ignores proxy | bridged ✓ 216.77.46.31 |
| 3 | TCP, raw socket | bridged ✓ 216.77.46.31 |
| 4 | UDP (DNS) | bridged ✓ 216.77.49.33 |
| 5 | QUIC / HTTP-3 | n/a — curl has no HTTP/3 |
| 6 | **IPv6** | **bridged ✓ 2600:387:15:6712::7** |
| 7 | ICMP | blocked ✓ (cannot leak) |

Throughput through the bridge **153.5 Mbps** (18.3 MB/s); this Mac direct,
216.1 Mbps. The cable is not the bottleneck.

**IPv6 matters most in that table.** The standing warning here is that IPv4 can
be bridged while IPv6 goes straight out, so half the traffic tells one story and
half tells the other. The bridged v6 address (`2600:387:15:6712::7`) is the
carrier's, not this Mac's home v6 (`2001:db8:1:2:…`), measured before the
bridge came up.

**The baseline is what makes any of this evidence.** With the bridge down the
Mac reports `203.0.113.21`; with it up, `216.77.46.31`. Measured in that order,
which is the only order that proves anything — measuring the baseline through a
live bridge reports the carrier's address as the Mac's own and scores every
bridged row as a leak.

### Answered: usbmux reaches a Network Extension

```
Device: 00008120-000000000000001E  deviceID=1  via=usb
  port 50505 (network extension): ANSWERED
  port 50506 (foreground app): refused
```

The preferred path works, so the bridge survives the phone being locked. The
app-port fallback is genuinely a fallback. **`spike/usb-probe` can now be
deleted** — its question is settled.

### Three bugs found here that nothing else could reach

All three are lifecycle transitions, invisible to 300+ passing tests and to two
rounds of review. Written up in REGRESSIONS.md.

1. **Stale relay port.** The redial guard compared against a variable the caller
   had just assigned, so a new port never took effect.
2. **Orphaned route tunnel.** `routeManager` was only set on the session-live
   path, so a restart with no session left a default route into a
   packet-dropping tunnel that nothing could tear down — the Mac lost all
   networking and only `scutil --nc stop "UpLink Route"` by hand recovered it.
3. **Dropped announcement.** The relay announces its port once, at launch,
   before the proxy IPC channel exists. The message was lost and never retried.

### Restart recovery, after the fixes

```
15:12:42  session ENDED          (app quit)
15:12:48  usb: relaying …:54634  (new app, new port)
15:12:48  ipc: relay on …:54634
15:12:48  session started
```

~6 seconds, unattended. Before the fixes this state was permanent until the
cable was physically unplugged.

### Still not exercised

- **QUIC / HTTP-3** — this `curl` has no HTTP/3, so UDP 443 at bulk rates is
  still unmeasured. It is a different shape from DNS: long-lived, high-rate,
  many datagrams per destination.
- **The phone locked**, sustained. The extension port answering means it
  *should* hold; it has not been left locked under load.
- **Sustained throughput** over tens of minutes, and battery cost.

## Wired transport — the checklist, 2026-08-15

The transport changed from AWDL to the USB cable and **none of it has been run
on hardware yet.** Everything below is what a device run has to establish.
Record results here; do not report a pass that was not observed.

### Before anything

1. **Rebuild BOTH sides.** `release-mac.sh` is Mac-only. The phone needs
   `xcodebuild -scheme UpLinkiOS` + `devicectl device install app`, and
   installing does **not** restart an already-running NE extension. Confirm the
   bundle UUID with `xcrun devicectl device info processes` before drawing any
   conclusion — a whole round was once spent on a phone running old code.
2. **Never-bridge list by PATH, not bundle id**, and
   `com.apple.CoreDevice.remotepairingd` on it. Confirm the extension logs a
   non-empty `never bridging: [...]`.
3. **No commercial VPN** (utun7), or the coverage matrix cannot tell UpLink from
   it.
4. Phone on cellular only. Mac Wi-Fi radio **OFF, not merely disconnected** — a
   disconnected radio still holds a global SLAAC address and an IPv6 default
   route, and every dual-stack site then loads without touching the bridge.

### Already verified WITHOUT a device, 2026-08-15

```sh
swift run --package-path spike/usb-probe usb-probe --selftest
```

Talks to the real `/var/run/usbmuxd` with nothing plugged in. `ListDevices` and
`Listen` both answer on an empty Mac, so the header, the version, the message
type and the plist body are all exercised against Apple's implementation rather
than against our own fake.

| Date | Result |
| --- | --- |
| 2026-08-15 | **PASS** — and it immediately found `badVersion` was 5, not 6. See REGRESSIONS. |

What this does NOT establish: anything about the cable, the device, or the
Network Extension. Those are below.

### The one open question

```sh
swift run --package-path spike/usb-probe usb-probe
```

**Can `usbmux Connect` reach a listener inside a Network Extension?** Everything
else about the transport is already proven against a fake daemon; this is the
one thing a fake cannot answer.

- Extension port (50505) answers → the preferred path works. Record it and
  delete `spike/usb-probe`.
- Only the app port (50506) answers → the bridge will drop when the phone locks
  or the app is backgrounded. The product still works, degraded; this is the
  finding that would justify moving the listener.
- Neither → UpLink is probably just not running on the phone. A refused connect
  does **not** mean the cable or the lockdown pairing is broken.

| Date | Result | Notes |
| --- | --- | --- |
| 2026-08-15 | **ANSWERED — the Network Extension is reachable** | iPhone 15 Plus, `00008120-000000000000001E`, via=usb. `port 50505 (network extension): ANSWERED`. The preferred path works, so the bridge survives the phone being locked and the app being backgrounded. The app-port fallback (50506) was correctly refused, i.e. it is genuinely a fallback and not what is carrying the link. |

**So `spike/usb-probe` can be deleted** — its question is settled. Kept for now
only because `verify-wired.sh` uses it to enumerate the device.

One trap worth recording: the extension takes a few seconds to bind after
`process launch`, and a probe run too early reports "nothing answered on either
port", which reads exactly like "UpLink is not running on the phone". Check the
timestamp in the phone log against the probe before believing that.

### One command, once the cable is in

```sh
./scripts/verify-wired.sh
```

Waits for the cable (up to 10 minutes), then runs everything below in the order
the failures actually happen and prints one verdict. It refuses to summarise a
pass it did not observe. `verify-cellular.sh --full` inside it turns the Wi-Fi
radio off itself and restores it via a trap, so a failure cannot strand you.

The table below is what it checks, kept for reading when something fails.

### Then, in order

| # | Check | How | Result |
| --- | --- | --- | --- |
| 1 | Cable presence drives the UI | Unplug: menu bar reads **Waiting for USB connection**. Plug in with UpLink off on the phone: **iPhone connected — not answering**. Turn it on unpaired: **iPhone connected — not paired**. | |
| 2 | Pairing works first time | Mac shows a code, type it on the phone, session comes up without a retry. This is the flow that has actually been broken. | |
| 3 | Re-pairing works | Remove on the Mac, remove on the phone, pair again. Then remove on the Mac **while the phone is unplugged** and confirm the phone is told on its next session. | |
| 4 | The cable is genuinely the path | `./scripts/usb-status.sh`, then `./scripts/verify-cellular.sh --full`. **The cable check is inverted from the AWDL era** — it now fails if `awdl` appears anywhere. | |
| 5 | Egress is cellular, not the cable | The phone must not route back up the cable to the Mac. `verify-cellular.sh` greps the proxy log for the destination IP — the half that cannot be faked. | |
| 6 | Throughput | `./scripts/throughput-test.sh` against the radio's own bandwidth estimate. USB 2.0 over Lightning is ~25–40 MB/s, well above any cellular link, so the bridge should not be the bottleneck. If it is, `Frame.maxPayloadSize` and `Multiplexer.initialWindow` are the knobs — measure, do not guess. | |
| 7 | Survives a lock | Lock the phone mid-download. Only meaningful if the **extension** port answered in the probe above. | |
| 8 | Survives a replug | Pull the cable mid-session: the Mac must return to **Waiting for USB connection** promptly, not keep claiming flows it can no longer carry. Plug back in: it should reconnect without a click. | |

## One-time setup: the Developer ID certificate

The Mac app contains a **system extension**, and macOS activates one only if it
is Developer ID signed **and notarized**, or if SIP is disabled. We keep SIP on,
so every build is notarized. Setup is three steps, done once.

### 1. Create a Developer ID Application certificate

Xcode → **Settings → Accounts** → select your Apple ID → **Manage
Certificates…** → **+** → **Developer ID Application**.

An *Apple Development* certificate is not enough. Development provisioning
profiles never carry the `-systemextension` entitlement values the extension
needs, and an unnotarized extension is refused outright.

Verify:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Create an app-specific password

Sign in at **appleid.apple.com** → **Sign-In and Security** → **App-Specific
Passwords** → **+**. Name it something like "uplink notarization". Copy the
password; it is shown once.

This is not your Apple ID password. It is a scoped credential that can only be
used for this, and it can be revoked without touching your account.

### 3. Store the notary credentials in your keychain

```bash
xcrun notarytool store-credentials uplink-notary \
  --apple-id you@example.com \
  --team-id 9NT85V7Q37 \
  --password <the-app-specific-password>
```

Stored in the keychain under the profile name `uplink-notary`, which is what
`scripts/release-mac.sh` looks for. The password is never written to the repo.

### What notarization actually is

An **automated malware scan**, not App Store review. No queue, no human, no
submission in the App Store sense — typically 1–3 minutes. Your end users never
see it: they download the app, drag it to /Applications, launch it, and approve
the extension once. Gatekeeper silently verifies the stapled ticket.

---

## Running the Mac app

```bash
./scripts/release-mac.sh
```

Builds Release with Developer ID, notarizes, staples, installs to
`/Applications`, and launches. The script preflights both credentials above and
tells you exactly what is missing rather than failing cryptically.

Then approve once in **System Settings → General → Login Items & Extensions →
Network Extensions**.

Pressing Run in Xcode will build, but the extension will not activate — the
build is not notarized. That is expected, not a bug.

### Optional: close the ICMP leak

```bash
sudo ./scripts/block-icmp.sh on     # off / status also available
```

The transparent proxy carries TCP and UDP; ICMP has no path through it, so
`ping` still exits via this Mac and reveals its address. This adds a pf rule so
it is blocked rather than silently leaking. Reversible, and it backs up
`/etc/pf.conf` first.

## Running with no network of your own — read this first

**This is the configuration the product exists for, and it does not work out of
the box.** Measured 2026-08-14, Wi-Fi disconnected, bridge live and healthy:

```
IPv4 default route : NONE
flows claimed      : 0        <- handleNewFlow never fired at all
curl by IP         : exitcode 7
scutil --dns       : empty
```

`NETransparentProxyProvider` only ever receives flows the system was **already
going to route**. With no route, `connect()` fails before any NECP policy match,
so there is nothing to intercept: the bridge sits connected and completely idle
while every request dies in the socket layer. Controlled comparison, same
machine, same second:

```
curl --interface en0 (has route)  ->  http 301,    2 flows claimed
curl --interface en9 (no route)   ->  exitcode 7,  0 flows claimed
```

Both missing pieces — a route and a resolver — come from having a configured
network service, so give the Wi-Fi service a standing one:

```bash
sudo ./scripts/standalone-mode.sh on
sudo ./scripts/standalone-mode.sh keep     # cancel the 180s auto-revert
```

Verified working with it applied:

```
route:  169.254.99.1 via en0     <- a gateway that goes nowhere
https://1.1.1.1      http 301
https://example.com  http 200    <- DNS resolving too
public IP            216.77.46.31 (carrier, not this Mac's ISP)
```

Nothing is ever sent to that gateway. It exists so `connect()` succeeds and the
flow reaches the proxy, which carries it to the phone. Link-local on purpose: a
flow the proxy fails to claim dies on this machine rather than leaking.

**Turn it off when you are not bridging** — `sudo ./scripts/standalone-mode.sh
off`. With it on and no bridge, the Mac has a default route to nowhere and no
internet at all.

**This is a configuration workaround, not the finished product.** The app should
apply and remove it with the session. It cannot today: the extension is
sandboxed so it cannot call `route`, and the app is not root. Doing it properly
needs a privileged helper (`SMAppService`) or moving the Mac side to
`NEPacketTunnelProvider`, which would also fix DNS natively — `NEDNSSettings`
applies to a packet tunnel and is silently ignored by a transparent proxy.

## Before you run anything: keep your own connection

If you are driving the run from the Mac being bridged — which you are — put
whatever you need to stay online on the never-bridge list first:

```bash
defaults write com.uplink.app UpLinkDirectApps -array <signing-identifier>
```

Find the identifier by watching the extension claim a flow:

```bash
log stream --predicate 'subsystem == "com.uplink.app"' | grep '^.*claim '
```

A UDP flow is claimed before any destination is known, so this is the **only**
exclusion that works for UDP. Naming a host does not help.

Keep the list to the tools actually driving the run. In particular
`com.apple.CoreDevice.remotepairingd` — the Mac↔iPhone developer channel —
**used** to need to be on it, because it reaches the phone at the phone's
*global* IPv6 address on the home LAN and the capture policy could not tell that
from a real internet host. Left unexcluded it produced 1217 claims in seconds
and ended the session within three. That is fixed properly now: the policy reads
this Mac's own interface prefixes at session start and refuses to bridge any
network it is attached to. If you find yourself adding a system service to the
never-bridge list, that is a bug in the policy, not a configuration step.

Check what the extension actually received — an empty list is logged too, since
a misconfigured hatch otherwise looks identical to a build without it:

```
never bridging: [com.anthropic.claude-code]
capture policy: peer=… resolvers=… on-link=[v6/64,v4/24,v6/64,v4/16]
```

`./scripts/emergency-off.sh` is still the backstop, but it is a recovery tool,
not a safety mechanism: it runs after the Mac has already gone dark, and by then
the session you were measuring is gone.

## Measuring coverage

```bash
./scripts/coverage-test.sh
```

**The baseline must be measured before the bridge is up.** This script refuses
to run without a live session — correctly — which means it cannot take its own:
by the time it starts, the transparent proxy is in front of every flow, and a
proxy claims flows regardless of the interface a socket binds to, so
`--interface en0` does not escape it. For as long as this harness existed its
baseline came back as the *carrier's* address, and every genuinely bridged row
was then scored `DIRECT ✗` for matching it. One run, eight lines apart:

```
prove-bridge step 4:  216.77.46.31  CHANGED — traffic is leaving via the phone
coverage row 1:       DIRECT ✗ 216.77.46.31
```

`prove-bridge.sh` now takes the baseline at step 0, before connecting, and
exports `UPLINK_BASELINE_V4` / `UPLINK_BASELINE_V6`. Run `coverage-test.sh`
alone and it refuses rather than guessing. Prefer running it through
`prove-bridge.sh`.

Prints a matrix of which traffic classes actually egress through the phone.
Rows 1–6 must show the **carrier's** IP; row 7 (ICMP) must be blocked. Anything
showing `DIRECT` bypassed the bridge and revealed this Mac's real address.

The harness baselines **both** IPv4 and IPv6, because IPv6 is a separate leak
path and a v4-only baseline would score a leaked v6 result as "bridged".

## Checklist

Copy this block per run.

```
Date:
Build:            (git rev-parse --short HEAD)
Transport:        peerToPeer | localLink
macOS / iOS:
Carrier:

[ ] 1. Pair — Mac shows a code, phone accepts, both Keychains hold the peer key
[ ] 2. Connect — phone shows Cellular, Mac menu bar shows "Connected — … Cellular ✓"
[ ] 3. User-facing check — menu bar header reads Cellular ✓, not Wi-Fi
[ ] 4. Developer check — `curl ifconfig.me` on the Mac returns the CARRIER's IP
       If 3 and 4 disagree, the egress reporting is broken and 3 is worthless.
[ ] 5. Background — lock phone, switch apps, wait 10 min → Mac still connected
[ ] 6. Throughput — speed test vs. a plain hotspot baseline
       plain hotspot:      ____ Mbps down / ____ up
       through UpLink:     ____ Mbps down / ____ up
[ ] 7. Watchdog fires — bridge up on a SEPARATE Wi-Fi, banner at ~120s
[ ] 8. Watchdog does NOT fire — bridge up over the phone's OWN hotspot, no banner
[ ] 9. Stop — clean teardown, Mac returns to "Waiting for iPhone"

Notes:
```

## Phase 0 spike results

The two questions the architecture is waiting on. Until these are answered,
`TransportProfile.preferenceOrder` is a guess.

| Question | Result | Date |
| --- | --- | --- |
| Does AWDL (`includePeerToPeer`) survive inside an `NEPacketTunnelProvider`? | **yes** — carried a full session, `peer=…%awdl0` | 2026-08-14 |
| …with the phone **locked**? | not yet run — every session so far has been with the phone awake | |
| Sustained AWDL throughput | not yet run | |
| Does iOS accept `NEPacketTunnelNetworkSettings` with empty `includedRoutes`, and keep the extension alive? | not yet run | |

If AWDL fails: drop `.peerToPeer` from `TransportProfile.preferenceOrder` and
ship over the hotspot / shared-Wi-Fi link, which needs no code change elsewhere.

## Run history

### 2026-08-14 — UDP works on hardware

```
Date:             2026-08-14 08:37–08:47 PDT
Build:            cd967f5 (+ harness fixes)
Transport:        peerToPeer (awdl0) / localLink (en8) both observed
macOS / iOS:      macOS 15, iOS 17 — MacBook Air ↔ iPhone 15 Plus
Carrier:          AT&T, 5G NSA (kENDCSub6)
Config:           Mac on home Wi-Fi (deliberate — see below)
```

**The line that settles it**, from the phone's own log:

```
08:37:57.953  udp dial ok 1.1.1.1:53
08:37:58.201  udp reply 1 from 1.1.1.1:53  51 bytes
```

248 ms — a cellular round trip. Last night the same two lines were 3 ms apart
and read `ended after 0 replies`. Three concurrent queries, three answers.

| Measure | 2026-08-13 | 2026-08-14 |
| --- | --- | --- |
| `udp flow failed` | 296 in 25 min | **0** |
| `ended after 0 replies` | every DNS query | **0** |
| `tcp FAIL` | 4 claims, 0 opens | **0** (77 claims) |
| `udp dial FAILED` | — | **0** |
| 25 MB download | 6.71 Mbps | **223.92 Mbps** |
| 5 MB upload | n/a | 34.45 Mbps |

Coverage matrix, against a baseline taken with the bridge **down**
(`203.0.113.21` / `2001:db8:1:2:a113:aa40:7944:eaf4`):

```
1. TCP, proxy-aware (curl)         bridged ✓ 216.77.46.31
2. TCP, ignores proxy              bridged ✓ 216.77.46.31
3. TCP, raw socket                 bridged ✓ 2600:387:15:6712::7
4. UDP (DNS)                       bridged ✓ 2600:382:a609:6fb9:…
5. QUIC / HTTP-3                   n/a — curl has no HTTP/3
6. IPv6                            bridged ✓ 2600:387:15:6712::7
7. ICMP (ping)                     DIRECT ✗ — expected; block-icmp.sh not run
```

Rows 4 and 6 were `DIRECT ✗` yesterday. Row 7 is the documented API limit:
`NETransparentProxyProvider` does not intercept ICMP, and `block-icmp.sh` was
not applied for this run.

QUIC (row 5 reads `n/a` only because this curl lacks HTTP/3 — the phone log is
better evidence):

```
udp 2620:149:af6::10:443 ended after 19 replies
udp 2620:149:af1::10:443 ended after 19 replies
```

Nineteen replies from one destination is exactly the case the `isComplete` bug
killed at the first. No stream exhaustion, no credit starvation, no framing
errors over the run.

**Checklist**

```
[x] 1. Pair — survived reinstalling both apps
[x] 2. Connect — phone shows Cellular, egress: Cellular in the Mac log
[x] 3. User-facing check — egress reported Cellular
[x] 4. Developer check — carrier IP 216.77.46.31 vs baseline 203.0.113.21
[ ] 5. Background — not exercised this run
[x] 6. Throughput — 223.92 Mbps down / 34.45 Mbps up
       phone's own downlink estimate: 70–84 Mbps (CommCenter, conservative)
[ ] 7. Watchdog fires — not exercised
[ ] 8. Watchdog does NOT fire — not exercised
[x] 9. Stop — clean teardown via UPLINK_AUTOCONNECT=stop
```

**What this run does NOT prove.** It was taken with the Mac still on home
Wi-Fi, deliberately: the run was driven from this Mac over this Mac's own
connection, and with Wi-Fi off there is no path for the operator's traffic at
all — the never-bridge list keeps it off the phone, which with no other route
means no route. Rows 1–6 showing the carrier's address proves the traffic
*went through the phone*; it does not prove the bridge works as the only
network. That is the Wi-Fi-off run, still outstanding, along with items 5, 7
and 8.

**Three harness defects found and fixed during this run**, each of which made a
working bridge look broken:

1. `coverage-test.sh` measured its baseline *through* the live bridge, so every
   bridged row scored `DIRECT`.
2. `prove-bridge.sh` baselined without stopping the phone, which reconnects on
   its own — same defect, one level up. `--terminate-existing` was missing, so
   `UPLINK_AUTOCONNECT=stop` was silently ignored.
3. Both scripts judged liveness on a 2-minute log window. A session logs on
   start and end and nothing in between, so a healthy connection of 140 seconds
   read as no session at all.

All three share a shape: **treating the absence of a recent log line as
evidence about the present state.**

### 2026-08-14, later — IPv6 on-link fix, device verification OUTSTANDING

The run above was only possible because `com.apple.CoreDevice.remotepairingd`
was put on the never-bridge list by hand. That was papering over a real defect:
the capture policy could not recognise a globally-scoped IPv6 address on this
Mac's own LAN as local, so it bridged every IPv6 neighbour — including the
Mac's own control channel to the phone, which ended the session in three
seconds.

Fixed by reading this Mac's interface prefixes (`LocalNetworks` /
`OnLinkNetwork`) and refusing to bridge any network it is attached to. Verified
off-device: 248 tests, both halves confirmed red before the fix, and a test that
reads this machine's real interfaces and asserts they never exclude the
internet. Confirmed the prefix actually read on this Mac is
`2001:db8:1:2::/64` — exactly the one containing the phone.

**Confirmed on hardware, 09:17.** The never-bridge list was trimmed to just
`com.anthropic.claude-code`, so nothing but the policy itself was protecting the
session:

```
never bridging: [com.anthropic.claude-code]
capture policy: peer=fe80::2063:e4ff:fed6:7ce0%awdl0:51435 resolvers=
                on-link=[v6/64,v6/64,v4/24,v6/64]

claims by com.apple.CoreDevice.remotepairingd:  0     (was 1217)
sessions started: 1     sessions ended: 0       (was: ended within 3s, every time)
```

Stable across the full seven-minute run. The only Apple services claimed were
`com.apple.curl` and `com.apple.dig` — the coverage probes themselves. Rows 1–6
bridged, row 7 ICMP as before.

**The peer link ran over AWDL** (`%awdl0`), not the USB cable that was attached.
The cable serves `devicectl` only — launching the app on the phone from a
script. No part of the product's path uses it: the Mac↔phone hop was
peer-to-peer Wi-Fi and egress was the cellular radio. So this run does prove the
cable-free path, despite a cable being plugged in.

Throughput this run was 50.3 Mbps against a direct reference of 53.3 — about
94% of what this Mac gets on its own connection, on a sample where the home link
was slower than the 08:37 run.

Incidentally this answers half of Phase 0's first spike question: **AWDL does
survive inside a Network Extension** and carried a full session. The other half,
whether it survives with the phone *locked*, is still unrun — every session so
far has been with the phone awake.
