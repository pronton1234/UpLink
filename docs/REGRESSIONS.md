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

### Two gaps left open deliberately — one now closed, and not the way it said

- ~~`handleSession` refuses a fingerprint this side holds no key for, but does
  **not** bind the claim to the PSK identity actually negotiated, so one paired
  peer can still announce another's fingerprint.~~ **Closed**, but the fix
  named here was wrong. It said to install
  `sec_protocol_options_set_pre_shared_key_selection_block` on the listener.
  Reading the SDK header shows that block is invoked *"when the **client** must
  choose a PSK identity given a hint from its peer"* — a client-side selection
  hook receiving the server's identity **hint**, not a server-side observer of
  the client's identity. It cannot answer the question, and building on it
  would have produced a fix that looked right and checked nothing.

  The binding is now an application-layer HMAC over the session key
  (``HelloProof``), carried in the `HELLO` frame. Only the holder of the private
  key behind a fingerprint can derive that key, so only that device can produce
  the tag. Guarded by `HelloBindingRegressionTests`, which run without a device.

  *Lesson, and it is the same one twice now: a plan recorded in a doc is not a
  verified plan.* This one sat in the file as though it were settled work
  awaiting time, when in fact the API named does not do what the note assumed.
  Check the header before writing down the fix.

- A wrong pairing code and a revoked device both produce `-9816`. Still open in
  the transport, but no longer the only signal: the listener sends an explicit
  `pairFailure` frame carrying a `PairingError` wire code, so the *dialer* is
  told which it was even though the TLS error alone cannot say.

## Wired transport, 2026-08-15 — the cable becomes the only path

AWDL, Bonjour discovery, `TransportProfile` and the Wi-Fi watchdog are gone. The
Mac reaches the phone through `usbmuxd`, which needs no network interface at
all — which is the entire point, because the configuration the product exists
for is a Mac whose Wi-Fi is associated with nothing.

New permanent tests:

| Suite | Guards |
| --- | --- |
| `USBMuxProtocolTests` | The framing and the byte-swapped `PortNumber`. An unswapped 50505 asks for 18885, and the daemon then answers "connection refused" for a port nothing was listening on — an error pointing at entirely the wrong thing. |
| `USBMuxClientTests` | Attach/detach streaming, `Connect` refusal, carried-over coalesced bytes, and above all: **a device usbmuxd reaches over the network is never offered.** Wi-Fi-paired devices differ from cabled ones only by `ConnectionType`, so using one would produce a bridge that appears to work and dies with the Wi-Fi. |
| `HelloBindingRegressionTests` | The impersonation gap above. |
| `DevicePinningRegressionTests` | A pairing is pinned to the UDID it was made over, and the legacy-record migration adopts **once** rather than staying a permanent wildcard. |
| `CellularEgressRegressionTests` | The phone must not egress back up the cable. Plugging in gives the phone a wired interface pointing at the Mac; if the Mac has any route to share, traffic goes Mac → phone → Mac and bypasses nothing while reporting a healthy session. |

Three things worth keeping:

**A blocking `read` outlives the descriptor it was given.** `RawSocket.close()`
called `shutdown` then `close` while a read was blocked on another thread. The
number is immediately free for the kernel to hand to the next socket any thread
opens, so the blocked read resumed against an unrelated connection and the
following `close` shut down someone else's. It took the whole parallel test
process down — no failure, no crash report, just a run that stopped. Serial runs
passed, which is exactly how it hid. The descriptor is now reference-counted:
`close()` only ever `shutdown`s, and whoever leaves the last syscall closes.

**A closed descriptor left in a list is the same bug one level up.** The fake
daemon's `ListDevices` and refused-`Connect` paths closed their descriptor but
left the number in `openFDs`, so `stop()` later `shutdown`s whatever socket has
since been given that number.

**A tautological test proves nothing.** The first version of the egress test
built `NWParameters` itself and asserted on what it had just written. It passed
without touching the shipping code. `CellularDialer.parameters(for:)` is split
out so the assertion is against what actually ships — and doing that immediately
found that prohibiting `.loopback` broke every integration test that points "the
internet" at a local server.

