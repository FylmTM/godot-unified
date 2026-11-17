# `unified:netcode`: input relay, prediction, rollback

Status: signed off 2026-11-14 (#8).

Nobody sends game state: every client runs the whole deterministic sim, and the relay only orders inputs. The
relay's input log is the session (seed + content + log replays to the same checksums anywhere).

Generic over the game: `Relay(G)`, `Client(G)`, `Host(G)` (`G` the game type, a `sim.Game`). Nothing runs a
thread or loop of its own: the host application calls `*_step(now_us) -> wake_us` from its own loop (or one thread
on a `Virtual_Clock` in tests, which makes whole sessions deterministic and fast) and sleeps with
`sleep_until(wake_us)` (to the microsecond: a high-resolution waitable timer on Windows, whose `Sleep` takes whole
milliseconds). The wake time is the next deadline (a tick of the relay or the client, a held broadcast) or the poll
interval (the configs' `poll_us`, 1 ms by default), whichever is sooner. A host with no remote links (single player)
doesn't poll: its relay and client hand each other what they send within the same `host_step`, so it wakes at its
deadlines only, about twice a tick (measured on the toy: 156 wakeups a second and a quarter of the CPU, from 683).
Remote links are polled every 1 ms (decided in #263: EOS links can't wait on a socket, and the Godot driver pumps EOS
every 4 ms anyway). The session thread allocates nothing in steady state (#262): queued messages, delayed
datagrams and early reliable messages take reused slots (`Slot_Pool`), the loopback hub's inboxes are byte queues
swapped whole, a client's kept desync images reuse their buffers (`tests/netcode/alloc_test.odin` keeps the count at
0). `now_us()` is the monotonic time base. A game touches the netcode only through a `Link` (it
picks EOS, UDP or loopback), `Hooks`, the configs (through
`unified:godot`'s driver, or directly in its tests) and the test helpers (`Profile`, `Virtual_Clock`, `hub_create`,
through `headless.session_run`).

## Pieces

- **Link** (the transport interface, stable and small): `send(to, bytes)`, `recv(buf) -> (n, from, ok)`, `close`,
  optional `event() -> (peer, Connected|Disconnected, ok)`, optional `forget(peer)` (UDP reuses the number; EOS
  closes the P2P connection; wrappers such as the netsim pass it on),
  optional `account(peer) -> (Account{platform, id}, ok)` (the account the transport vouches for behind a peer: EOS
  gives the remote's product user id; LAN and direct UDP none).
  Datagrams ≤ `MAX_DATAGRAM` (1152, fits EOS P2P), may be lost. A link numbers its remote endpoints as `Peer`s (a
  client-side link: peer 0). Implementations: in-process loopback (`hub_create`, `loopback_link`), UDP
  (`udp_listen(port, .Local | .Lan)`: 127.0.0.1, or every interface for players on other machines; `udp_connect`),
  `netsim_wrap(link, profile, seed, clock)` (latency, jitter, loss, duplicates, reordering, seeded, real or virtual
  clock; `split` with `profile_in` impairs incoming apart; an ideal profile, `profile_is_ideal`, returns the link
  as is; closing it sends the datagrams still delayed, as if already on the wire). EOS implements a Link in its own
  package.
- **Channel**: reliability over any number of links (`channel_add_link`): every (link, peer) pair is one channel
  peer. Every datagram carries seq, ack and a 32-bit ack history (`DGRAM_VERSION` 2). Reliable messages ride until a
  datagram carrying them is acked, are resent after `1.5 × srtt + 15 ms` (30–500 ms), and are delivered once, in
  order; unreliable ones as they come. At most `REL_IN_FLIGHT` (32) datagrams carrying reliable messages are in
  flight past the peer's newest ack, so one ack covers a whole burst (a snapshot is never resent though it
  arrived); at most `REL_WINDOW` (512) reliable messages past the oldest unacked one; messages over `MAX_MESSAGE` are
  refused (`channel_send` false). Keepalive 250 ms, timeout 10 s, or 30 s for a peer that has never answered
  (`FIRST_ANSWER_US`: a transport like EOS sets up its path after the first hello). Each side's connection has an
  epoch, sent (and the peer's echoed) in every datagram: a restarted peer on the same address replaces its old
  connection at once, and a side still talking to a connection the other ended is told so at once instead of sitting
  half-open.
- **Relay** (`relay_create(cfg, G)`, `relay_add_link`, `relay_step`, `relay_stop`, `relay_finished`,
  `relay_clock`, `relay_tick`, `relay_end_recording`): owns the clock; finalizes ticks, broadcasts them, routes and
  checks late-join snapshots, judges checksums. Keeps the last `RELAY_RING` (512) finalized ticks; the whole
  session only in its optional recording. Serves all links at once. `ticks = 0` is an endless session.
- **Client** (`client_create(&GAME, cfg, link, hooks)`, `client_step`, `client_stop`, `client_state`,
  `client_destroy`, `client_result`): the verified and predicted frames, rollback, the clock and input delay,
  snapshots for joiners.
- **Host** (`host_create(&GAME, cfg, hooks)`, `host_add_link`, `host_step`, `host_stop`, `host_finished`,
  `host_destroy`): the relay plus the host's own client (slot 0) joined by loopback; `Host_Config.account` is the
  host player's own platform account (the Godot host asks its transport). Single player is a host with no remote
  links. The relay serves remote links from when the host's own player is in (a remote Hello already waiting joins
  as a late joiner, never in slot 0), and starts its clock without the start lead.

## Relay

- **Hello** carries the protocol, the slot (or any), a join tick, a `compat` id (default `sim.compat_of(game)`:
  layouts, command and event types, player count, tick rate, game name and version, content; 0 at the relay
  accepts any), the client's token (Members) and a name. Rejects: `Full`, `Player_Taken`, `Incompatible`,
  `Not_Started`, `No_Snapshot` (a joiner nobody can send a snapshot), `Bad_Snapshot`, `Too_Far_Behind` (below). An EOS
  lobby carries `compat` and `PROTOCOL_VERSION` (13), so a joiner on another build is told before it joins
  (`src/eos/SPEC.md`). **Welcome** carries the slot, the joiner's member id, the seed, the tick rate, the length,
  the first tick it is present and flags.
- **Start** (#179, D6 of #8): the clock starts once the start players have connected: they get Welcome and tick 0 is
  due `START_LEAD_MS` (500 ms) later, so a far start player's inputs for tick 1 arrive in time (~550 ms RTT); during
  the lead the relay already broadcasts, with a negative relay time. A host's relay skips the lead (`local_start`):
  its only start player is in-process.
- **Finalizing**: tick T is final once every present player's input for T is in, or the clock reaches T +
  tolerance (100 ms, 7 ticks at 64 Hz), never past the clock while nobody is present. A missing input repeats the
  player's last one (`replaced`). `present` = connected slots from their join tick; a slot's join tick carries its
  join record (`sim.Inputs.member`: the member seated there). Slots go lowest-free. A tick can be final before it
  is due.
- **Broadcast**: newly finalized ticks, at most once per ¾ tick (`BROADCAST_GAP`, #246), and a heartbeat when
  nothing was finalized for a tick (the clients time their clocks from it). Under jitter the players' inputs arrive
  apart and each arrival can finalize a tick: once per finalize was ~106 packets a second per client at 64 Hz (100 ±
  25 ms, 1% loss), ¾ tick cuts packets 25% and bytes 23% for +0.12 rollback depth, a clean network unchanged (a whole
  tick: −33%, but +1 depth on a clean network). Each Finalized datagram carries the relay time, an echo of the client's last Inputs time, the
  input and command acks, and the client's unacked finalized ticks (as many as fit, ≤ `WINDOW_MAX` 32); a longer
  backlog, up to `CATCHUP_TICKS` (384), goes out one window per broadcast in turn. A client whose unacked ticks have
  left the ring is refused (`Too_Far_Behind`).
- **The window** (#192, `window.odin`): each tick is written as its changes from the tick before it in the same
  packet, the first from the empty tick (nobody present, zero inputs): a flags byte (presence changed, inputs
  changed, has commands, has join records), then only what it says: present and replaced; a bit per slot whose input
  changed and, per such slot, a bit per changed byte and those bytes; the commands; the join records (per tick,
  never carried over). A tick like the one before, without commands or joins, is one byte; absent seats cost nothing. Every packet decodes on its own, so acks and loss work as before
  (the next packet repeats what wasn't acked). A tick's commands are budgeted so it fits a packet alone however much
  it changed (`window_tick_max_bytes`). Measured (`net-bench`, 2 clients, 140 ms each way): a joiner receives 7.5
  kB/s in drift, 7.8 in friendslop, from 38 and 52 (110 and 115 bytes a packet from 555 and 758); scripted inputs
  change every 16 ticks, a player turning the aim every tick costs 3–4 bytes a tick more. A client's Inputs packet
  writes its own unacked inputs the same way (#245, `window_write_input`: each from the one before, the first from
  the zero input): its upload at 60 / 100 / 140 ms is 4.4 / 4.8 / 5.2 kB/s in drift (from 6.7 / 8.6 / 10.6), 4.6 /
  5.1 / 5.6 in friendslop (from 7.7 / 10.3 / 12.8), nearly all of it headers.
- **Recording** (#8 D12): `Relay_Config.recording` (a `sim.Log_Sink`: `sim.log_sink_memory`, `sim.log_sink_file`)
  gets the session's input log (`UNIL`, `src/sim/SPEC.md`) as ticks are finalized: the header with a tick count of
  0, each tick in the wire format, the count when it ends (`relay_end_recording`, or `relay_destroy`); a recording
  that never ended still reads to its last tick. `session_run`, the headless `--log` and the online modes record; a
  shipped game leaves it off, or records to disk as an opt-in for bug reports.
- **The host leaving ends the session** (#8 D9): the host is the relay. Host migration is #187.

## Members

Signed off 2026-11-15 (#222; the sim's side: `src/sim/SPEC.md`, Players). A player is a session **member**, the
person, not a slot.

- The relay gives each distinct person a **member id** for the session (1, 2, ...; never reused, at most 65,535) and
  keeps account-or-token -> member. The **account** comes from the link (`Link.account(peer)`; EOS: the remote's
  product user id), never from the client. On a link that vouches for none (LAN, direct UDP) the client's **token**
  is used instead: 16 random bytes in Hello (`Client_Config.token`; the Godot host keeps it in `user://`, a headless
  client takes `--token`), never forwarded. Neither has one: a new member every time.
- Accounts and tokens never enter the deterministic stream: a finalized tick (and the log) carries only member ids,
  in the join record of a slot's join tick. Welcome carries the joiner's member id; the client predicts its own join
  record on its first tick.
- **Newest wins**: a Hello from a member who is still seated drops their old connection first (`player_gone`: the
  slot is absent from the next tick, and the new connection joins in the lowest free slot at a later tick, as the same
  member). A restarted game is back at once instead of after the old connection's timeout (#173).
- **The roster** is one reliable `Roster` message per member change: `{member, slot or none, connected, name,
  account platform and id}` (the vouched account; a token is never in it). Everyone connected gets each change; a
  joiner gets every entry. Departed members' entries stay (connected false, no slot): a "left" message can name them
  after they are gone. The client keeps them by member id (`client_member(client, id) -> ^Roster_Entry`,
  `roster_changes`).

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
 window: the relay finalizes S without a late input once R reaches S + tolerance (7 ticks at 64 Hz)
```

- **Stamp lead** `s = ceil((RTT/2 + 8 ms) / tick)`: an input reaches the relay 8 ms or so before its tick is due.
- **Input delay** (the lag a player feels, #8 D3) `k = clamp(ceil((RTT⁺ + 8 ms)/tick) + 1 − cap, k_min, k_max)`:
  the least delay that keeps the prediction depth inside the cap. RTT⁺ = RTT + 4 × its mean deviation (jitter);
  `k_min` is the game's `sim.Game.min_input_delay` (0: 1), `k_max` 100 ms (7 ticks at 64 Hz). It rises at once
  and falls a tick per second.
- **The clock**: L runs `s − k` ticks ahead of the relay clock (behind, when negative), slewed ±2% towards it (a
  jump when more than 4 ticks behind). Own inputs are sampled for L + k on every clock tick, also while the sim
  is held back (#8 D4): they count, and the view hitches.
- **Prediction depth** `P − V ≈ RTT/tick + ½ − k`: felt lag and rollback depth add up to the round trip.
- **Cap** `sim.ring_size(tick_hz) − 2`: the most the ring allows (a rollback target is always in it): 6 ticks
  (187 ms) at 32 Hz, 14 (218 ms) at 64, 30 (234 ms) at 128.
- **Round-trip ceiling**: depth ≤ cap with k at k_max: RTT ≲ (cap + k_max − ½) ticks ≈ 320 ms at 64 Hz, less the
  jitter. Past it the sim stalls a tick at a time; inputs still arrive in time. A lobby warning above it is #186.
- Measured at 64 Hz on the toy (4 clients, `uni bench`'s `net-bench`): 100 ms RTT k = 1, depth 6.0; 200 ms k =
  1, depth 11.9; 300 ms k = 7, depth 12.9, 20 stalled of 4,800 ticks; 400 ms 4,744 stalled, 0 inputs replaced.

## Client

- Frames: V (newest verified), P (newest predicted), L (the clock). Predicted ticks use own inputs and commands and
  the others' last finalized inputs repeated. A finalized tick that differs from its prediction (presence, input
  bytes, commands; `sim.inputs_same`) restores the tick before it and re-simulates to P. Re-simulated ticks that are
  already final are not saved (#117, `sim.step_unsaved`), except V (the next rollback's target), V − 1 when nothing
  is predicted past V (the view interpolates between P and P − 1), and a checksum tick a snapshot is wanted of.
- The clock starts at the first Finalized after Welcome (during the start lead: once L's tick 0 is due), timed by
  the channel's latest RTT sample until the relay echoes an Inputs packet, so a joiner's inputs for its join tick
  arrive in time up to ~550 ms RTT.
- Cumulative counters (the dev UI takes differences): rollbacks, stall and re-simulated ticks, ticks stepped and the
  time stepping them by `Step_Kind`, own inputs replaced, desync reports, when the relay's last message arrived.
  `client_result` (the headless JSON, the Godot result line): `ok` = verified every tick, didn't fail, no desync.

## Hooks (called from `client_step`, on the caller's thread)

- `sample(user, player, tick, state) -> Input`: the local player's input for `tick` (state = latest predicted, or
  nil).
- `commands(user, player, tick, state, out)` (optional): the local player's commands for `tick`, right after `sample`
  for every tick the client generates; `sim.send_command(out, command)` is false once `COMMAND_QUEUE` (64) wait.
- `frame(user, simulation, Frame_Info{tick, verified, resim_from})`: after a step that computed ticks; the view reads
  `sim.state_at(tick)` and `tick − 1` to interpolate, and `events_at` for `resim_from..tick`.
- `verified(user, simulation, tick, events)`: each newly verified tick, in order, with its final events.
- `status(user, Idle|Connecting|Connected|Failed|Disconnected, detail)`.
- `desync(user, Desync_Report{tick, diverged, detail})` (optional): below.

## Commands

Signed off by the developer 2026-11-10 (the types and how `tick` reads them: `src/sim/SPEC.md`); its two
implementation choices accepted in the #8 sitting (D2). Each player's commands arrive exactly once, in order.

- **Client:** a command gets the next seq n and a wanted tick W (the tick generated when the hook sent it) and is
  predicted at W. Unacked commands go with every Inputs packet until the relay acks them: the ack means
  **received**, not finalized; the client keeps predicting a command until a verified tick carries it (at W, or the
  first tick not finalized yet once W is, at most 4 per tick, in order). Others' commands are unknown until
  finalized.
- **Relay:** takes each seq once, in order (a gap waits for the resend; at most `COMMAND_QUEUE` waiting per
  player); clamps W to finalized + 256 (`INPUT_RING`), so a bogus far tick can't hold back the sender's later
  commands. Finalizing T, it puts in each present player's waiting commands with W ≤ T: at most 4 per player and
  16 per tick, within the bytes that keep a tick alone inside one datagram, round-robin; the rest wait for T + 1. A
  left player's waiting commands go with it.
- **Wire:** a finalized tick carries its commands as `sim.write_commands` does (the window, under Relay), and its join
  records as `sim.write_joins` does. A placement
  T ≠ W is a misprediction like any other (the sender rolls back at W).

## Late join and rejoin

- The joiner's join tick J = max(asked, clock + 500 ms, finalized + 2). The lowest connected player that can (and
  didn't send it a bad one) is asked for a snapshot of the first checksum tick S ≥ J − 1 it verifies (#8 D11 b; S
  is at most 15 ticks later). It goes through the relay in 1,000-byte reliable chunks, only from the player asked.
  The finalized ticks from S on are streamed to the joiner.
- **The check**: the joiner restores and sends its checksum of S; the relay compares it with the majority of the
  other players' checksums of S (below) and answers `Snap_Ok` (the joiner plays) or asks another player (the
  joiner replaces its sim with the new snapshot). With nobody left to ask the joiner is refused: `Bad_Snapshot`
  after a failed check, `No_Snapshot` when nobody could send one. A provider that leaves before its snapshot got
  through is replaced the same way. There is no replay from tick 0 (#8 D12).
- A crafted snapshot can do no more than fail to load: Box3D images load safely from any bytes (#8 D11 a), and a
  snapshot that loads but differs from the majority fails the check.
- A rejoin is a late join, in the lowest free slot; a restarted program on the same address is recognized by its new
  epoch. Over EOS the product user id keeps the Peer (not the slot) and makes the joiner the same member (Members);
  over direct UDP a restarted program has a new port and is a new peer, the same member when its token is (#173; #8
  D10: direct UDP is for LAN and tests).

## Checksums and desyncs

- Every client sends the checksum of every 16th verified tick (`sim.DEEP_CHECKSUM_EVERY`: they cover every extra's
  whole state); a joiner from its first tick after S on.
- The relay judges a checksum tick once every player expected to report it has, or `CHECK_WAIT_MS` (1 s) after it
  is due: the majority value (a tie goes to the lowest player: with 2 players, the host). Players that differ from
  it are a **desync** (#8 D5): counted, logged, and reported to every client (`Desync`: tick, `diverged`, detail);
  the `desync` hook gets it, the dev UI shows it, `session_run`'s `ok` turns false. A late report that differs from
  a judged tick is reported too.
- **Typed reports** (dev builds, `Relay_Config.desync_diff`, `Host_Config.desync_detail`): clients keep snapshots of
  their last `DESYNC_IMAGES` (8) checksum ticks (Welcome's `Keep_Images`); on the session's first desync the relay
  asks a majority player and a diverged one for theirs and diffs them (`sim.snapshot_diff`: table by table, field by
  field, then each extra's image): "tick 4160: enemies[12].pos.x 3.25 vs 3.5". Later desyncs are its consequences
  and carry no detail.
- **Recovery** (specified here, built in #188):
  1. *Rejoin in place*: a diverged client is resynced from a majority player's snapshot of a checksum tick, checked
     as a joiner's is; it keeps its slot, clock and input stream. With 2 players the host's state wins.
  2. A client whose resync fails (no majority player can provide, or the check fails again) is refused
     (`Desynced`); a desync with no majority (3+ players all differing) ends the session.
  3. *Re-anchor*: a client whose backlog passes `CATCHUP_TICKS` (384) gets a checked snapshot instead of the stream,
     as in 1; until then the relay streams it up to its ring and refuses it past that (`Too_Far_Behind`).

## Tests

`tests/netcode`, on the toy and a virtual clock unless a test says otherwise (every client sends the toy's scripted
commands): host + remote clients under `wan` (checksums agree, the recording replays to the verified checksum, hooks
in order), late join + leave + slot reuse (the roster by member), single player (and that it wakes at its deadlines
only), no heap allocation in steady state (`alloc_test.odin`), a taken player refused, the delay and stamp formulas at
32/60/64/128 Hz, outages and rejoins, catching up, too far behind, everyone leaving (a returning player refused),
a snapshot provider leaving (another steps in; with nobody, the joiner is refused), a bad snapshot refused and
another sent (with nobody else: refused), the `desync` hook, a reliable burst not resent, a jitter-only netsim,
stale finalized ticks, the window encoding (`window_test.odin`: round trips, sizes, malformed ticks refused),
reliable floods, UDP endpoint reuse, oversized messages, another build refused, a seeded
fuzz of the channel, relay and client decoders, and commands (`command_test.odin`): exactly once and in order under
`bad`, a late input's command moved to a later tick, the 5th command of a tick waiting for the next. Members (`member_test.odin`): a token, and an account a link vouches
for, bring a member back in another slot with the same handle and data; the newest connection of a member wins; the
roster keeps a departed member's entry; neither the token nor the account id is in the recording.
`tests/headless`: a desync made on purpose (a tick that reads the World) is detected, reported to everyone with a
typed detail, and fails the session; inputs count past the round-trip ceiling (400 ms: 0 of 2,400 replaced, 2,322
before); the delay stays at the game's floor within the window. The end-to-end suites run the same code through
`unified:headless` (`src/headless/SPEC.md`); `uni test --suite net` runs it in real time over UDP between processes;
`uni bench` runs each game's session under `bad` (`net-bench`: time, rollbacks, stalls, bytes per second).
