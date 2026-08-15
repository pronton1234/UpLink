# Regression policy

**Every bug fixed gets a test that fails before the fix and passes after.**

No exceptions. If you cannot make the test fail first, you do not yet understand
the bug well enough to be confident the fix addresses it.

## Where they go

`UpLinkKit/Tests/UpLinkRegressionTests/`, deliberately separate from
`UpLinkKitTests`. Unit tests describe how a component works today and are fair
game to rewrite when that component is redesigned. Regression tests describe
defects that actually happened, and they survive redesigns — that separation is
the entire reason the target exists.

## How to write one

1. Name it for the **defect**, not the code: `testWatchdogDoesNotFireOnBridgingHotspotLink`,
   not `testWatchdogTimer`.
2. Open with a `// SYMPTOM:` comment describing what the user saw. Six months
   from now that comment is the only thing that explains why the test exists.
3. Watch it fail. Comment out the fix, run it, confirm it fails for the right
   reason, restore the fix. A regression test that has never been red proves
   nothing.
4. Never delete one because "the code obviously handles that now". That is
   precisely the moment it starts earning its keep.

## Seeded from design hazards

These were written before the code they guard, from failure modes identified
during design rather than from bugs found in the field:

| Test | Guards against |
| --- | --- |
| `oversizedPayloadLengthIsRejected` | A peer claiming a 4 GiB payload OOM-kills the extension |
| `arbitraryGarbageNeverTraps` | Malformed input traps instead of throwing, dropping every proxied flow |
| `truncatedFrameIsNotYielded` | A partial payload is handed on as complete, corrupting a stream |
| `exhaustedStreamDoesNotStarveOthers` | One large download head-of-line blocks every other stream |
| `windowAccountingIsPerStream` | Draining one stream grants credit on another |
| `closedStreamIDsAreNotImmediatelyReused` | A late frame lands in an unrelated new flow |
| `closedStreamBookkeepingIsBounded` | Per-stream state leaks across a long session |
| `concurrentStreamsAreCapped` | A peer opens unbounded streams and exhausts memory |
| `wifiFallbackIsReportedHonestly` | The UI claims "Cellular ✓" while traffic egresses over Wi-Fi |
| `unreachableDestinationDoesNotKillTheSession` | One dead host drops every other tab |
| `bridgingHotspotIsNotAnAlternative` | "Switch to Wi-Fi!" fired about the very link being bridged over |
| `pathLossCancelsTimer` | Notification after the user walks out of range |
| `matchesAcrossAddressChange` | Reconnect keyed on address, which changes on every local-link reconnect |
| `doesNotMatchStrangerAtSameAddress` | A different Mac inheriting the address and being handed a cellular session |
| `backoffIsCapped` | An overnight outage leaving the user waiting hours after reopening the lid |

## The TLS-PSK handshake

Pairing failed on a real iPhone every time for days while all 159 tests passed,
because **nothing off-device had ever opened a real TLS connection**. Every
pairing test checked key-schedule maths or the attempt state machine — the parts
that were already correct.

| Test | Guards against |
| --- | --- |
| `correctCodePairs` | The handshake not completing at all, on any transport |
| `productParametersNegotiate` | A TLS configuration in which the PSK is never offered |
| `tls13FloorStillBroken` | Silently reintroducing the TLS 1.3 floor that caused this |
| `rejectedHandshakeFailsFast` | A wrong code taking 12s, or forever, to report |
| `connectTimeoutIsBounded` | A connection with no deadline at all |
| `listeningAfterShowingACode` | The Mac going off the air while a code is displayed |

Two defects, one symptom:

1. `sec_protocol_options_add_pre_shared_key` **does not work under TLS 1.3** in
   Network.framework. The transport pinned a TLS 1.3 floor, so the PSK was never
   offered and the handshake failed with -9858. The fix is to name an explicit
   PSK ciphersuite; `spike/pair-probe --tls` measures which ones negotiate, and
   is the tool to re-run rather than reasoning about it.