### The review pass on the wired transport — what a fresh reading found

The change above was written, built, and green on 286 tests before anyone read
it end to end. A review pass then found thirteen defects, none of which any test
caught, and several of which were the *same shapes this file already records*.
Worth listing because the repeat offenders are the point.

**Shapes that recurred:**

- **Teardown that does not say which session it is tearing down.** A superseded
  session's task runs its tail *after* the replacement has installed itself,
  sees non-nil state, and wipes it. The new session then carries traffic while
  `status()` reports "disconnected" and `unpair` tombstones a Mac that is
  bridging right now. Fixed with a generation stamp — the same device
  `listenerGeneration` already used one level down, applied to sessions.
- **Cancelling a task that cannot observe cancellation.** `sessionTask?.cancel()`
  was supposed to enforce "only one Mac bridges at a time". The task is parked
  in `channel.receive()`, which suspends on a continuation only a network
  callback resumes, so cancellation is invisible and two Macs proxied at once.
  Closing the channel is the only thing that ends a session — which this file
  already says, one side over. The relay had the identical bug with its pumps.
- **`endSession(channel: nil)`.** Fixed on the Mac earlier in the same change,
  then written afresh on the phone with the explanatory comment sitting directly
  above it. The comment was copied; the argument was not.
- **Wired up to nothing.** `restoreTombstones`/`currentTombstones` had no
  callers, so revocations died with the extension; meanwhile the Mac still asked
  *its* extension for tombstones it no longer owns and wrote a `revokedDevices`
  key nothing read. The restore/snapshot accessors left behind are deleted too,
  rather than left looking usable. This is the `clearUnpairedByPeer` shape exactly.
- **A guard that reads the wrong variable.** `unpair` disconnected when
  `state.isConnected` — true for *any* live session — so removing Mac B tore
  down a healthy bridge with Mac A. Two lines above sat the comment explaining
  that this exact cross-talk had already been fixed once by addressing the
  message.

**New shapes worth naming:**

- **A one-way door.** Disconnect cancelled the redial loop but left `relayPort`
  set, so status answered "connecting" forever and the app's re-announcement —
  which only fires on "disconnected" — could never restart it. The only way back
  to a working bridge was to physically unplug the cable. *If an action has no
  inverse in the UI, that is the bug, not a missing feature.*
- **State published before it was verified.** The HELLO proof was checked inside
  the frame loop, after `activeFingerprint` and `.sessionStarted` had already
  been set from the claimed value — and `.sessionStarted` clears a pending
  "unpaired" notice. A short window, but it made the binding partly ceremonial.
  The proof arrives in a frame already in hand; there was no reason to defer it.
- **`Thread.sleep` inside a `@MainActor` type.** Up to three seconds of frozen
  UI on the attach path, i.e. every replug.
- **`isCancelled` is not `isFinished`.** A prune written as
  `removeAll { $0.isCancelled }` never removes a task that completed normally.
- **Unstructured tasks have no order.** One `Task` per relay state change, each
  awaiting a provider round trip, can deliver `usbrelay:<stale port>` after
  `usbgone`. Serialised through a single consumer.
- **Ordering around a throw.** `restartListener` cancelled the old listener
  before bumping the generation, so a throwing `NWListener(using:)` left a
  corpse that failed every rebuild and took the phone off the air permanently,
  silently.

**The lesson that generalises:** every one of these lives on a path no test
reaches — supersession, teardown, an error branch, an explicit user action with
no inverse. The suite is good at the protocol and useless at the lifecycle.
Reading the diff found in one pass what 286 green tests did not.

### Round two — fixes that were themselves wrong

The thirteen defects above were fixed, and a second reading found that four of
the fixes were incomplete and three had introduced new bugs. Recording it
because the failure mode is specific and repeatable: **a fix aimed at one
caller, applied to one caller.**

- The generation stamp that stopped a dying session clearing its replacement
  was added to `sessionFinished` — and then `peerUnpaired` passed
  `sessionGeneration` (always the current one) straight back into it, and
  `MacSessionClient` never got the stamp at all. Same defect, two sites, one
  fixed.
