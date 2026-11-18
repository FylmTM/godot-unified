# `unified:netcode`: input relay, prediction, rollback

Status: signed off 2026-11-18 (#333)

Nobody sends game state: every client runs the whole deterministic sim, and the relay only orders inputs. The
relay's input log is the session (seed + content + log replays to the same checksums anywhere).

Generic over the game: `Relay(G)`, `Client(G)`, `Host(G)` (`G` the game type, a `sim.Game`). Nothing runs a thread or
loop of its own: the host application calls `*_step(now_us) -> wake_us` from its own loop (or one thread on a
`Virtual_Clock` in tests, which makes whole sessions deterministic and fast) and sleeps with `sleep_until(wake_us)`
(to the microsecond: a high-resolution waitable timer on Windows, whose `Sleep` takes whole milliseconds). The wake
time is the next deadline (a tick of the relay or the client, a held broadcast) or the poll interval (`POLL_US`),
whichever is sooner. A host with no remote links (single player) doesn't poll: its relay and client hand each other
what they send within the same `host_step`, so it wakes at its deadlines only. Remote links are polled every
`POLL_US` (EOS links can't wait on a socket). The session thread allocates nothing in steady state: queued messages,
delayed datagrams and early reliable messages take reused slots (`Slot_Pool`), the loopback hub's inboxes are byte
queues swapped whole, a client's kept desync images reuse their buffers. `now_us()` is the monotonic time base.

A game touches the netcode through a `Lobby` (online play: `eos.lobby`), `Hooks` (through `unified:godot`'s
driver, or directly in its tests) and `headless.session_run`; it implements no transport. The library logs through
`context.logger` (`core:log`): silent unless the host sets a logger.

## Pieces

- **Link** (the transport interface, stable and small): `send(to, bytes)`, `recv(buf) -> (n, from, ok)`, `close`,
  optional `event() -> (peer, Connected|Disconnected, ok)`, optional `forget(peer)` (UDP reuses the number; EOS
  closes the P2P connection; wrappers pass it on), optional `account(peer) -> (Account{platform, id}, ok)` (the
  account the transport vouches for behind a peer: EOS gives the remote's product user id; LAN and direct UDP none).
  Datagrams ≤ `MAX_DATAGRAM` (fits an EOS P2P packet), may be lost. A link numbers its remote endpoints as `Peer`s (a
  client-side link: peer 0). Implementations: in-process loopback (`hub_create`, `loopback_link`), UDP
  (`udp_listen(port, .Local | .Lan)`: 127.0.0.1, or every interface for players on other machines; `udp_connect`),
  the network simulator (below), EOS P2P (in `unified:eos`).
- **Lobby** (online play): `open_host(Lobby_Build) -> (Link, ok)`, `open_join(Lobby_Build, code) -> (Link, ok)`,
  `pump() -> Lobby_Status{stage, detail, code, local, host, network, peers}`, `close`, and the optional `main_frame`,
  `shutdown` (main thread) and `account`. `Lobby_Build{game, compat, version, players}`: lobbies are found per game,
  and a joiner on another build is told so before joining. Implemented once per platform (`eos.lobby`); the Godot
  host takes it in `godot.init`, a game's headless binary in `modes.run`'s `lobbies`.
- **Network simulator**: `netsim_wrap(link, profile, seed, clock)` impairs both directions (latency, jitter, loss,
  duplicates, reordering), seeded, on the real or a virtual clock; an ideal profile returns the link as is.
  `netsim_live(link, seed, clock) -> (Link, ^Net_Sim)` starts ideal and `netsim_set(net_sim, up, down)` changes each
  direction while it runs (the dev UI's Conditions panel): an ideal direction with nothing queued passes datagrams
  straight through. Closing it sends the datagrams still delayed, as if already on the wire. The built-in profiles:
  `PROFILES[Network]` (`.Ideal`, `.Wan` the common case, `.Bad` a stress case), `profile_by_name`.
- **Channel**: reliability over any number of links (`channel_add_link`): every (link, peer) pair is one channel
  peer (below).
- **Relay** (`relay_create(&GAME, cfg)`, `relay_add_link`, `relay_step`, `relay_stop`, `relay_finished`,
  `relay_tick`, `relay_end_recording`): owns the clock; finalizes ticks, broadcasts them, routes and checks late-join
  snapshots, judges checksums. Keeps the last `RELAY_RING` finalized ticks; the whole session only in its optional
  recording. Serves all links at once. `ticks = 0` is an endless session. `compat` and the tick rate come from the
  game (and the content).
- **Client** (`client_create(&GAME, cfg, link, hooks)`, `client_step`, `client_stop`, `client_finished`,
  `client_state`, `client_inputs`, `client_stats`, `client_member`, `client_destroy`, `client_result`): the
  verified and predicted frames, rollback, the clock and input delay, snapshots for joiners.
- **Host** (`host_create(&GAME, cfg, hooks)`, `host_add_link`, `host_step`, `host_stop`, `host_finished`,
  `host_destroy`): the relay plus the host's own client (slot 0) joined by loopback; `Host_Config.account` is the
  host player's own platform account (the Godot host asks its lobby). Single player is a host with no remote links.
  The relay serves remote links from when the host's own player is in (a remote Hello already waiting joins as a
  remote player, never in slot 0), and starts its clock without the start lead.

## The wire

`PROTOCOL_VERSION` versions everything below; bump it on any change (the sim-change skill).

- **Datagram**: a tag byte (`0x80 | PROTOCOL_VERSION`), the sender's epoch and the peer's last seen, seq, ack and a
  32-bit ack history, the datagram that arrived last (back from the ack) with how long it waited there, a chunk
  count, chunks (`u8 kind, [u32 id], u16 len, bytes`). Two builds never parse each other's datagrams: a datagram whose
  tag has the top bit and another version is answered with a 5-byte *notice* (our tag, a zero epoch), which no
  version ever answers; a client that gets one from its relay fails at once ("a different game build").
- **Round trip**: one measure, the channel's. Each datagram's ack names the datagram that arrived last and how long
  it waited before the ack went out, so the sender's sample is the path alone. The last arrival, not the newest seq:
  under jitter the newest is the one that came fast. The channel uses it for its resend timeout; the client averages
  it (with its mean deviation) for its clock and input delay.
- **Messages** (`proto.odin`, `Msg`): Hello, Welcome, Reject, Inputs, Finalized, Checksum, Snap_Request,
  Snap_Begin, Snap_Chunk, Done, End, Leave, Roster, Snap_Ok, Desync. The relay knows a sender's slot from its
  connection: no message carries its own slot.

## Channel

Every datagram acks; a reliable message rides until a datagram carrying it is acked, is resent after
`1.5 × srtt + 15 ms` (clamped), and is delivered once, in order; unreliable ones as they come. At most
`REL_IN_FLIGHT` datagrams carrying reliable messages are in flight past the peer's newest ack, so one ack covers a
whole burst (a snapshot is never resent though it arrived); at most `REL_WINDOW` reliable messages past the oldest
unacked one, and a receiver drops anything further ahead; messages over `MAX_MESSAGE` are refused (`channel_send`
false). A keepalive keeps idle peers connected; a peer is dropped after `DISCONNECT_US` of silence, or
`FIRST_ANSWER_US` for one that never answered (a transport like EOS sets up its path after the first hello). Each
side's connection has an epoch, sent (and the peer's echoed) in every datagram: a restarted peer on the same address
replaces its old connection at once, and a side still talking to a connection the other ended is told so at once
instead of sitting half-open. A datagram that doesn't validate never gets a connection (or a transport peer number).

## Relay

- **Hello** carries the slot (or any), a join tick, a `compat` id (`sim.compat_of(game, content)`: layouts,
  command and event types, player count, tick rate, game name and version, the library and Box3D pin, content), the
  client's token (Members) and a name. Rejects: `Full`, `Slot_Taken`, `Incompatible`, `Not_Started`, `No_Snapshot`
  (a joiner nobody can send a snapshot), `Bad_Snapshot`, `Too_Far_Behind` (below). A Hello while the session ends gets
  End. **Welcome** carries the slot, the joiner's member id, the seed, the tick rate, the length, the first tick it is
  present and flags.
- **Seats**: one `Seat` per slot holds its connection, inputs, commands and late join. A seat is emptied with one
  assignment when its occupant leaves and before a new one sits down: nothing of a previous occupant carries over.
- **Start**: the clock starts once the start players have connected: they get Welcome and tick 0 is due
  `START_LEAD_MS` later, so a far start player's inputs for tick 1 arrive in time; during the lead the relay already
  broadcasts, with a negative relay time. A host's relay skips the lead (`local_start`): its only start player is
  in-process.
- **Finalizing**: tick T is final once every present player's input for T is in, or the clock reaches T +
  tolerance (`TOLERANCE_MS`), never past the clock while nobody is present. A missing input repeats the player's last
  one (`replaced`). `present` = connected slots from their join tick; a slot's join tick carries its join record (the
  member seated there). Slots go lowest-free. A tick can be final before it is due.
- **Broadcast**: newly finalized ticks, at most once per `BROADCAST_GAP` of a tick (under jitter each player's input
  arriving can finalize a tick), and a heartbeat when nothing was finalized for a tick (the clients time their clocks
  from it). Each Finalized carries the relay time, the input and command acks, and the client's unacked finalized
  ticks (as many as fit, ≤ `WINDOW_MAX`); a longer backlog, up to `CATCHUP_TICKS`, goes out one window per broadcast
  in turn. A client whose unacked ticks have left the ring is refused (`Too_Far_Behind`).
- **The window** (`window.odin`): each tick is written as its changes from the tick before it in the same packet,
  the first from the empty tick: a flags byte, then only what it says: present and replaced (a bit per slot); a bit
  per slot whose input changed and, per such slot, a bit per changed byte and those bytes; the commands; the join
  records (per tick, never carried over). A tick like the one before, without commands or joins, is one byte. Every
  packet decodes on its own, so losing one costs nothing more (the next repeats what wasn't acked). A tick's commands
  are budgeted so it fits a packet alone however much it changed (`window_tick_max_bytes`). A client's Inputs writes
  its own unacked inputs the same way, each from the one before.
- **Recording**: `Relay_Config.recording` (a `sim.Log_Sink`) gets the session's input log (`src/sim/SPEC.md`) as ticks
  are finalized: the header with a tick count of 0, each tick, the count when it ends (`relay_end_recording`, or
  `relay_destroy`); a recording that never ended still reads to its last tick. A shipped game leaves it off, or
  records to disk as an opt-in for bug reports.
- **The host leaving ends the session**: the host is the relay.

## Members

A player is a session **member**, the person, not a slot (the sim's side: `src/sim/SPEC.md`, Players).

- The relay gives each distinct person a **member id** for the session (1, 2, ...; never reused, at most 65,535) and
  keeps account-or-token -> member. The **account** comes from the link (`Link.account(peer)`), never from the
  client. On a link that vouches for none (LAN, direct UDP) the client's **token** is used instead: 16 random bytes in
  Hello (`Client_Config.token`; the Godot host keeps it in `user://`), never forwarded. Neither: a new member every
  time.
- Accounts and tokens never enter the deterministic stream: a finalized tick (and the log) carries only member ids,
  in the join record of a slot's join tick. Welcome carries the joiner's member id; the client predicts its own join
  record on its first tick.
- **Newest wins**: a Hello from a member who is still seated replaces their old connection once the new one is
  accepted (the slot is absent from the next tick, and the new connection joins in the lowest free slot at a later
  tick, as the same member): a restarted game is back at once instead of after the old connection's timeout.
- **The roster** is one reliable `Roster` message per member change: `{member, slot or none, connected, name, account
  platform and id}` (the vouched account; a token is never in it). Everyone connected gets each change; a joiner gets
  every entry. Departed members' entries stay (connected false, no slot): a "left" message can name them after they
  are gone. The client keeps them by member id (`client_member`, `roster_changes`).

## Timing

```
            one way           s − k              k
        ◀──────────────▶◀────────────────▶◀───────────▶
 ───────V──────────────R──────────────────L────────────S───────▶ ticks
        │              │                  │            └ S = L + k = R + s: the tick an input sampled now is
        │              │                  │              stamped with; it reaches the relay one way later,
        │              │                  │              just before S is due
        │              │                  └ L: the client's clock; it predicts up to P = L (at most V + cap)
        │              └ R: the relay clock (the tick due now); ticks are final about now, inputs being in
        └ V: the newest tick the client has verified (its Finalized took one way)
        ◀──────────── prediction depth P − V ≈ RTT/tick + ½ − k ≤ cap ─────────▶
 window: the relay finalizes S without a late input once R reaches S + tolerance
```

- **Stamp lead** `s = ceil((RTT/2 + 8 ms) / tick)`: an input reaches the relay 8 ms or so before its tick is due.
- **Input delay** (the lag a player feels) `k = clamp(ceil((RTT⁺ + 8 ms)/tick) + 1 − cap, k_min, k_max)`: the least
  delay that keeps the prediction depth inside the cap. RTT⁺ = RTT + 4 × its mean deviation (jitter); `k_min` 1 tick,
  `k_max` `MAX_DELAY_MS`. It rises at once and falls a tick per second.
- **The clock**: L runs `s − k` ticks ahead of the relay clock (behind, when negative), slewed ±2% towards it (a
  jump when more than 4 ticks behind). It starts at the first Finalized after Welcome, timed by the channel's round
  trip (measured from the Hello's ack on), so a joiner's inputs for its join tick arrive in time. Own inputs are
  sampled for L + k on every clock tick, also while the sim is held back: they count, and the view hitches.
- **Cap** `sim.ring_size(tick_hz) − 2`: the most the ring allows (a rollback target is always in it). Past the
  round-trip ceiling (depth > cap with k at k_max) the sim stalls a tick at a time; inputs still arrive in time.

## Client

- Frames: V (newest verified), P (newest predicted), L (the clock). Predicted ticks use own inputs and commands and
  the others' last finalized inputs repeated. A finalized tick that differs from its prediction (presence, input
  bytes, commands; `sim.inputs_same`) restores the tick before it and re-simulates to P.
- **Saves**: a predicted tick is saved every `PREDICTED_SAVE_EVERY` (2) ticks, and when a snapshot of it may be
  wanted; a re-simulated tick that is already final only when it is V (the next rollback's target) or a snapshot is
  wanted of it. A rollback restores the nearest saved tick at or before its target and re-steps from there: at most
  one tick back, which the ring holds even at full depth (P − V ≤ ring − 2). Checksum ticks are multiples of it.
- `client_stats` (`Client_Stats`, copied whole: the dev UI takes differences of the counters): rollbacks and their
  depth, stall and re-simulated ticks, ticks stepped and the time stepping them by `Step_Kind`, own inputs replaced,
  desync reports, when the relay's last message arrived; `client_steps`, how long each `client_step` that stepped
  the sim took (a `Durations`: fixed buckets, `durations_percentile`, `durations_merge`), the time the frame budget is
  about; a joiner's snapshot (bytes, Snap_Begin to its last chunk); and the round trip, the input delay and the
  channel's bytes. `client_inputs(tick)`: a tick's finalized inputs, else its predicted ones. `client_result` (the
  headless JSON, the Godot result line): `ok` = didn't fail, no desync, and a fixed-length session's every tick
  verified; its checksums are all of a fixed-length session's, the last `CHECKSUMS_KEPT` of an endless one's.

## Hooks (called from `client_step`, on the caller's thread)

- `sample(user, slot, tick, state) -> Input`: the local player's input for `tick` (state = latest predicted, or nil).
- `commands(user, slot, tick, state, out)` (optional): the local player's commands for `tick`, right after `sample`
  for every tick the client generates; `sim.send_command(out, command)` is false once `COMMAND_QUEUE` wait.
- `frame(user, simulation, Frame_Info{tick, verified, resim_from})`: after a step that computed ticks; the view reads
  `simulation.state` (`tick`'s) and `events_at` for `resim_from..tick`.
- `verified(user, simulation, tick, inputs, events)`: each newly verified tick, in order, with its final inputs and
  events.
- `status(user, Idle|Connecting|Connected|Failed|Disconnected, detail)`.
- `desync(user, Desync_Report{tick, diverged, detail})` (optional): below.

## Commands

The types and how `tick` reads them: `src/sim/SPEC.md`. Each player's commands arrive exactly once, in order.

- **Client:** a command gets the next seq n and a wanted tick W (the tick generated when the hook sent it) and is
  predicted at W. Unacked commands go with every Inputs packet until the relay acks them: the ack means
  **received**, not finalized; the client keeps predicting a command until a verified tick carries it (at W, or the
  first tick not finalized yet once W is, at most `COMMANDS_PER_SLOT` per tick, in order). Others' commands are
  unknown until finalized.
- **Relay:** takes each seq once, in order (a gap waits for the resend; at most `COMMAND_QUEUE` waiting per slot);
  clamps W to finalized + `INPUT_RING`, so a bogus far tick can't hold back the sender's later commands. Finalizing T,
  it puts in each present slot's waiting commands with W ≤ T: at most `COMMANDS_PER_SLOT` per slot and
  `TICK_COMMANDS` per tick, within the bytes that keep a tick alone inside one datagram, round-robin; the rest wait
  for T + 1. A left player's waiting commands go with it. A placement T ≠ W is a misprediction like any other.

## Late join and rejoin

- The joiner's join tick J = max(asked, clock + `JOIN_LEAD_MS`, finalized + 2). The lowest connected player that can
  (and didn't send it a bad one) is asked for a snapshot of the first checksum tick S ≥ J − 1 it verifies. It goes
  through the relay in reliable chunks, only from the player asked; the finalized ticks from S on are streamed to the
  joiner. A provider that leaves, sends nothing for `SNAP_STALL_US`, or sends a snapshot the relay can't use is
  replaced by another. Until it plays the joiner holds finalized ticks only up to `FIN_RING − 64` past S, so it is
  refused as too far behind when it isn't in within that plus `RELAY_RING` ticks of S (64 s at 64 Hz): the time a
  large world's snapshot has to arrive.
- **The check**: the joiner restores and sends its checksum of S; the relay compares it with the majority of the
  other players' checksums of S and answers `Snap_Ok` (the joiner plays) or asks another player. With nobody left to
  ask the joiner is refused: `Bad_Snapshot` after a failed check, `No_Snapshot` when nobody could send one. There is
  no replay from tick 0.
- When no other player's checksum of S comes within twice `CHECK_WAIT_MS` (its only other player, the provider,
  never reports S or leaves after sending it), there is nothing independent to compare with: the joiner plays
  unchecked, and the relay counts it (`Relay.unchecked_snapshots`). Refusing instead would turn away joiners who
  would have played fine; a snapshot that diverges is caught at the next checksum tick both report.
- A crafted snapshot can do no more than fail to load: Box3D images load safely from any bytes, and a snapshot that
  loads but differs from the majority fails the check.
- A rejoin is a late join, in the lowest free slot; a restarted program on the same address is recognized by its new
  epoch. Over EOS the product user id keeps the Peer (not the slot) while the user stays in the lobby, and makes the
  joiner the same member; over direct UDP a restarted program has a new port and is a new peer, the same member when
  its token is (direct UDP is for LAN and tests).

## Checksums and desyncs

- Every client sends the checksum of every 16th verified tick (`sim.DEEP_CHECKSUM_EVERY`: they cover every extra's
  whole state); a joiner from its first tick after S on.
- The relay judges a checksum tick once every player expected to report it has, or `CHECK_WAIT_MS` after it is due:
  the majority value (a tie goes to the lowest slot: with 2 players, the host). Slots that differ from it are a
  **desync**: counted, logged, and reported to every client (`Desync`: tick, `diverged`, detail); the `desync` hook
  gets it, the dev UI shows it, `session_run`'s `ok` turns false. A late report that differs from a judged tick is
  reported too. Checksums of ticks the relay has not finalized are dropped.
- **Typed reports** (`desync_detail` on the relay or host config; the Godot host turns it on where the dev UI is):
  clients keep snapshots of their last `DESYNC_IMAGES` checksum ticks (Welcome's `Keep_Images`); on the session's
  first desync the relay asks a majority player and a diverged one for theirs and diffs them (`sim.snapshot_diff`:
  table by table, field by field, then each extra's image): "tick 4160: enemies[12].pos.x 3.25 vs 3.5". Later
  desyncs are its consequences and carry no detail.