2. That failure surfaces as `.waiting`, not `.failed`. `NWConnectionChannel`
   resumed only on `.ready`/`.failed`/`.cancelled`, so it did not fail — it hung
   forever, with no error anywhere.

**The lesson worth keeping: a handshake is not tested until two real sockets
complete one.** Key-schedule tests prove both sides compute the same bytes; they
say nothing about whether the transport will carry them.

## Throughput: one stream must not stall another

The bridge worked and was still no faster than the throttled hotspot it exists
to replace. Every correctness test passed, because every one of them used a
dialer that answered instantly and a destination that never blocked.

`BridgeResponder.run()` is a single sequential task: until `handle(_:)` returns,
the next frame is not decoded. Both the destination dial (DNS + TCP handshake,
60–230 ms on cellular) and the destination write were awaited inside it, so one
connection being established — or one congested socket — stalled *every* stream
on the link.

| Test | Guards against |
| --- | --- |
| `slowDialDoesNotBlockOtherStreams` | Dialling back on the frame loop |
| `slowWriteDoesNotBlockOtherStreams` | Destination writes back on the frame loop |
| `concurrentOpensDoNotSerialise` | A page's worth of opens costing the sum of its dials |
| `refusedDestinationFailsFast` | A dial hanging instead of failing |
| `connectTimeoutIsBounded` | A destination dial with no deadline |
| `transferLargerThanWindowCompletes` | Credit exhaustion that never resolves |
| `receiveBufferIsBounded` | Unbounded buffering killing the extension on its memory limit |

Each of the first three was checked against the old code before being kept:
they fail at 0.61 s / 0.63 s against a 0.4 s budget, and at 3.13 s against 2 s
for twenty opens — exactly 20 × 150 ms of serialised dialling. **A timing
regression test that has never been seen to fail is not a regression test.**

Two related fixes are pinned here rather than in their own section. The
`Task.yield()` retry used on credit exhaustion read like waiting but was a spin:
every starved stream re-entered the actor immediately, competing with the frame
loop that had to deliver the WINDOW frame that would unblock it. And
`CellularDialer` did not handle `.waiting`, so a refused or unresolvable
destination hung forever instead of failing — the cause of the
`udp flow failed: The peer closed the flow` flood in the device logs, and the
same defect class as the TLS hang above.

**The lesson worth keeping: a concurrency property is not tested by a test that
never makes anything slow.** Correctness fixtures answer instantly, which is
precisely why they cannot see head-of-line blocking.

## Local traffic must not be bridged

With the bridge up and the phone correctly reporting "Cellular", browsing still
felt like the throttled hotspot. The device log carried **296
`udp flow failed: The peer closed the flow` entries in 25 minutes, and zero TCP
failures** — the shape of the problem was in that asymmetry.

The Mac's DNS resolvers were its home router: `192.168.1.254` and
`2001:db8:1:2::1`. Nothing excluded them, so every lookup was sent across
the bridge to a phone that cannot reach a router on someone's home LAN. Each
query timed out and retried, and since no connection starts before its name
resolves, the whole machine felt throttled while the bridge was accurately
reporting cellular egress.

The second half: refusing to bridge is not the same as being able to ignore.
`NEAppProxyUDPFlow` has no remote endpoint — a UDP flow is a session that sends
to many destinations — so it must be claimed before any of them are known, and
a claimed flow is ours to service completely. Datagrams the policy rejected were
dropped, and the system will not deliver what we declined. Hence
`LocalDatagramRelay`: excluded destinations go out this Mac's own interface and
the replies are written back into the flow.

