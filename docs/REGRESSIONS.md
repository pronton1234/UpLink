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

## Retired: the capture-policy suite

`CapturePolicy` and its four regression tests were deleted when the Mac side
moved from a `NETransparentProxyProvider` to an in-process SOCKS5 proxy. They
guarded against the extension capturing its own link to the phone (an unbounded
loop), capturing loopback, and capturing mDNS.

Those hazards are structurally gone rather than merely untested: a SOCKS proxy
only ever sees connections a local app deliberately sends it, so it cannot
capture our own traffic, loopback, or multicast discovery. **If a system-wide
capture mechanism is ever reintroduced, restore that suite first** — the
self-capture loop is the worst failure this codebase can produce.

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