- Making `unpair:` always reach the extension was right, and it walked straight
  into a `wrong-peer` early return that then swallowed the removal, the
  tombstone and the rebuild — so removing a Mac while a *different* Mac was
  bridging did nothing at all. The fix re-created the exact bug it was fixing,
  through a guard written for the old calling convention.
- `disconnectedByUser` could never be read, because `disconnect` nilled the very
  `relayUDID` the guard compared against. Fixing that made **Reconnect** dead
  instead: with the UDID preserved, a re-announcement for the same cable no
  longer cleared the flag, and nothing else did — so the menu item existed and
  silently did nothing. Two states, and the code could only ever be in the wrong
  one. It needed a verb of its own.
- The phone read `.unpaired` without binding the fingerprint the wire already
  carried, removing `activePeerFingerprint` instead — so a notice about Mac A
  arriving while Mac B was live deleted **B's** pairing and then stopped the
  whole tunnel, taking the listener off the air for every other paired Mac. The
  Mac's side had bound it correctly all along; nobody checked the other end.

**A race is closed by structure, not by a test.** The concurrent-accept
interleaving was fixed by making the install between claiming the session slot
and setting `sessionTask` contain no `await` whatsoever — the superseded channel
is closed in a detached task, and the unpair handler is passed to
`BridgeResponder.init` rather than registered with one. A test was written for
it, and then the suspension was deliberately reintroduced to see it fail: **it
passed anyway.** Real handshakes do not line the timing up. The test is kept as
a consistency check and labelled as exactly that. A test that cannot fail is not
evidence, and leaving it looking like evidence is worse than having none.

**What did work:** deliberately breaking the code to confirm the test notices.
The generation-stamp test fails on all three of its assertions with the guard
disabled; the concurrency test does not. That five-minute check is the only
thing separating the two, and without it both would have been reported as
proven.

### A fake built from the same assumptions cannot catch a wrong assumption

`USBMuxCodec.ResultCode.badVersion` was written as **5**. It is **6**. Every
one of the 23 codec tests passed, because `FakeUSBMuxDaemon` was written from
the same reading of the protocol as the client — so both sides agreed on a
number Apple does not use, and the suite confirmed the agreement rather than the
protocol. The client then rejected the daemon's real answer as "unknown Result
number 6", turning a precise, actionable error into a parse failure.

Found in about a minute by `spike/usb-probe --selftest`, which talks to the real
`/var/run/usbmuxd` — **with no device attached.** `ListDevices` and `Listen`
both answer on an empty Mac, and a wrong header version, message type, or plist
body fails them. The circularity had been sitting there the whole time behind a
green suite.

Two changes came out of it:

- The result code is corrected, and pinned by a test that asserts 5 is *not*
  `badVersion` as well as that 6 is.
- An unrecognised result number is now **carried** (`.unknownResult(Int)`)
  rather than thrown. Throwing discarded the one piece of information the daemon
  was offering, and would do the same for any code a future macOS adds.

**The general rule:** when a test double models a protocol you do not own, the
double and the code under test share an author and therefore share their
mistakes. Something outside that loop has to be consulted at least once. Here
the daemon was available all along and cost nothing to ask.

## The first hardware run, 2026-08-15 — what only a device could show

The wired transport reached a real iPhone 15 Plus for the first time. Three
things were settled and one bug was found that no amount of off-device work
could have reached.

**Settled:**

- **`usbmux Connect` reaches a listener inside a Network Extension.** This was
  the single assumption the whole design hedged against, and it holds:
  `port 50505 (network extension): ANSWERED`, with the app-port fallback
  correctly refused. The preferred path works, so the bridge survives the phone
  being locked.
- **The pairing survived the transport rewrite.** An existing pairing from the
  AWDL era completed a session over the cable with no re-pair, which is a real
  check on the key derivation: both sides still agree on the session key after
  the roles swapped, because the context is the phone's fingerprint on both
  ends either way.
- **The `remotepairingd` hazard does not bite over the cable.** `devicectl`
  installed an app and launched processes with a session live. The capture
  policy logged `on-link=[v6/64,v6/64,v4/24,v4/16,v6/64]`, i.e. rule 6 is
  excluding the on-link destinations that used to be captured.