| Test | Guards against |
| --- | --- |
| `resolversAreNeverBridged` | DNS sent to a router the phone cannot reach |
| `globallyScopedResolverIsExcluded` | Assuming a resolver can be spotted by address prefix |
| `privateNetworksAreNotBridged` | A printer, NAS or LAN host handed to a cellular phone |
| `publicTwelveSevenTwoIsBridged` | Over-excluding: 172.16/12 is not all of 172/8 |
| `publicDestinationsAreBridged` | Excluding so much that nothing is bridged at all |
| `originalGuardsIntact` | The new rules quietly dropping the self-capture guard |
| `peerSubnetIsPrivate` | A second host on the hotspot subnet being bridged |

A globally-scoped address can still be the local router — `2001:db8:1:2::1`
is indistinguishable from a real internet host by inspection. Resolvers are
therefore read from the system (`SystemResolvers`, via `SCDynamicStore`) and
named explicitly, not inferred.

**The lesson worth keeping: "do not send it over the bridge" and "do not send it
at all" are different instructions, and a claimed flow only accepts the first.**

## Nothing on the flow path may wait forever

Three separate outages in one evening, one defect class. Each time the fix was
made for the specific call site; this section exists so the *class* is the thing
that gets remembered.

| Occurrence | The await that hung | How it presented |
| --- | --- | --- |
| TLS handshake | resumed only on `.ready`/`.failed`, but rejection arrives as `.waiting` | pairing hung with no error, for days |
| `CellularDialer` | same omission, on the destination dial | `udp flow failed` flood; streams stuck open |
| `NWConnectionChannel.send` | awaited `.contentProcessed` with no deadline | **every TCP row of the coverage matrix read "no connectivity"** |

The third is the sharpest. Receives were bounded by `receiveHighWater`; sends
were not. When the peer stopped draining, TCP backpressure meant
`.contentProcessed` was never called and every writer blocked — including the
one sending the OPEN frame for a newly captured flow. The log showed it exactly:

```
21:29:50  egress: Cellular      ← the channel was healthy here
21:29:54  tcp claim 191.96.106.7:443
…four claims, zero opens, zero failures…
```

`handleNewFlow` returning `true` means the extension **owns** that connection.
The system will not deliver it, and the app has no recourse. A step that hangs
therefore produces a flow owned by us and serviced by nobody — indistinguishable
from a dead network, and strictly worse than an error, because an error is
recoverable.

| Test | Guards against |
| --- | --- |
| `stalledPeerFailsTheWrite` | A peer that stops reading blocking every writer |
| `timeoutsAreBounded` | Any critical-path timeout being removed or made useless |

`stalledPeerFailsTheWrite` was verified against the unbounded version: it runs
past 75 seconds and never returns, versus 15.7 s with the deadline in place.

**The rule: if a claimed flow depends on it, it needs a deadline.** Not "should
be fast", not "cannot block in practice" — a deadline, and a failure path that
closes the flow so the app can retry.

## Un-retired: the capture-policy suite

This section used to say that `CapturePolicy` and its regression tests had been
deleted, because the Mac side had moved from `NETransparentProxyProvider` to an
in-process SOCKS5 proxy, and that the self-capture hazards were therefore
structurally gone. It ended: *"If a system-wide capture mechanism is ever
reintroduced, restore that suite first."*

**It was reintroduced.** The tree runs a `NETransparentProxyProvider` again — a
SOCKS proxy cannot carry UDP at all, so QUIC and DNS bypassed the bridge, and
DNS bypassing it defeats much of the point. The suite was restored, and
`CapturePolicy` plus `LocalTrafficRegressionTests` now carry about thirty tests
between them.

Worth keeping as a warning: for a while this file described, in the present
tense and with no hint it was stale, an architecture the code no longer had. A
doc that records decisions has to record the reversals too, or it confidently
misinforms the next person — which is worse than saying nothing.

The self-capture loop remains the worst failure this codebase can produce.

## UDP: three defects, one symptom

The bridge carried TCP at 98 Mbps and no hostname would resolve. All three
faults below produce that same symptom, and all three were live at once, which
is why fixing any one of them alone changed nothing observable.

