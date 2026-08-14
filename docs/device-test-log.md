# On-device test log

The Simulator has no cellular radio and no real Network Extension host, so none
of the checks below can be run by CI or by an agent. Record every pass here with
a date, so "it worked" is evidence rather than memory.

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
| Does AWDL (`includePeerToPeer`) survive inside an `NEPacketTunnelProvider` with the phone locked? | not yet run | |
| Sustained AWDL throughput | not yet run | |
| Does iOS accept `NEPacketTunnelNetworkSettings` with empty `includedRoutes`, and keep the extension alive? | not yet run | |

If AWDL fails: drop `.peerToPeer` from `TransportProfile.preferenceOrder` and
ship over the hotspot / shared-Wi-Fi link, which needs no code change elsewhere.

## Run history

_(none yet)_