**The bug: the bridge could not survive an app restart.**

The redial loop's idempotence guard — added in the round-one review fixes to
stop a repeated relay announcement cancelling the dial it was waiting on —
compared the announced port against `relayPort`:

```swift
if let existing = sessionTask, !existing.isCancelled,
   relayPort == port, relayUDID == udid { return }
```

The caller assigns `relayPort = port` from that same announcement one line
earlier, so the comparison is **always true**. The guard therefore returned
whenever any loop existed, and a genuinely new port could never take effect.

Quitting and relaunching the menu-bar app binds a fresh ephemeral relay port.
The extension went on dialling the dead one: `connection refused — nothing is
listening there`, every five seconds, indefinitely, while `lsof` showed a
healthy listener on the new port. The first session came up perfectly; only the
restart exposed it.

**Why nothing caught it.** Every test dials one relay port. Catching this needs
*two successive* ports — the bug lives in the transition, not in either state.
The guard was also reviewed twice by a fresh reader and passed both times,
because it reads correctly: the defect is in the caller's assignment order, one
frame up.

Fixed by tracking what the running loop is actually dialling (`dialingPort` /
`dialingUDID`) rather than the most recent announcement, and pinned by
`RelayHandoverRegressionTests`.

**The general lesson, and it is the one this file keeps re-learning:** state
that answers "what did I last hear?" is not state that answers "what am I doing
now?", and a guard that consults the wrong one is invisible to review because
each half looks right on its own.

## The route tunnel could not be restarted once the Wi-Fi it was dropped under was gone

**Symptom.** "I tested with wifi off initially and it worked, but when I
disconnected from my phone and tried reconnecting, it failed." The sequence was:
bridge over the cable, then stop bridging and turn Wi-Fi back on, then turn
Wi-Fi off, plug the cable in, and switch the bridge on again. The bridge itself
came up in three seconds. Nothing worked anyway.

**What was actually happening.** The bridge was never the problem. The route
tunnel — which gives the Mac a default route and a resolver, without which no
socket can be created for the proxy to claim — refused to start, once a second,
for thirty-one seconds. `startVPNTunnel()` did not throw. NetworkExtension
accepted it, moved to `connecting`, and killed it milliseconds later, thirty
times identically:

```
Entering state NESMVPNSessionStatePreparingNetwork
E  No network available
Entering state NESMVPNSessionStateStopping
status changed to disconnected, last stop reason No network available
```

**NetworkExtension will not START a packet tunnel on a Mac with no network.** It
will happily keep one RUNNING: the same session, once up, stayed connected for
the next twenty minutes with the radio off and no status change at all. That
asymmetry is the whole bug and the whole fix.

It eventually started only because Personal Hotspot happened to give the USB
interface an address at 17:50:40, which changed the ranked interfaces and handed
NE a network to prepare against. With the hotspot off it would have retried
forever.

**Why the existing guard did not save it.** The teardown was already gated on
`hasAlternativeNetwork()`, on the reasoning that dropping the tunnel is safe
while another network exists because it can then be rebuilt. The reasoning is
sound and the conclusion is still wrong: **reversibility is a property of the
moment you restart, not the moment you stop**, and the user turns the network
off in between — deliberately, because that is what the product is for. The
check was evaluated against a network guaranteed to be gone by the time it
mattered. No amount of tuning the condition can fix that; it is the wrong
question.

The misleading diagnostic made it worse. An earlier fix had rewritten the
twenty-attempt message to disclaim NE-refusing-without-a-network, because it had
once fired with Wi-Fi up — so the line was actively arguing against the true
cause at the moment it was true.

**The fix.** The tunnel is never stopped for a dead session. It is started
eagerly, while a network still exists to start it with, and then switches
between two modes:

* `.capture` — default routes for both families plus DNS. What the bridge needs.
* `.standby` — an address and nothing else: no routes, no resolver. The Mac's
  own network is untouched.

A mode change is `setTunnelNetworkSettings` on a live interface and needs no
network at all. Standby is what makes never stopping safe — it is the answer to
the original hazard that motivated the teardown, a capturing tunnel with no
bridge behind it being a total outage that outlives the app.