| Test | Guards against |
| --- | --- |
| `A UDP destination answers more than once` | `isComplete` read as end-of-connection |
| `One destination answers several datagrams in a row` | the same, through the whole session |
| `A UDP session OPEN does not dial its placeholder destination` | the responder dialling `*:0` and closing the stream |
| `A reply that arrives after the client stops sending still gets through` | closing the flow when `readDatagrams` completes |
| `With no reply window the same answer is lost` | the window being removed, or made useless |
| `An excluded destination goes out directly and its reply comes back` | the direct outlet silently dropping datagrams |

**1. `isComplete` does not mean "the connection is over".** On a UDP
`NWConnection` it marks the end of each *message*, and every datagram sets it.
`NWDestinationConnection.pump()` treated it as end-of-stream, so a destination
died the instant its first reply arrived. A resolver is one destination expected
to answer many queries, so DNS was the worst victim while TCP was untouched.

**2. A UDP OPEN registers a session, not a connection.** `NEAppProxyUDPFlow`
carries datagrams to many hosts, so the OPEN carries the placeholder `*:0` and
each datagram addresses itself. `BridgeResponder.handle` sent every
`.openRequested` to `openDestination`, which dialled — and a dial of `*` cannot
succeed, so `failStream` wrote a CLOSE that killed the stream the flow had just
been given. `failStream` also tears down `datagramConnections[streamID]`, so the
device log showed a destination dialled and dead in the same breath:

```
23:55:13.541  udp dial ok 1.1.1.1:53
23:55:13.544  udp 1.1.1.1:53 ended after 0 replies
```

Every UDP flow raced that CLOSE. **This was found by an existing test failing
only when run alongside the rest of the suite and passing in isolation** — a
race, read at first as a flake. Every other datagram test wires the responder to
a stub dialer that answers for any host, `*` included, so none of them could see
it.

**3. A client with nothing more to send may still have something to receive.**
`readDatagrams` completes as soon as the client is done sending, which for DNS
is immediately after the single query. Closing the stream there discarded the
answer. The flow now holds a bounded reply window instead.

Fix 2 was initially suspected of making fix 3 unnecessary, since it produces the
same 3 ms evidence. It does not: with the dial bug fixed, `With no reply window
the same answer is lost` still fails without the window. **Two faults with
identical signatures are not one fault** — the only way to know was a test that
isolates each.

### The tester's own connection

A device run is driven from the Mac being bridged, over the connection being
bridged. When the UDP path broke, the operator's own API traffic went with it —
so the tool needed to diagnose the fault went offline exactly when the fault
happened, and recovering meant killing the app, which ended the session being
measured. Every run was one fault away from destroying its own evidence.

`CapturePolicy.directApps` names signing identifiers whose flows are never
claimed, set without a rebuild:

```bash
defaults write com.uplink.app UpLinkDirectApps -array <signing-identifier>
```

Keyed on the **app**, not the host, and that is not a preference. A UDP flow has
no destination at claim time and a datagram carries only an already-resolved
address, so no hostname rule can keep an app's UDP traffic off the bridge.

| Test | Guards against |
| --- | --- |
| `An excluded app's TCP flow is declined` | the hatch not applying to TCP |
| `An excluded app's UDP session is declined` | the case that actually broke |
| `Every other app is unaffected` | over-excluding |
| `An empty exclusion list changes nothing` | the hatch changing default behaviour |
| `The original guards are intact` | the new rule displacing self-capture, peer or loopback |

While doing this, `FlowAdmission` was found to have been "extracted so it is
testable" **into the test target**, while `handleNewFlow` went on inlining its
own copy of the same gates. The guard this file calls the worst failure the
codebase can produce was being verified against a replica; changing the code
that actually runs failed nothing. It now lives in `UpLinkKit/Support/` and
`handleNewFlow` calls it.

**The lesson worth keeping: a test fixture that reimplements the thing it tests
proves the fixture works.** Extraction means the production code loses the
logic, not that the test gains a copy of it.

### Testing across the app-target boundary

