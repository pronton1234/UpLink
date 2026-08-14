# Setting up UpLink from scratch

For a Mac and an iPhone that are already paired. If they are not, see
"Pairing" below.

The order matters in one place: **standalone mode goes on last and comes off
first**, because it deliberately leaves the Mac with a default route that only
the bridge can service.

---

## 0. If you are currently offline, start here

Standalone mode leaves the Mac with an address and a gateway that only work
while the bridge is carrying traffic. With the app quit, or Wi-Fi joined to
nothing, that is a Mac with no internet.

```bash
sudo ./scripts/standalone-mode.sh off      # back to DHCP
```

Then rejoin your Wi-Fi network from the menu bar. Confirm:

```bash
curl -s https://api.ipify.org; echo
```

If that prints your ISP address you are back to normal, and nothing below is
urgent.

---

## 1. Mac: install and approve the extension

The Mac app is not usable from Xcode — macOS will not activate a system
extension from a build in derived data, and the extension needs a Developer ID
signature and notarization.

```bash
./scripts/release-mac.sh
```

Builds, notarizes, staples, installs to `/Applications/UpLink.app`, and
launches it. Roughly four minutes, most of it waiting on Apple.

**First run only:** approve it in
System Settings → General → Login Items & Extensions → **Network Extensions**.

Check it took:

```bash
systemextensionsctl list | grep uplink        # want [activated enabled]
log show --last 2m --predicate 'subsystem == "com.uplink.app"' --style compact \
  | grep -E "listening as|never bridging"
```

`listening as '<your Mac>' sessionKeys=N` means it is up and knows about N
paired phones.

## 2. iPhone: install the app

There is no script for this; `release-mac.sh` is Mac-only. The phone must be
unlocked and connected.

```bash
xcodebuild -project UpLink.xcodeproj -scheme UpLinkiOS -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/ios-device \
  -allowProvisioningUpdates build

xcrun devicectl device install app --device <UDID> \
  build/ios-device/Build/Products/Debug-iphoneos/UpLink.app
```

Find the UDID with `xcrun devicectl list devices`.

**Do not skip this after changing shared code.** `BridgeResponder` — the half
that dials destinations over cellular — runs on the *phone*. A Mac-only deploy
leaves the phone running the old build while everything looks freshly built.

## 3. Pairing

Only needed once per phone; it survives reinstalling both apps.

1. On the Mac, open UpLink from the menu bar and choose to add a device. A code
   appears.
2. On the phone, open UpLink, pick the Mac, and enter the code.

Both sides store the peer's key in their Keychain. `sessionKeys=1` in the Mac's
log means one phone is paired.

## 4. Connect

Open UpLink on the phone and connect to the Mac. The phone drives every
session; the Mac is passive and simply waits.

Confirm from the Mac:

```bash
log show --last 5m --predicate 'subsystem == "com.uplink.app"' --style compact \
  | grep -E "session started|egress:|capture policy"
```

Want to see:

- `session started with <fingerprint>`
- `egress: Cellular` — traffic really is leaving over the radio, not Wi-Fi
- `capture policy: peer=…%awdl0…` — `awdl0` is the peer-to-peer Wi-Fi link,
  `en8`/`en9` is the USB cable if one is plugged in. Both work.

At this point the Mac is bridging **while still on its own network**. Browsing
already goes through the phone; check with `curl -s https://api.ipify.org`,
which should show the carrier's address rather than your ISP's.

## 5. Standalone mode — running with no network of your own

Only now, and only if you actually want the Mac running on the phone alone.

```bash
sudo ./scripts/standalone-mode.sh on
sudo ./scripts/standalone-mode.sh keep     # ← cancels the 180s auto-revert
```

**`keep` is not optional.** Without it the settings roll back to DHCP after
three minutes, and a test run after that rollback fails exactly as if nothing
had been fixed. That auto-revert exists because if standalone mode does not
work you lose the connection you would need in order to undo it.

Then disconnect Wi-Fi from its network in the menu bar — **leave the radio on**.
The radio is what carries the peer-to-peer link to the phone; turning it off
falls back to needing a USB cable.

### Why this step exists

`NETransparentProxyProvider` only ever receives flows the system was already
going to route. With no network joined, macOS has no primary service, therefore
no default route and no resolver, so `connect()` fails before the proxy is ever
consulted — measured: zero flows claimed, `scutil --dns` empty. Standalone mode
gives the Wi-Fi service a standing address, a gateway that goes nowhere, and a
public resolver, so the flow exists for the proxy to claim. Nothing is ever sent
to that gateway.

## 6. Verify

```bash
curl -s https://api.ipify.org; echo          # carrier address, not your ISP
curl -sI https://example.com | head -1       # HTTP/2 200 — proves DNS too
networksetup -getairportnetwork en0          # "not associated"
ping -c 1 -t 2 <your router>                 # should fail
```

If a browser was open across step 5, **quit and reopen it** — browsers cache an
"offline" verdict and will not retry until they see a network change.

## 7. Shutting down

In this order:

```bash
sudo ./scripts/standalone-mode.sh off
```

then rejoin Wi-Fi, then quit the apps. Turning the bridge off first leaves you
with a route to nowhere.

---

## If something is wrong

```bash
./scripts/emergency-off.sh
```

Quits the app, deactivates the system extension, removes any default route left
behind via `lo0`/`en9`/`awdl0`, and flushes DNS. Safe to run at any time.

The single most useful diagnostic, in order:

```bash
# 1. Is there a session at all?
log show --last 10m --predicate 'subsystem == "com.uplink.app"' --style compact \
  | grep -E "session started|session ENDED" | tail -1

# 2. Are flows reaching the extension? Zero here means no route, not a bad bridge.
log show --last 15s --predicate 'subsystem == "com.uplink.app"' --style compact \
  | grep -cE "claim (tcp|udp)"

# 3. Do they complete?
log show --last 2m --predicate 'subsystem == "com.uplink.app"' --style compact \
  | grep -cE "tcp open  "
```

**Zero claims is the signature of the routing problem, not of a broken bridge.**
A bridge that is connected and idle looks identical to one that is broken; the
claim count is what separates them.

## Keeping a tool online through a bridge failure

```bash
defaults write ~/Library/Preferences/com.uplink.app UpLinkDirectApps \
  -array com.example.tooling
```

Signing identifiers, never hostnames — a UDP flow has no destination at claim
time. Write the **path**, not the bundle id: a stale
`~/Library/Containers/com.uplink.app` makes `defaults write com.uplink.app` land
somewhere this app never reads, and `defaults read` will still show the value.

Confirm the extension actually got it — it logs the list even when empty:

```
never bridging: [com.example.tooling]
```

Note this is useless in standalone mode: excluding an app from the bridge when
the bridge is the only path means that app has no path at all.