Measured after the fix, same machine: tunnel adopted already-connected, standby,
then capturing 1.9s after the session started — with no `startTunnel` call at
all, because it never went down.

**A second defect found while fixing it.** `reconcileRouteTunnel` was called
from four of `refreshStatus`'s six branches. The two it missed were `.refused`
and `.unintelligible` — and `.unintelligible` is what an unreachable extension
looks like, so the one state in which the tunnel most needed re-deriving was the
one state that skipped it. Hoisted out of the switch and run unconditionally.
Gating on an enumerated subset of replies has now been wrong in this function,
in the relay announcement, and in the relay itself: the real failure is always
the case the subset left out.

Pinned by `RouteTunnelRestartRegressionTests`, which walks the reported sequence
as transitions and asserts that no combination of inputs can ever tear the
tunnel down.

## Wireless bearer, 2026-08-20 — the peer link's own interface is an egress path

`CellularDialer` has always prohibited `.wiredEthernet`, and the comment above
that line explains why: plugging the phone into the Mac gives the phone a wired
interface, so a Mac with any route to share lets the phone dial out through it.
The bridge then carries traffic from the Mac to the phone and straight back to
the Mac, bypassing nothing while reporting a healthy session, and the egress
report says `.wiredEthernet` only after the fact.

The wireless bearer recreates that hazard exactly, one interface over. With the
phone associated to an access point the Mac hosts, a destination dial satisfied
over Wi-Fi leaves the phone, crosses the access point and arrives back at the
Mac. Same loop, different radio.

`requiredInterfaceType` does not close it. It is documented as a preference
Network.framework may fall back from, which is precisely how a Wi-Fi fallback
was once observed being reported as a successful cellular dial. Prohibition is
the half that cannot be negotiated away.

**The fix is where the rule lives, not what it says.** A literal
`[.wiredEthernet]` in the dialer is correct while there is one bearer and wrong
the moment there are three, because the set is not a property of the dialer — it
is a property of whichever link is carrying the peer connection.
`WirelessBearer.prohibitedEgressInterfaces` owns it, so adding a bearer cannot
leave the prohibition behind. This is the same shape as the identifiers that
were scattered across four targets until one file owned them.

| Test | Guards against |
| --- | --- |
| `EgressLoopRegressionTests` | A proxied dial re-entering the Mac over the access point. Asserts `.wifi` prohibited under `.hostedAP`, cellular still required, and — separately — that the cable's prohibition is unchanged, so adopting the wireless bearer cannot quietly widen or narrow the USB path. |
| `CellularEgressRegressionTests` | Unchanged, now naming `.usbmux` explicitly rather than relying on a default. A cable regression that silently started testing a different bearer would be worse than no test. |

Loopback stays permitted under every bearer, deliberately. A destination on the
phone's own loopback is not a way around the bridge, and banning it breaks every
integration test that points "the internet" at a local server — which is how the
datagram and refused-destination suites run with no network at all.

## Internet Sharing, 2026-08-20 — the write succeeds and nothing happens

Raising the access point failed on hardware with:

```
Could not start the UpLink network
NetworkSharing did not restart (status 150)
```

`launchctl error 150` decodes to **"Operation not permitted while System
Integrity Protection is engaged."** SIP owns Apple's daemons, so nothing outside
Apple may restart `com.apple.NetworkSharing`. The helper runs as root and it
makes no difference: this is not a permissions problem that more privilege
solves.

**The dangerous half is that the write worked.** After the failure the
preference file read exactly right — `NAT.Enabled = 1`, `AirPort.Enabled = 1`,
`NetworkName = UpLink-…`, `SharingDevices = [en0]`, `PrimaryService` pointing at
the product's own dead-end route tunnel. Every field correct, and no access
point: `bridge100` absent, `InternetSharing` not running.

So a direct write to `com.apple.nat.plist` is not "most of the way there". It
goes behind SystemConfiguration's back, configd is never told, and the file
becomes a description of a state the machine is not in. Anything reading that
file to decide whether sharing is on gets a confident wrong answer — which is
the same trap already recorded here as ":NAT:AirPort:Enabled reads 0 with the AP
fully up", seen from the other side.