`pumpUDP` and everything it routed to lived in `Sources/UpLinkProxyExtension/`,
which the SwiftPM test bundle cannot import. So the code deciding where every
UDP packet on the machine goes had **zero** tests, and the only way to exercise
it was a signed, notarized, user-approved system extension on real hardware.

It now lives in `UpLinkKit/Mux/UDPFlowPump.swift` behind a `UDPFlow` protocol,
with the extension keeping only the `NEAppProxyUDPFlow` conformance.

**The lesson worth keeping: if the only way to run a piece of code is to deploy
it, it will only ever be debugged in production.** Where the code lives is a
testability decision, not just an organisational one.

## A globally-scoped address can still be on your own LAN

Found on hardware 2026-08-14, by logging *which app* was claiming each flow.

`CapturePolicy` excluded local addresses by prefix — RFC 1918 and RFC 4193.
That works for IPv4 and cannot work for IPv6: a home network is delegated a
globally routable /64, so this Mac at `2001:db8:1:2:a113:…` and the phone
sitting next to it at `2001:db8:1:2:23:…` both hold addresses
indistinguishable from a server in another country.

So every IPv6 neighbour on the user's own network was handed to a phone on a
cellular link that cannot reach it. The sharpest case was
`com.apple.CoreDevice.remotepairingd`, the Mac↔iPhone developer channel: the
Mac captured its own control connection to the phone and routed it *through*
the phone.

```
08:32:48  claim tcp 2001:db8:1:2:23:f710:2dae:d09d:49152
            by com.apple.CoreDevice.remotepairingd
08:32:49  tcp FAIL … handshakeFailed("write not acknowledged within 10s")
08:32:51  session ENDED
```

1217 claims in seconds, and the session died within three of starting, every
time. Note this is the self-capture loop again in a different costume — the
peer-endpoint guard checks the address the *session* is on, and remotepairingd
reaches the same phone by another one.

| Test | Guards against |
| --- | --- |
| `The phone's globally-scoped address on the home LAN is not bridged` | the defect itself |
| `Address prefixes alone cannot recognise it` | someone "simplifying" this back into a prefix rule |
| `A real internet host in a different /64 is still bridged` | over-excluding |
| `A public IPv4 network this Mac is on is excluded` | the v4 half |
| `A prefix broad enough to swallow the internet is refused` | one bad netmask excluding everything |
| `The real interface list never excludes the internet` | the same, against this machine's actual interfaces |
| `A scoped link-local address still parses` | `inet_pton` rejecting `fe80::1%en0` and skipping every link-local interface in silence |

Two things worth keeping from how this was tested:

- The IPv4 test originally used `169.254.4.183/16`, which **rule 3 already
  catches**. It passed with the new rule deleted — coverage that pinned
  nothing. A regression test has to fail for the reason you think it does, not
  merely fail to pass. It now uses a public /24.
- `LocalNetworks` was written in the extension and moved to the kit before it
  ever ran, per the section below. The test that matters most reads *this
  machine's real interfaces* and asserts they never exclude the internet — no
  unit test of the matching logic in isolation can make that assertion, and it
  is the entire safety argument for reading netmasks off a live system.

**The lesson worth keeping: this is the third time an address that looked
global turned out to be local** — the router as resolver, the resolver at
`2001:db8:1:2::1`, and now every neighbour on the LAN. Ask the system;
never infer locality from the bits.

## Rules of thumb these encode

Three of the failures above share a shape worth naming: **the bridge must never
consume its own machinery.** Capturing the link to the phone, capturing the
discovery traffic that finds the phone, and recommending the user leave the
network they are bridging over are all the same mistake at different layers.
When adding anything that acts on network state, ask what happens when it is
pointed at the bridge itself.

## Found on hardware, 2026-08-13

Both found while chasing "the Mac has no internet at all with Wi-Fi and hotspot
off" — the configuration the product exists for.

