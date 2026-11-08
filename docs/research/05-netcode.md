# 05: Netcode architecture and transports

Research date: 2026-11-07. Claims marked **[unverified]** come from memory or one secondary source. **[estimate]**
means my own arithmetic. The phase 2 core (`../PHASE2.md`) implemented and validated the relay, prediction, rollback, adaptive delay, time sync and late join; where it disagrees with this doc, the code and `spec/CORE.md` win. Quantum facts come from the SDK in OctoEscape
(Quantum 3.1.0 Preview, build 2249): its offline doc mirror (`Assets/Photon/Quantum/Documentation~`, snapshot of
doc.photonengine.com from 2026-10-09), `Quantum.Engine.xml`, and **defaults read by instantiating
`DeterministicSessionConfig` from `Quantum.Engine.dll` via reflection**. Those are the real defaults, not the values
in a doc table.

## TL;DR and recommendation

**Build a Quantum-style star: one relay owns the clock and stamps the official input set for every tick. Every
client, the host's own included, predicts and rolls back against that stream. Do not use GGPO/GGRS-style P2P mesh.**

1. **The relay is game-agnostic and tiny.** It runs no simulation. It keeps the tick clock, collects inputs, and
   finalizes tick T when every input for T has arrived or a hard tolerance has expired. Missing inputs get the
   player's last repeatable input or a neutral one, flagged `ReplacedByRelay`. It broadcasts the set and keeps the
   full input log. That log is the replay, the late-join tail and the desync oracle. The relay runs in the host
   process on its own thread. The same code runs headless on a VPS as the "self-hosted relay".