**The fix is to use the door rather than the window.**
`SCPreferencesApplyChanges` is the notification System Settings itself sends,
and configd's `com.apple.SystemConfiguration.ISPreference` plugin is what
listens for it and starts the daemon. The sequence is
`SCPreferencesCreate` → `SCPreferencesLock` → `SCPreferencesSetValue` →
`SCPreferencesCommitChanges` → `SCPreferencesApplyChanges`. No daemon is
restarted by us at any point, so SIP has no reason to object.

The lock is not optional politeness: these preferences are shared with System
Settings, and committing without it can lose a concurrent edit or fail in a way
that reads as a permissions problem — sending the next person back to SIP, which
is a dead end.

**Rule this encodes.** When SIP refuses an operation, that is the boundary
naming the supported API, not an obstacle to route around. Every "run the tool
by hand" approach here — `launchctl kickstart`, writing the plist, `defaults
write` — fails or lies. The framework call works and is shorter.

### The same run, one layer down — a correct file that says nothing

With the SIP problem understood, the access point still did not come up, and
configd said why:

```
[com.apple.NetworkSharing:preference] store changed
[com.apple.NetworkSharing:preference] no external service id
[com.apple.NetworkSharing:preference] external interface: (null)
[com.apple.NetworkSharing:preference] sharing started on 0 interfaces
```

`store changed` means the plugin *did* see the write. It could not resolve the
source being shared, because the configuration was built from scratch and had
silently dropped `PrimaryInterface` — the sub-dictionary naming that source.
Every field a reader would think to check was present and correct. The fault was
entirely in what was missing, which is why reading the written file proved
nothing and why the earlier "the write worked" conclusion was only half true.

`AccessPointConfiguration.natPreferences(mergedOnto:)` merges now, and never
replaces. Unknown keys are carried through untouched: a system preference is not
ours to rewrite from first principles, and not knowing what every key is for is
precisely what made this defect possible.

| Test | Guards against |
| --- | --- |
| `SharingMergeRegressionTests` | Rebuilding the sharing configuration from scratch. Pins `PrimaryInterface` surviving and being enabled, unknown keys inside `NAT` surviving, and sibling top-level keys surviving — against this Mac's real captured off-state, so the fixture is the thing that actually failed. |

**Rule this encodes.** Two failures in one run both took the shape "the artefact
looks right and the system disagrees". Confirm a system change by asking the
system, never by reading back the file you wrote.

### The same run, one layer further down — a VPN has no device

With SIP understood and the merge fixed, the access point still did not start —
and this time it took the Wi-Fi radio on its way to failing, which is the worst
shape available: from the outside it looks like it is working. The Mac spent the
whole attempt hunting for networks that no longer existed, because its radio was
gone and nothing had replaced it.

```
[com.apple.NetworkSharing:preference] AP stopped
[com.apple.NetworkSharing:preference] external interface: (null)
[com.apple.NetworkSharing:preference] sharing started on 0 interfaces
```

`en0` was `inactive` for 40 of the recorded samples and `InternetSharing` was
`running` for 50 of them, so every outward sign said the mechanism had engaged.

The source being shared is the product's own route tunnel, which is a **VPN
service**, and `preferences.plist` records a VPN's interface as
`Type: VPN, DeviceName: None`. So `PrimaryInterface.Device` cannot be carried
forward from stored configuration or merged from what is on disk: it does not
exist until the tunnel is running. The live value is in the dynamic store, at
`State:/Network/Service/<serviceID>/IPv4` → `InterfaceName` (here `utun5`).

| Test | Guards against |
| --- | --- |
| `SharingSourceDeviceRegressionTests` | An empty or stale `PrimaryInterface.Device`. Pins that the live device is always written, that a stored `""` is replaced rather than merged forward, and that a device from a previous tunnel is replaced too — `utun` numbering is not stable across restarts. |

**Rule this encodes.** Three failures in one run, each one layer beneath the
last, and all three looked correct from the artefact. Preferences describe
configuration; only the dynamic store describes what is *running*. Anything
naming a live interface has to come from the latter.

## The hosted network's name cannot be set, 2026-08-20

The Mac brought its access point up correctly and broadcast the wrong name. The
preference read `UpLink-c743de63`; the radio was on the air as `UpLink-Spike`,
a name left over from an earlier spike and present nowhere in this repository.

`NAT:AirPort:NetworkName` is written, accepted, and ignored. This is the third
field in this one plist to behave that way, after `:NAT:AirPort:Enabled` reading
`0` with the access point fully up and `PrimaryInterface.Device` being empty for
a VPN source. The pattern is now unmistakable: **`com.apple.nat.plist` records
intent, and a good deal of it is vestigial.**

Where the live configuration actually lives is
`com.apple.airport.preferences.plist`, and with SIP enabled that file cannot be
read **even by root** — `sudo plutil -p` returns "you don't have permission to
view it" on a file whose mode is `rw-r--r-- root:wheel`. Searching by the name
on the air found it only inside `/var/db/diagnostics/*.tracev3`, which are log
files, not configuration. So the name can be neither read nor written, at any
privilege level, by us.

**The fix is to stop needing it.** `NEHotspotConfiguration(ssidPrefix:passphrase:isWEP:)`
(iOS 13+) joins any network whose name begins with a prefix. The user names the
network once in System Settings, anything starting with `UpLink` matches, and
the exact name never has to travel between the two devices.

**Rule this encodes.** When a value cannot be read at any privilege level, that
is the platform declining to have the conversation. Design so the value is not
needed, rather than looking for a way to extract it — the extraction is the part
that breaks on the next OS release.

## Wireless bearer, 2026-08-20 — both sides healthy, disagreeing about the port

The Mac hosted its access point, found the phone through its own DHCP lease,
announced `peer:192.168.2.2:50505`, and dialled it. The phone's listener was up
and the tunnel extension was running the current build. For several minutes the
log read, every twelve seconds:

```
ipc: peer at 192.168.2.2:50505
dial failed: handshakeFailed("no connection within 12s")
```

Nothing was broken on either side. They had stopped agreeing about the port.

Over the cable the port arrived inside `requiredLocalEndpoint`, which carried
**two facts in one value**: bind to loopback, and bind to *this* port. Removing
that endpoint for the wireless bearer was correct — loopback is unreachable from
the network the Mac hosts — and silently took the port with it, so
`NWListener(using:)` chose an ephemeral one. The listener then came up perfectly,
on a port nobody was dialling.

The port is passed to `NWListener(using:on:)` explicitly now.

| Test | Guards against |
| --- | --- |
| `ListenerPortRegressionTests` | The two sides drifting apart on the port. Pins that the wireless listener carries no `requiredLocalEndpoint` to silently re-pin it to loopback, that the cable's still names the same constant, and that the constant is what the Mac announces. |

**Rule this encodes.** A value that carries two facts will lose one of them when
it is removed for the sake of the other. `requiredLocalEndpoint` meant "loopback"
and "port 50505" at once; only the first was unwanted. Where a change deletes a
compound value, name each fact it was carrying and decide about each one.

### The same evening — a diagnostic that could not be wrong

The phone's log said, through every wireless attempt:

```
listening on 127.0.0.1:50505 — waiting for the Mac to dial over the cable
```

It was a literal string, written unconditionally after the listener started. It
said `127.0.0.1` while the bearer had been changed to bind every interface, and
it said "over the cable" during an evening in which no cable was attached. It
was read as evidence twice and sent the search in the wrong direction both
times.

It now reports the port actually bound, the bearer, and the **build**.

The build is there because **installing the app does not restart a running
Network Extension.** The phone kept an old binary across several installs, so
fix after fix was shipped to a device that never loaded any of them, and every
symptom pointed at code that was not running. The proof was that the phone's log
had not been written to since before the last three installs — identical size
and mtime — which is a thing nobody thinks to check.

**Rule this encodes.** A diagnostic that cannot be wrong cannot help. If a line
would print the same text whatever happened, it is decoration. Print the value,
and print which build printed it.

### macOS has local network privacy too, 2026-08-20

After the phone was proven correct — `join: OK`, `listening: port=50505
bearer=hostedAP`, reachable at 2.7ms with an ARP entry — the Mac's dial still
timed out at twelve seconds with **nothing arriving at the phone at all**.

The measurement that separated it:

```
tcp 50505: Connection to 192.168.2.2 port 50505 succeeded!   ← nc, from Terminal
dial failed: handshakeFailed("no connection within 12s")     ← the extension
```

Same address, same port, seconds apart. The difference is not the network, it is
**which binary is asking**. macOS 15 brought iOS's local network privacy to the
Mac, and neither `UpLinkMac` nor the proxy extension declared
`NSLocalNetworkUsageDescription`. Terminal had been granted long ago; the
extension had never asked, and a denial here is silent — the connection simply
never completes.

This is the same defect as the iOS one recorded above, on the other device, and
it was not looked for there because the Mac side had been working all evening
over loopback — where local network privacy does not apply.

**Rule this encodes.** When two processes on one machine get different answers
from the same address and port, the variable is the process, not the network.
Look at what the OS grants each of them before looking at anything else.

### The SYN was going to the home router, 2026-08-20

The dial failed with `POSIXErrorCode(rawValue: 60)` — operation timed out —
which reads as "the phone is not answering". The phone was answering: ping 2.7ms,
a valid ARP entry, and `nc` from Terminal reaching the same port. The route
probe showed what was actually happening:

```
route to phone: gateway: 192.168.1.254   interface: en0
```

`192.168.2.2` was falling through to the **default** route, so the Mac sent the
SYN to the home router, which dropped it. ETIMEDOUT is the correct and useless
answer to that.

This is why the earlier readings disagreed: an ordinary process and the
extension were measured at different moments, and the bridge interface comes and
goes with the access point. Whenever it was not fully up, everything targeting
the phone left over the home Wi-Fi instead — including, at times, `nc`.

The dial now binds its source to the Mac's own address on the hosted network,
read from the interfaces at dial time rather than remembered, so the wrong
interface is impossible rather than unlikely. Loopback is exempt: the cable
needs no help.

| Test | Guards against |
| --- | --- |
| `DialBindingRegressionTests` | An unbound dial leaving over the default route. Pins that the cable's loopback endpoint is recognised and left unbound, that a peer on the hosted network is not mistaken for it, and that binding actually reaches `requiredLocalEndpoint`. |

**Rule this encodes.** ETIMEDOUT names a destination that did not answer, never
the path taken to it. When it appears against a host that is provably reachable,
the question is which interface the packets left on.

## The bridge came up, and the thing meant to protect it killed it, 2026-08-20

First working wireless session, and the whole chain:

```
23:36:33.620 join: OK (prefix UpLink)
23:36:33.827 listening: port=50505 bearer=hostedAP build=1
23:36:34.297 accept: inbound from 192.168.2.1:63578
23:36:34.322 accept: TLS ok, first frame = hello
23:36:34.332 session started with 012ff2a529f58e7a
23:36:45.572 session ENDED
```

Eleven seconds. The Mac's side explains it:

```
23:36:14  bridge100: inet 192.168.2.1     ← access point up
23:36:36  bridge100: absent                ← two seconds after the session started
23:36:47  bridge100: inet 192.168.2.1     ← back on its own
23:36:55  helper: raising access point     ← the re-host, making it worse
```

**The access point flaps when the first client associates** — Internet Sharing
reconfigures and `bridge100` briefly disappears. The thirty-second re-host,
added so a Mac in the back of a car could recover an access point that had gone
down, read that blip as "down" and raised again. Raising re-applies the sharing
configuration, which restarts the access point and drops every client, so the
repair destroyed a session that had just completed its TLS handshake.

Two guards now, and each is necessary on its own:

- **Never re-host while a session is live.** A working bridge needs no repair,
  and a re-host during one cannot help by construction.
- **Down must be sustained.** One sample is a blip; two consecutive checks a
  minute apart is an access point that is genuinely gone.

**Rule this encodes.** Automatic recovery has to be surer of the fault than of
its remedy. A repair that is destructive when wrong must wait for evidence that
would be silly to doubt — and must never run while the thing it protects is
working.