| Test | Guards against |
| --- | --- |
| `PeerLinkInterfaceRegressionTests` | The peer link being satisfied over cellular. `NWParameters` for the Mac connection constrained nothing, so with the radio up Network.framework pinned the link to `pdp_ip0` and *suppressed* the AWDL path that was the only one able to carry data. The connection reported `.ready` and moved nothing, so it presented as a hang rather than an error. Never seen over USB or shared Wi-Fi, where the peer link and the working path coincide. |
| `PeerWaitRegressionTests` | A dropped session becoming a permanent outage. `firstMatchingPeer` checked its 15s deadline inside `for await`, which only runs when the browser publishes. A browser with nothing to report publishes once and goes quiet, so the deadline never ran again and the reconnect loop could never retry. Observed as a session ending at 22:33:52 followed by eight minutes of silence from a phone sitting next to the Mac. |

Both were confirmed red before the fix: the first asserted on
`prohibitedInterfaceTypes` and saw `[]`; the second was proven by running the
original loop shape against a silent browser, which never returned within 400ms
while the replacement returned in 53ms.

## Found on hardware, 2026-08-14 — neither side could recover from a radio change

Wi-Fi disconnected from its network, radio on, no cable, no hotspot. A working
AWDL session died within 400ms of the kernel's

```
awdl0: interfaceStateChange: Infra link down, disable dynamic SDB
disableWorkQueueSources: Disable all AWDL timers
```

and the phone did not get back in for ~100 seconds. On the Mac there was **zero
`accept:`** in that entire window — so the phone was not being refused, it never
dialled. Two silences, one per side, and neither side had a sensor for its own.

| Test | Guards against |
| --- | --- |
| `DiscoveryRecoveryRegressionTests` — browser rebuild | A wedged `NWBrowser` being permanent. It had **no `stateUpdateHandler` at all**, so a browser that failed when its interface was reconfigured was undetectable; and `start(on:)` guarded on `browser == nil`, so it could not be replaced even deliberately. `firstMatch` then returned nil for the life of the tunnel. |
| `DiscoveryRecoveryRegressionTests` — staleness | A dead cached endpoint costing the full 12s `connectTimeout` on every retry, at the exact moment the device is trying to recover. `peers()` yielded `latest` unconditionally, so a result from before the radio changed was returned instantly and treated as current. |
| `AdvertisementRecoveryRegressionTests` — path change | The Mac silently ceasing to be findable. `restartListener()` was reachable only from `start()` and `setPairingCode()`; there was no `NWPathMonitor` anywhere in the kit, and the listener's state handler covered `.failed` alone, emitting an event nothing acted on. A listener that survives a radio change but stops being advertised on the re-derived `awdl0` is, from the Mac's side, indistinguishable from a healthy one. |
| `AdvertisementRecoveryRegressionTests` — debounce | The fix becoming its own failure. One Wi-Fi disconnect produces a burst of path updates, and the port changes on every rebuild (`NWListener` will not rebind a port it just released), so re-advertising per update makes a browser watch the service flap rather than settle. |
| `AdvertisementRecoveryRegressionTests` — stop | A host that cannot be stopped. `stop()` cancels the listener, and `.cancelled` is precisely what cancelling reports, so the new rebuild-on-terminal-state rule read a deliberate shutdown as a death and put the Mac straight back on the air — advertisement and bound socket outliving the user quitting. |

### Two notes on method

**The staleness test passed before it tested anything.** Its first version used a
never-started `PeerDiscovery`, whose `latest` is empty regardless — so it went
green with the fix deleted. It only became a test once the window was made
injectable and a peer was actually observed through a seam. This is the same
failure as the `169.254.4.183/16` case above, and it is now the second time
coverage has pinned nothing until it was watched red.

**Two of the five bugs were found by reading the tests' own log, not by
reasoning.** `stop()` resurrecting the listener and `awaitListening`'s 1s bound
being tighter than a rebuild both appeared as unexplained lines
(`listener died (cancelled) — rebuilding`, `listener did not bind within 1s`) in
a run where every assertion passed. Green is not the same as correct; the log a
passing test emits is evidence worth reading.

