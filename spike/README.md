# Phase 0 spike

Throwaway. **One** question the wired transport is waiting on, answerable only
on a physical iPhone. Delete this directory once
[`docs/device-test-log.md`](../docs/device-test-log.md) records the answer.

## The question — ANSWERED 2026-08-15

**Can `usbmux Connect` reach a listener inside an iOS Network Extension? Yes.**

```
Device: 00008120-000000000000001E  deviceID=1  via=usb
  port 50505 (network extension): ANSWERED
  port 50506 (foreground app): refused
```

The preferred path works, so the bridge survives the phone being locked, and
the app-port fallback is genuinely a fallback rather than what carries the link.

This directory survives only because `scripts/verify-wired.sh` uses the probe to
enumerate the device and to report which port answered. The *spike* is over;
what is left is a diagnostic. Delete it if that script ever grows its own
enumeration.

### The original question, for context

Everything else about `usbmuxd` is already proven by `swift test` against a fake
daemon — the framing, the byte-swapped `PortNumber`, attach/detach streaming,
the Wi-Fi-device filter, `Connect` refusal, and the byte pipe that follows a
successful connect. None of that needs hardware, which is the point: the last
transport was debugged one device round-trip at a time, and a whole test round
was spent on a phone running stale code.

This is the one thing a fake cannot answer. `usbmux` reaches app-hosted
listeners routinely — it is how `iproxy` works and how every dev tool talks to a
debug server on a device — and an extension is an ordinary process with no
documented restriction. But it has never been tried here, and the difference
matters: the extension keeps running while the phone is locked; the app does
not.

## Why it does not block anything

The answer is already designed around rather than waited on. The phone binds
**two** ports and the Mac tries them in order:

- `UpLinkUSB.extensionPort` (50505) — the Network Extension. Preferred.
- `UpLinkUSB.appPort` (50506) — the foreground app. The fallback.

So if the extension turns out to be unreachable, the product still works with
UpLink open on the phone — degraded, and *visibly* so, because
`scripts/usb-status.sh` says which port answered rather than leaving it to be
inferred from a bridge that mysteriously dies at lock.

## Running it

With the phone plugged in and UpLink running on it:

```sh
swift run --package-path spike/usb-probe usb-probe
```

It prints which port answered and what that means. `--watch` streams attach and
detach events instead, which is the quickest way to confirm the cable and the
lockdown pairing are healthy at all.

## What the previous spikes settled

`awdl-probe` and `pair-probe` are gone with the AWDL transport. Two of their
findings outlived them and are now permanent, in code rather than in a spike:

- **TLS 1.3 does not carry an external PSK** in Network.framework — the
  handshake fails with `-9858`, and because it surfaces as `.waiting` rather
  than `.failed` it presents as a connection that hangs forever. The version is
  pinned to 1.2 in `TransportParameters.applyPSKCiphersuite`, with the
  measurement written next to it.
- **The pairing salt cannot be a display name.** Names travel through DNS-SD,
  get renamed for uniqueness, and routinely contain U+2019, which round-trips
  differently and yields a different key with no usable diagnostic. Guarded by
  `PairingSaltRegressionTests`.
