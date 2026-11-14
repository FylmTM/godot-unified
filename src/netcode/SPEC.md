# `unified:netcode`: input relay, prediction, rollback

Decided autonomously 2026-11-09, pending developer review.

Generic over the game: `Relay(I, P)`, `Client(S, I, W, P)`, `Host(S, I, W, P)`. Nothing runs a thread or loop of
its own: the host application calls `*_step(now_us) -> wake_us` from its own loop (or the virtual clock in tests)
and sleeps with `sleep_until(wake_us)`. `now_us()` is the monotonic time base.

## Pieces

- **Link** (the transport interface, stable and small): `send(to, bytes)`, `recv(buf) -> (n, from, ok)`, `close`,
  optional `event() -> (peer, Connected|Disconnected, ok)`, optional `forget(peer)` (the channel is done with a peer
  number; UDP reuses it). Datagrams ≤ `MAX_DATAGRAM` (1152, fits EOS P2P), may be lost. A link numbers its remote
  endpoints as `Peer`s (a client-side link: peer 0). Implementations: in-process
  loopback (`hub_create`, `loopback_link`), UDP (`udp_listen(port, .Local | .Lan)`: 127.0.0.1, which never
  triggers a firewall prompt, or every interface for players on other machines; `udp_connect`, loopback-bound for
  a loopback remote), `netsim_wrap(link, profile, seed,
  clock)` (latency, jitter, loss, duplicates, reordering; real or virtual clock; `split` with `profile_in` impairs
  incoming apart). EOS implements a Link in its own
  package.
- **Channel**: reliability over any number of links (`channel_add_link`): every (link, peer) pair is one channel
  peer. Seq/ack/32-bit ack field, reliable resend by RTT, in-order delivery, keepalive 250 ms, timeout 10 s. At most
  `REL_WINDOW` (512) reliable messages in flight past the oldest unacked one (the receiver drops ids beyond it);
  messages over `MAX_MESSAGE` are dropped (`channel_send` returns false); a datagram with a bad header gets no
  connection; sent-packet records are allocated per open connection. Each
  side's connection has an epoch, sent (and the peer's echoed) in every datagram: a peer that started over (a
  rejoin from a restarted program on the same address) replaces the old connection at once, and a side still
  talking to a connection the other ended (timed out after a one-way outage) is told so at once, instead of
  sitting half-open.