### A comment that was wrong, and was reasoned from

`MenuBarModel` claimed `NETransparentProxyManager` is a **subclass** of
`NETunnelProviderManager`, and both configuration lookups filtered on `is` to
avoid the resulting cross-contamination. They are **siblings** — both descend
from `NEVPNManager` — so neither filter could ever fire, which is what the
compiler had been warning. They now match on the configuration name. The bug was
harmless; the comment asserting a false fact about the framework was not, because
it is exactly the kind of thing the next reader takes on trust.

## Pairing, 2026-08-14 — "removing a device doesn't register, and re-pairing fails"

Two complaints, ten faults. Two of the worst were mine, introduced hours earlier
while fixing the first complaint, and one of those *was* the second complaint.

| Test | Guards against |
| --- | --- |
| `UnpairPropagationRegressionTests` — new session clears the flag | An unbreakable re-pair loop. `wasUnpairedByPeer` is checked ahead of `isConnected` on every status poll, and `clearUnpairedByPeer()` had **zero call sites** — so once set it answered "unpaired" for the life of the extension process. Re-pair, and the first poll told the app to delete the pairing it had just made. |
| `PairingFailureReportingTests` | A pairing failure that says nothing. A wrong code fails inside TLS and surfaced as an opaque `NWError`; an expired one gets *past* TLS and the Mac merely closed the channel. So `.codeMismatch`, `.expired` and `.tooManyAttempts` were values no path could produce, with good human strings that could never be shown. |
| `PairingCodeConsumptionTests` | A failure the user did not cause burning the code. `verify` consumed it before the response was written, and the Mac answered before committing its own side — so a failed save left the phone storing a Mac with no record of it, and the code was spent. |
| `PairedDeviceMergeRegressionTests` | A removed device coming back. The device poll's rule was additive, which undoes a removal two ways: it races the Remove button (the reply was composed before the removal, so the device looks new), and it copies resurrections back into the keychain. |
| `RevocationTombstoneRegressionTests` | A device unpaired while offline never finding out. The `unpaired` frame rides on the live session; with no session there is nothing to write to, and neither Bonjour nor TLS carries revocation state. |
| `PeerPairedLabelRegressionTests` | A green "Paired" seal against a Mac never paired with. `isKnown` was `fingerprint != nil` — "does this Mac publish an identity", which every UpLink Mac does — so the label misled precisely during a stale-pairing failure. |

### The method lesson, and it is the same one twice

**A test covering one half of an invariant reads exactly like a test covering
the invariant.** `unpairFlagSurvivesTeardown` was correct, necessary, and the
whole suite — so it pinned stickiness as though stickiness alone were the
requirement, and the missing half shipped. The fix was not just to add the
second test but to move the clearing *into* `runningSession`, where no caller
can forget it. That type already exists because of an invariant a caller forgot.

**Test the input the code actually receives.** `AWDLPresence.awdlHost` was
written and tested against the dot-separated form printed in the `accept:` log,
while `MacSessionHost.describe` passes a colon-separated one — so it was green
against a string the code never sees, and in production held towards a host with
`:52540` glued on. That is the third time this shape has appeared here, after the
`169.254.4.183/16` case and the staleness test that used a never-started
discovery.

**`(any Error).self` is not an assertion.** The consumption test's second half
would have accepted `.alreadyConsumed` — the exact failure under test — and
passed. It asserts by name now.

### Two gaps left open deliberately

- `handleSession` now refuses a fingerprint this Mac holds no key for, but does
  **not** bind the claim to the PSK identity actually negotiated, so one paired
  phone can still announce another's fingerprint. That needs
  `sec_protocol_options_set_pre_shared_key_selection_block` on the listener.
- The same missing block is why a wrong pairing code and a revoked device both
  produce `-9816` with nothing to tell them apart.
