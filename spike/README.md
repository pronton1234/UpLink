# Phase 0 spikes

Throwaway. Two questions the architecture is waiting on, both answerable only
on a physical iPhone. Delete this directory once
[`docs/device-test-log.md`](../docs/device-test-log.md) records the answers.

## Why these block anything

`TransportProfile.preferenceOrder` currently reads `[.peerToPeer, .localLink]`.
That ordering is a **guess**. Apple's documented position is that peer-to-peer
networking stops when a process is suspended; a Network Extension is not
suspended, so AWDL *should* survive inside one — but nothing documents it either
way, and the user's non-negotiable requirement is that the bridge keeps working
with the phone locked.

If AWDL turns out not to survive, the fix is one line: drop `.peerToPeer` from
`preferenceOrder`. Everything else already works over the phone's Personal
Hotspot or a shared Wi-Fi network. That is why this is a spike and not a
redesign — the answer changes one array, not the architecture.

## Spike 1 — does AWDL survive inside a Network Extension?

**Instrument (Mac):**

```bash
cd spike/awdl-probe && swift run
```

It advertises `_uplinkspike._tcp` with `includePeerToPeer = true`, accepts one
connection, echoes whatever arrives, and prints a line every second. Watch for:

- `READY interfaces: … awdl0 …` — confirms the link really is peer-to-peer. If
  `awdl0` is absent the probe warns you, because a result measured over
  infrastructure Wi-Fi answers a different question than the one being asked.
- `LIVE` — link healthy, with current throughput.
- `GAP` / `DEAD` — **the whole point.** Every second of silence is a second the
  real bridge would have been down.

**Phone side.** The production app already speaks both transports, so it is the
cleanest probe. In `UpLinkKit/Sources/UpLinkKit/Transport/NetworkTransport.swift`:

```swift
public static var preferenceOrder: [TransportProfile] { [.peerToPeer] }
```

Forcing the list to AWDL only means a fallback cannot silently rescue the run
and make a failure look like a success.

**Procedure.** Turn Wi-Fi off on both devices so no infrastructure network can
stand in. Start the probe on the Mac. Connect from the phone. Then:

1. Lock the phone. Wait 2 minutes. Still `LIVE`?
2. Switch to another app. Wait 2 minutes. Still `LIVE`?
3. Leave locked and idle for 10 minutes. Worst gap?
4. Walk out of range and back. Does it recover?

**Pass:** no `DEAD` lines, worst gap under ~2s, sustained throughput usable
(tens of Mbps).
**Fail:** any `DEAD` line while the phone is locked → drop `.peerToPeer`.

## Spike 2 — is a route-less packet tunnel accepted and kept alive?

`PacketTunnelProvider` sets `NEIPv4Settings.includedRoutes = []` and excludes
the default route, so the tunnel captures none of the phone's own traffic and
exists purely as a process host. Two ways this could fail: iOS might reject the
settings outright, or it might accept them and then reap an extension it
considers idle.

**Procedure.** No extra code — the production tunnel already does this.

1. Connect from the phone; confirm the Mac reaches `Connected`.
2. On the phone, confirm ordinary browsing still works normally. It must be
   completely unaffected — if the phone's own traffic changed at all, the tunnel
   is capturing something it should not be.
3. Leave it connected and idle for 30 minutes with the phone locked.
4. Check the Console for `stopTunnel` with a reason you did not cause.

**Pass:** settings applied, phone traffic untouched, no unexplained
`stopTunnel`.
**Fail:** give the tunnel a real but unused route (a dummy /32 in a reserved
range) instead of an empty `includedRoutes`, and re-run.

## Recording the result

Fill in the Phase 0 table in [`docs/device-test-log.md`](../docs/device-test-log.md),
then delete this directory. A spike's output is an answer, not code.