- **Relay** (`relay_create(cfg, Input, PLAYERS)`, `relay_add_link`, `relay_step`, `relay_stop`, `relay_finished`,
  `relay_clock`): owns the clock, which starts once the start players have connected: it sends them Welcome and
  tick 0 is due 500 ms later (`START_LEAD_MS`; at once with `local_start`, the host's in-process client), so a far
  start player's inputs for tick 1 arrive in time, like a joiner's (its J is as far ahead); it broadcasts during
  the lead too, with a negative relay time. Finalizes tick T when every present player's input is in or the clock reaches
  T + tolerance (100 ms), and never past the clock while nobody is present; a missing input repeats the player's last
  one (`replaced`); commands go in as below. `present` = connected players
  from their join tick. Broadcasts unacked finalized ticks (as many as fit one datagram, ≤ 32, fewer when they carry commands; a longer backlog, up to 384 ticks, goes
  out one window per broadcast in turn, so a client catches up after a stall at a window per tick, not per RTT), keeps the official
  input log, routes snapshots, compares checksums (every `sim.DEEP_CHECKSUM_EVERY` = 16 ticks, the ones that cover every extra's whole state). Hello carries protocol, player (or any), join tick
  and a `compat` id (default `sim.compat_of(game)`: layouts, command and event types, the player count, tick rate, game name and version; a relay with
  compat 0 accepts any); rejects: full, player taken, incompatible, not started. `ticks = 0` is an endless session.
  `PROTOCOL_VERSION` 8 (8: the relay time is below 0 during the start lead; a game bumps its lobby bucket with it).
- **Client** (`client_create(&GAME, cfg, link, hooks)`, `client_step`, `client_stop`, `client_state`,
  `client_destroy`): verified and predicted frames, rollback from the first mispredicted tick (presence, input
  bytes and commands compared, `sim.inputs_same`; finalized ticks at or below the held prefix are ignored), prediction cap (`sim.ring_size(tick_hz)` − 2 ticks, the most
  the ring allows: 187 ms at 32 Hz, 218 ms at 64, 234 ms at 128; at 64 Hz a client plays smoothly up to ~300 ms RTT, and
  166 ms stalled most ticks from ~250 ms), input delay `clamp(ceil((rtt/2 + 8 ms)/tick), 1, 100 ms)`
  re-evaluated each second by ±1, clock slewed ±2% towards relay tick + delay. The clock starts at the first
  Finalized after Welcome (during the relay's start lead: once its tick 0 is due), timed by the channel's latest RTT
  sample until the relay echoes an Inputs packet (a round trip later), so a joiner's inputs for its join tick and a
  start player's for tick 1 arrive within the tolerance up to ~550 ms RTT.
  Cumulative counters for tools (the dev UI's graphs take differences): rollbacks, stall and re-simulated ticks, ticks
  stepped and the time stepping them by `Step_Kind` (verified, re-simulated after a rollback, newly predicted), our
  inputs the relay replaced (they came too late), when the relay's last message arrived.
- **Host** (`host_create(&GAME, cfg, hooks)`, `host_add_link`, `host_step`, `host_stop`, `host_finished`,
  `host_destroy`): relay + the host's own client (player 0) joined by loopback. Single player is a host with no remote
  links. Remote players reach the relay through any added link; the relay serves all links at once, from when the
  host's own player is in (so a remote player whose Hello was already waiting joins as a late joiner, never as
  player 0). The host's relay starts its clock without the start lead (`local_start`).

## Hooks (called from `client_step`, on the caller's thread)

- `sample(user, player, tick, state) -> Input`: the local player's input for `tick` (state = latest predicted, or nil).
- `commands(user, player, tick, state, out)` (optional): the local player's commands for `tick`, called right after
  `sample` for every tick the client generates; `sim.send_command(out, command)` returns false once `COMMAND_QUEUE`
  (64) of the client's commands wait to be verified.
- `frame(user, simulation, Frame_Info{tick, verified, resim_from})`: after a step that computed ticks; the view reads
  `sim.state_at(tick)` and `tick − 1` to interpolate, and `events_at` for `resim_from..tick` (predicted events).
- `verified(user, simulation, tick, events: []sim.Raw_Event)`: each newly verified tick, in order, with its final
  events (the view confirms or cancels what it predicted).
- `status(user, Idle|Connecting|Connected|Failed|Disconnected, detail)`.

## Commands

Signed off by the developer 2026-11-10 (the types and how `tick` reads them: `src/sim/SPEC.md`). Each player's
commands arrive exactly once, in order; never lost; never repeated by the input-repeat rules.

- **Client:** a command gets the next seq n and a wanted tick W (the tick being generated when the hook sent it,
  i.e. sampled with the input delay, like the input of W) and is **predicted locally at W**. The client sends its
  unacked commands with every Inputs packet (first seq, count; per command W, kind, size, bytes; as many as fit next
  to the inputs) until the relay acks them, and predicts each until a verified tick carries it: at W, or at the
  first tick not finalized yet once W is (a late command moves on), at most 4 per tick, in order. Another player's
  commands are unknown until finalized: predicted ticks carry none of theirs.
- **Relay:** takes each seq once, in order (duplicates and resends skipped; a gap waits for the resend; at most
  `COMMAND_QUEUE` waiting per player). Finalizing tick T, it puts in each present player's waiting commands with
  W ≤ T, in seq order: T = W when W isn't finalized yet, else the next tick it finalizes. A late (replaced) input's
  commands are not lost: they arrive after W and go in a later tick. At most 4 per player and 16 per tick, within
  the bytes that keep a tick alone inside one datagram (round-robin over the players); the rest wait for T + 1.
  A left player's waiting commands go with it.
- **Wire:** a finalized tick is `sim.write_tick` (present, replaced, inputs, command count, then per command player,
  kind, size, bytes: an empty tick costs one byte), and Finalized carries a command ack (the highest seq received).
  The relay's log is the official record with the commands (`UNIL` v5); a late joiner gets them from the log (its
  snapshot is of a verified tick; the ticks after it come with their commands, or the whole log on a replay).
- **Rollback:** a finalized tick is compared with the prediction by presence, input bytes and commands
  (`sim.inputs_same`): when the relay placed a command at T ≠ W, the sender rolls back at W (and again until it
  lands); every other client rolls back to T as for any input that differs from its prediction.

## Late join

The relay gives the joiner the join tick J = max(asked, clock + 500 ms, finalized + 2) and asks the lowest connected client
with a known base for a snapshot at V ≥ J − 1 (requests queue, so several joiners at once work). The snapshot goes
through the relay chunked (1000 B reliable), and only from the provider asked, in order and within its announced
size. If nobody can provide one, the joiner starts from tick 0 and replays the whole log. If the provider leaves
before its snapshot got through, the relay asks another player, or sends an empty `Snap_Begin` (tick 0, 0 bytes):
the joiner starts from tick 0 and replays. A left player (`Leave`, or a link/channel disconnect) stops being present at
once and can be reused.

## Tests

`tests/netcode` (every client sends the toy's scripted commands unless a test says otherwise): host + remote clients
under `wan` on a virtual clock (checksums agree, relay log replays to the verified checksum, hooks in order), late
join + leave + seat reuse, single player, a taken player refused, the delay formula at 32/60/64/128 Hz, outages and rejoins,
everyone leaving, a snapshot provider leaving, stale finalized ticks, reliable floods, UDP endpoint reuse, oversized
messages, another build refused, a seeded fuzz of the channel, relay and client decoders (commands included), and
commands (`command_test.odin`): exactly once and in order under `bad` (loss, duplicates, reordering), a late input's
command moved to a later tick with the sender rolling back and everyone verifying it there, the 5th command of a
tick waiting for the next. The end-to-end suites run the same code on the virtual clock through
`unified:headless` (`src/headless/SPEC.md`); `uni test --suite net` runs it in real time over UDP between processes.