2. **Defaults for 2–4-player physics co-op at 60 Hz** [estimate, tune with the phase 2 harness]: adaptive input delay **min 1
   tick**, max 6, growing above about 80 ms RTT (Quantum's formula, with a lower start ping). Prediction capped at
   **10 ticks**: past that, the client slows its clock instead of predicting further. A state ring of 16 frames.
   Hard tolerance about 6–7 ticks. Checksum every verified tick in dev builds and every 16 in release.
   Quantum's own defaults (input delay 0 under 100 ms RTT, rollback window 64) suit cheap sims. Re-simulating 1000
   rigid bodies is the expensive part, so we buy rollback depth back with a tick of delay.
3. **Inputs are bit-packed, quantized at the source, absolute (not deltas of motion), and delta-encoded on the
   wire.** Every unreliable packet carries all unacknowledged ticks. That costs about 5 KB/s up and 10 KB/s down per
   client for 4 players [estimate]. Bandwidth is a non-issue. Rollback CPU is the issue.
4. **Transports sit behind one small message trait** (unreliable + reliable lanes, poll-based). The order:
   in-process loopback with a deterministic network simulator first, then raw UDP (done in phase 2), then Steam
   `ISteamNetworkingSockets` over SDR (needs C bindings from Odin). EOS comes later: it is free, but immature.
5. **Late join**: the host's client sends the latest verified state block (zstd, optionally XORed against the
   level's initial state). The relay sends the input tail and the joiner fast-forwards.

Biggest unknowns: rollback cost of full rigid-body physics with 1000 entities, the physics state's snapshot size,
and the real behaviour of Steam networking from Odin.

## 1. Quantum's model, with its defaults

**Topology.** Quantum's server is a "game-agnostic authoritative server component … to synchronize clocks and manage
input latency. Clients never need to wait for a slower client"
([intro](https://doc.photonengine.com/quantum/v3/quantum-intro)). The server runs no game logic unless you write a
custom plugin. The server batches input for "full tick-sets (all player's input)" and sends them down
([input](https://doc.photonengine.com/quantum/v3/manual/input)).

**Official inputs per tick.** The server waits `InputHardTolerance` frames. Then it "expires a frame and replaces all
non-received inputs with repeated inputs or nulls and sends it out to all players" (`Quantum.Engine.xml`). Each input
carries `DeterministicInputFlags`: `Repeatable` (copy it into the next tick, both for server replacement and for
client prediction), `PlayerNotPresent`, `ReplacedByServer` and `Command`. Flags "can only be trusted on verified
frames" ([input flags](https://doc.photonengine.com/quantum/v3/manual/player/input-flags)). `InputRepeatMaxDistance`
is how far the server scans for a repeatable input. The plugin API exposes the same pipeline:
`OnDeterministicInputReceived`, `…InputConfirmed`, `…ServerReplacedInput`, and `OnDeltaCompressedInput`, which
streams a replay ([server API](https://doc.photonengine.com/quantum/v3/addons/plugin-sdk/quantum-server-api)).
Whether the server finalizes a tick early once every input has arrived is not documented **[unverified]**. I assume
it does.

**Defaults** (`new DeterministicSessionConfig()` via reflection; the unit meanings come from XML docs):

| Field | Default | Meaning |
|---|---|---|
| `UpdateFPS` | 64 | Tick rate (OctoEscape sets 60) |
| `LockstepSimulation` | false | Lockstep mode, no rollback; the docs say to use `InputDelayMin` ≥ 10 with it |
| `RollbackWindow` | 64 | Frames kept in the ring, i.e. how far a client may predict |
| `ChecksumInterval` | 64 | Frames between checksums sent to the server; "set to zero for release" |
| `ChecksumCrossPlatformDeterminism` | false | Cross-platform checksums are "quite a cost", debugging only |
| `InputDeltaCompression` | true | Server delta-compresses tick-sets against the previous one |
| `InputDelayMin` / `Max` | 0 / 64 | Input offset in ticks. The asset clamps Max to `UpdateFPS`. The doc table says "ms", the XML and the editor say ticks |
| `InputDelayPingStart` | 100 ms | RTT at which input delay starts |
| `InputHardTolerance` | 8 | Recomputed by the asset as `ceil((pingStart/2 + 30 ms)/tick) + 2 − delayMin`, so 7 at 60 Hz and 8 at 64 Hz |
| `InputRedundancy` | 3 | Stagger between redundant input resends, in frames |
| `InputRepeatMaxDistance` | 10 | Scan distance for repeatable inputs |
| `TimeCorrectionRate` | 4 | Time-correction packets per second from the server |
| `MinTimeCorrectionFrames` | 1 | Clock error that triggers a local clock adjustment |
| `MinOffsetCorrectionDiff` | 1 | Delay change needed before the local input offset moves |
| `TimeScaleMin` / `PingMin` / `PingMax` | 100 % / 100 / 300 ms | Server time dilation for high ping. **Off by default** (min = 100 %) |
| `SessionStartTimeout` | 1 s | Wait for other players before starting |
| `InputFixedSize` | 0 | Set at start from the serialized size of the input struct |

`DeterministicSession.CalculateInputOffset` (called by reflection, 60 Hz, defaults) gives 0 ticks up to 100 ms RTT,
then 1 tick at 120 ms, 3 at 200 ms, 6 at 300 ms and 9 at 400 ms. In other words, input delay soaks up about half of
the RTT above `PingStart`, and prediction covers everything else. With defaults, a 4-player game at 80 ms RTT
predicts remote players about 5–6 ticks deep every frame.

**Time sync.** The server is the clock. It sends corrections 4 times a second, and a client re-aligns when it is off
by at least one frame. The view gets `Predicted`, `PredictedPrevious` (used for clock-aliasing interpolation) and
`PreviousUpdatePredicted` (used for error-correction smoothing)
([frames](https://doc.photonengine.com/quantum/v3/manual/frames)). A frame is *verified* only once every player's
input for it, and for all earlier ticks, is confirmed. Partial confirmation doesn't count.

**Commands vs input.** Input is polled every tick, fixed size and predicted. Commands are "fully reliable … the
server will *always* accept them". Remote clients see a command on the tick the server received it, so they can't
predict it ([commands](https://doc.photonengine.com/quantum/v3/manual/commands)). Since 3.1 there can be several
commands per tick.

**Checksums and desyncs.** Clients send checksums of verified frames every `ChecksumInterval`. On a mismatch the
server sends `TickChecksumError`. Clients then send frame dumps (`TickChecksumErrorFrameDump`) so the states can be
compared ([API](https://doc-api.photonengine.com/en/quantum/current/class_photon_1_1_deterministic_1_1_protocol_1_1_tick_checksum_error.html)).
The built-in mechanism "stops the simulation for **every** client"
([cheat protection](https://doc.photonengine.com/quantum/v3/manual/cheat-protection)). `SimulationConfig` keeps the
last 3 verified checksummed snapshots so that a dump can be built
([config](https://doc.photonengine.com/quantum/v3/manual/config-files)).

**Late join and reconnect.** A snapshot is "a platform independent blob … after a verified tick". It comes either
from the client itself (a local snapshot, accepted only up to 10 s old, or up to `EmptyRoomTTL` capped at 2 min),
from a **buddy** client the server picks by load balancing, or from a custom server plugin. Buddy snapshots apply to
clients that connect at least 5 s after the start. The timeouts are 15 s waiting, 10 s upload and 20 s download.
The server keeps "~10 minutes" of input history
([reconnecting](https://doc.photonengine.com/quantum/v3/manual/game-session/reconnecting)). Snapshots are uploaded in
chunks (`FrameSnapshot.MaxChunkSize`, `Last`), and the payload is "bit-packed and compressed" (`Quantum.Engine.xml`;
the algorithm isn't named, **[unverified]** probably GZip like `BinaryData`). The known failure: in a 2-player game,
if the only possible buddy drops, the joiner hangs. That doesn't happen to us, because our host is both the relay
and a client.

**A stalling client.** Its inputs are replaced after the hard tolerance and the others continue. Its own clock gets
corrected forward. After 10 s of silence Photon marks it inactive (`PlayerTTL`), and it needs a snapshot to rejoin.

**Lag compensation and prediction culling.** Quantum has no server-side lag compensation, because there's no
authority to rewind. *Prediction culling* is a CPU feature: entities outside a sphere run only in verified frames,
and `Filter()` skips them in predicted frames
([prediction culling](https://doc.photonengine.com/quantum/v3/manual/prediction-culling)). This matters for our
1000-entity sections.

## 2. Other models compared

| Model | Who decides inputs | Laggy player | Examples |
|---|---|---|---|
| **Lockstep, P2P or host** | Everyone waits for everyone | Stalls all | Age of Empires (scheduled turns of about 200 ms over UDP; [Terrano and Bettner, "1500 Archers"](https://www.gamedeveloper.com/programming/1500-archers-on-a-28-8-network-programming-in-age-of-empires-and-beyond)), StarCraft (turns plus a "latency" setting for turns in flight; [Liquipedia](https://liquipedia.net/starcraft/Ladder/Alternate_IDs/Battle.net/Latency)), Factorio (lockstep plus a local "latency state" to hide delay; state "too big to transfer"; [FFF #83](https://factorio.com/blog/post/fff-83), [#76](https://factorio.com/blog/post/fff-76)) |
| **GGPO / GGRS rollback, P2P mesh** | Nobody: each peer sends its own inputs to every peer | Everyone stalls once the prediction window runs out, then the peer is dropped on timeout | Fighting games; MK/Injustice re-simulate up to 8 frames in 16 ms ([GDC 2018](https://gdcvault.com/play/1025021/8-Frames-in-16ms-Rollback)); For Honor (deterministic P2P sim with "time travel"; [GDC 2017](https://gdcvault.com/play/1024035/Deterministic-vs-Replicated-AI-Building), [GDC 2019](https://gdcvault.com/play/1026077/Back-to-the-Future-Working)) |
| **Relay-stamped rollback (star)** | The relay | Replaced input, nobody stalls | Quantum |
| **Server-authoritative with client prediction** | The server sim; it repeats the last input when its buffer starves | Mispredictions only for that player | Overwatch (deterministic ECS prediction; [GDC 2017](https://gdcvault.com/play/1024001/-Overwatch-Gameplay-Architecture-and)), Rocket League (120 Hz physics; [GDC 2018](https://www.gdcvault.com/play/1024972/)) |

**GGRS** (0.13.0, June 2026, active) has three session types: P2P, Spectator (the host forwards confirmed inputs)
and **SyncTest**, which rolls back `check_distance` frames every frame and compares checksums. That last one is our
planned sync-test mode. Defaults from `builder.rs`: 2 players, input delay 0, max prediction 8, 60 fps, desync
detection **off**, disconnect timeout 2000 ms (notify at 500 ms), check distance 2, max frames behind 10
([source](https://github.com/gschup/ggrs/blob/main/src/sessions/builder.rs),
[changelog](https://github.com/gschup/ggrs/blob/main/CHANGELOG.md)). It does no NAT traversal (demos use
[matchbox](https://github.com/johanhelsing/matchbox) WebRTC, 0.15.0). Time sync is GGPO's *frame advantage*: the
peer that is ahead stalls for a frame so that the two advantages agree within about one frame
([GGPO](https://en.wikipedia.org/wiki/GGPO)).

Limits for 2–4 players: a mesh has n(n−1)/2 links, each with its own NAT punch, and the worst link sets everyone's
rollback depth. A peer that stops sending freezes everyone after 8 frames, about 133 ms, and the only remedy is
disconnecting it. Desync detection is pairwise, and there is no single input log to replay. **A star relay fixes all
of these.** One link per client. One timeline. A lagging player degrades only himself. The input log is canonical.
Over Steam, the host's connections can all go through SDR, so no IPs are exposed. The cost is one extra hop for
non-host clients, about RTT/2 more than a direct mesh link, and a host advantage (the host's client has about 0 RTT
to the relay). For co-op that advantage is harmless.

Other open-source references: GekkoNet (C/C++ GGPO-style, BSD-2), Backdash (C#), NetplayJS (TypeScript; lockstep
is recommended for physics you can't rewind), backroll-rs and GGRS (Rust), lightyear (Bevy, server-authoritative). None of them implements a Quantum-style relay.
We write that layer. It is small. **Borrow from GGRS**: the SyncTest design, its input-queue edge cases (its
changelog is a list of real bugs: input-delay gaps, packets encoded against old frames, catch-up overruns) and its
spectator catch-up.

## 3. Proposed design for unified

```
 host process                                        remote client process
┌──────────────────────────────────────────┐        ┌────────────────────────────┐
│ Relay thread (own 60 Hz timer, no sim)    │◄──────►│ Client                     │
│  clock · per-player input queues          │ UDP/   │  sim ring (verified +      │
│  finalize tick T: all in OR T+tol expired │ SDR/   │  predicted) · rollback     │
│  official tick-set log (= replay)         │ QUIC   │  clock slew · input sender │
│  checksum compare · join/leave commands   │        └────────────────────────────┘
│        ▲ in-process loopback              │
│        ▼                                  │   headless variant: same Relay on a VPS
│ Client (host's own, identical code path)  │   (= "self-hosted relay"); clients
│ + snapshot provider for late joiners      │   connect outbound, so no NAT traversal
└──────────────────────────────────────────┘
```

**Tick and time sync.** The relay ticks at 60 Hz from a monotonic clock on its own thread, so a render hitch on the
host can't delay stamping. Each confirmation packet tells the client its **arrival slack**: how many ticks early or
late its input for T arrived compared with finalization. That's the direct feedback signal, better than RTT/2
guesses. The client aims for a slack of +1 to +2 ticks. It **slews** its sim clock by ±1–5 % rather than jumping;
Quantum jumps on a 1-frame error. It jumps only past 4 ticks of error. Overwatch reportedly does the same: the client
ticks faster to rebuild a starved server buffer **[unverified]**. Input delay is adaptive: `delay = clamp(min +
round(max(0, rtt − pingStart)/2 / tick), min, max)` with min 1, pingStart 80 ms and max 6. It changes by one tick at
a time, with hysteresis. When predicted − verified would exceed **10 ticks**, the client stretches its frame time
instead of predicting deeper, so CPU stays bounded (Quantum's 64 is too deep for physics).

**Input packing.** Gameplay declares an input struct. Codegen or a derive produces a bit writer:
`button` = 1 bit, sticks as an 8-bit angle plus 4-bit magnitude, camera yaw as 16 bits absolute, pitch 12 bits.
OctoEscape already uses absolute yaw/pitch, and absolute values make "repeat last input" correct. Floats are
quantized **before** they enter the sim (Quantum makes the same point), so every peer sees identical integers. On
the wire, each tick is coded as "unchanged" (1 bit) or as an XOR delta against the previous tick of the same player.

- **Client → relay** (unreliable): the base tick, then every unacked tick (at most 16), delta-chained.
- **Relay → client** (unreliable): `ack_tick`, the slack, and every finalized tick-set newer than the client's ack
  (at most 16). Each tick-set has per-player flags (`Replaced`, `NotPresent`) and is delta-coded against the
  previous one.
- **Reliable lane**: commands (attached to the tick the relay receives them, as in Quantum), join/leave,
  configuration, snapshots.

**Laggy and disconnected players.** All decided by the relay, so all peers agree:

- *Tick past tolerance* (default 6–7 ticks after the tick falls due, by Quantum's formula): repeat the last
  `Repeatable` input, otherwise neutral, and set `Replaced`. Late input for a finalized tick is dropped. The client
  sees `Replaced` and its slack controller moves it earlier.
- *2 s without packets*: the player is marked `Stalled`, and gameplay may freeze its avatar (it reads the flag on
  verified frames only).
- *10 s*: the relay stamps a `PlayerLeft` system command at a definite tick. The slot stays reserved for a
  reconnect TTL of about 60 s.
- *Host leaves*: the session ends. Host migration is possible later, because every client has the verified state
  and the log.

**Host as relay plus client.** The host's client is a normal client on loopback. It has 0 RTT, so it gets only the
minimum input delay. For fairness you can optionally set a symmetric minimum. It also serves snapshots.

**Late join and snapshots.** The joiner connects, and the relay asks the host's client for the state block of its
latest verified tick V. The block is chunked over the bulk lane. The relay also streams the input log from V+1, then
stamps `PlayerJoined` at tick J, and the joiner catches up at up to N ticks per frame. Size **[estimate]**: 1000
entities × about 300 B (transform, velocities, physics body, gameplay) is about 300 KB, plus physics internals
(broadphase, contact manifolds with warm-start data, islands) at 1–3× that. The raw block is 0.5–1.5 MB. zstd-3 on
sparse game state should give 3–6× **[unverified]**, so 100–400 KB. XOR against the level's freshly built initial
state before compressing makes static data almost free. GameNetworkingSockets' default send rate is **256 KB/s**,
and a reliable message is at most **512 KB**
([steamnetworkingtypes.h](https://github.com/ValveSoftware/GameNetworkingSockets/blob/master/include/steam/steamnetworkingtypes.h)).
So chunk the snapshot, and raise `SendRateMin/Max` during the transfer. Expect 0.5–2 s, plus catch-up time.
Reconnect is the same path. A local snapshot is an optimization for later.

**Desync detection and diagnostics.**

- *Canonical hash.* xxh3-64 of the state block: zeroed free slots and padding, little-endian. Every target is
  little-endian. That makes the checksum cross-platform for free, which is our requirement and an expensive option
  in Quantum. Hashing 1 MB costs well under 0.1 ms **[estimate]**.
- *Reporting.* Clients send `(tick, hash32)` for verified ticks: every tick in dev, every 16 in release. The relay
  compares them. On a mismatch it flags the session (dev: freeze plus overlay; release: log and continue, or end
  the session). It asks every client for its kept verified block at that tick; clients keep the last 8 checksummed
  blocks.
- *Diff.* The tool is schema-aware: it diffs the blocks by archetype, entity and field. It also replays the
  relay's log offline on both machines with **per-system hashes** to find the first tick and the first system that
  diverged.
- *Shared machinery.* The sync-test mode (rolls back and re-simulates N frames every frame) and cross-platform CI use
  the same code.

**Network simulator.** A `Transport` decorator with a seeded RNG and a **virtual clock**. It simulates base latency
plus jitter (normal or Pareto tail), Bernoulli and Gilbert-Elliott burst loss, duplication, reordering, a bandwidth
cap and scripted events (a 500 ms spike, a 5 s blackout, a latency step). Headless N-client tests then run faster than
real time and stay reproducible. It also feeds the in-game network panel. GameNetworkingSockets has the same knobs
built in (`FakePacketLag/Loss/Jitter/Reorder/Dup`), which helps over real sockets.

**Bandwidth for 4 players at 60 Hz** [estimate]. An input is about 52 bits raw, or 7 B. With a changing camera,
about 4 B delta-coded per tick. Per-packet overhead is IP+UDP 28 B plus about 20–30 B for encryption and transport
headers **[unverified]**.

| Link | Payload / packet | Packet incl. overhead | Rate |
|---|---|---|---|
| Client → relay (≈6 unacked ticks at 100 ms RTT) | ~33 B | ~85 B | ~5 KB/s (~41 kbit/s) |
| Relay → each client (4-player sets, ≈6 unacked) | ~110 B | ~160 B | ~10 KB/s (~77 kbit/s) |
| Host upload, 3 remote clients | | | ~29 KB/s (~230 kbit/s) |
| Worst case: no delta, 16 ticks redundancy | ~450 B | ~500 B | ~30 KB/s per client |

Any home connection handles this. Batching two ticks per packet would halve the overhead, at the cost of up to
16 ms of latency. Not worth it.

## 4. Transports and the abstraction

| Transport | Notes |
|---|---|
| **Loopback** | In-process channel hub plus the network simulator. The workhorse for tests, agents and CI |
| **Direct UDP / LAN** | Own thin protocol (sequence, ack bits, one reliable stream), as built in phase 2 |
| **Self-hosted relay** | **The headless Relay itself on a VPS**, reached over UDP/QUIC. Clients connect outbound, so no NAT traversal and no packet forwarder are needed. TURN or WebRTC ([matchbox](https://github.com/johanhelsing/matchbox)) would only matter for a P2P mesh, which we don't use |
| **Steam** | `ISteamNetworkingSockets`: `CreateListenSocketP2P` / `ConnectP2P` go over SDR automatically. Traffic is "authenticated, encrypted, and rate-limited" and IPs are hidden ([SDR](https://partner.steamgames.com/doc/features/multiplayer/steamdatagramrelay), [networking](https://partner.steamgames.com/doc/features/multiplayer/networking)). Lobbies handle discovery and invites; the lobby owner is the host. Choose Sockets over `ISteamNetworkingMessages` (UDP-like, implicit sessions, built on the same code; [docs](https://partner.steamgames.com/doc/api/ISteamNetworkingMessages)), because we want explicit connection state for the host. Odin: bind the Steamworks C API (flat API header) ourselves |
| **GameNetworkingSockets (open source)** | BSD-3. Same API, encryption, lanes and fake-lag. P2P through WebRTC ICE with your own signaling. **No SDR** ("only available on Steam"; [repo](https://github.com/ValveSoftware/GameNetworkingSockets)). It *can* serve the dev and self-hosted relay over direct IP. The C++ build (OpenSSL or libsodium, protobuf) is real work on three OSes and linking it next to `steam_api` might clash on symbols **[unverified]**. Raw UDP is enough for non-Steam |
| **EOS P2P** | Free, cross-store, NAT punch with automatic relay fallback (`EOS_RC_AllowRelays/ForceRelays/NoRelays`). **Max packet 1170 B** (`EOS_P2P_MAX_PACKET_SIZE`). Reliability modes: unreliable-unordered, reliable-unordered, reliable-ordered. Needs EOS Connect login (ProductUserId). Relay cost and quotas not verified **[unverified]**. Later |

**The trait** is message-based, non-blocking and polled from the net thread. Reliability for inputs lives above it,
through redundancy, so transports only need unreliable datagrams plus one reliable ordered stream.

Shape (the real one is in `spec/CORE.md`): `PeerId`; lanes (Input, Control, Bulk); delivery (Unreliable, or Reliable =
ordered within its lane); events (Connected, Disconnected, Message); and `poll(now)`, `send(to, lane, delivery, data)`,
`flush()` (one datagram per peer per tick), `disconnect`, `stats(peer)` (rtt, jitter, loss, queued bytes) and
`max_datagram()` (keep inputs ≤ ~1100 B: EOS 1170, SDR MTU). Backends are Loopback hub, UDP, later Steam; a `NetSim`
decorator wraps any of them with a profile, seed and clock.

`now` is passed in, so the simulator and the tests control time. A backend's own threads (Steam callbacks) stay behind `poll`.

## 5. Risks and unknowns

1. **Rollback CPU with full physics** (the biggest). At 10 ticks of prediction we re-simulate up to 10 × (1000
   bodies plus gameplay) in one frame. MK needed dedicated engine work to fit 8 frames in 16 ms. Mitigations: a
   tick of input delay, the prediction cap with clock stretch, Quantum-style prediction culling, and sleeping bodies.
   Depends on the physics research.
2. **Snapshot size and memcpy per tick.** If the physics engine's internal state doesn't fit the pointer-free
   block, rollback and late join get expensive or impossible. Measure.
3. **Cross-arch determinism.** Covered elsewhere, but the netcode's only defence is detection plus diffs.
4. **Steam networking from Odin.** Threading, callback pumping and SDR latency are untested here. SDR sometimes adds latency, and sometimes improves the route.
5. **Quantum internals we inferred**: whether ticks finalize early, the exact clock and offset relationship, the
   snapshot codec. They don't block us, because we're designing our own.
6. **Host advantage and host loss.** Fine for co-op. Migration is deferred.
7. **Timer precision** for the relay thread on macOS (App Nap, coalescing) and Windows (`timeBeginPeriod`).

## 6. Validation

Phase 2 covered consistency, no-stall, time sync, late join, UDP and cross-platform snapshots (`../PHASE2.md`). Still open:
Steam transport on a real link, bandwidth and desync-report checks. Network profiles used:

*good* is 30 ± 5 ms with 0 % loss. *Typical* is 80 ± 15 ms with 1 % loss. *Bad* is 150 ± 40 ms with
5 % bursty loss, 1 % duplication and 1 % reordering.

Pass/fail criteria not yet covered: see git history of this file for the original list.
