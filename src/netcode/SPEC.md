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
  loopback (`hub_create`, `loopback_link`), UDP (`udp_listen`, `udp_connect`), `netsim_wrap(link, profile, seed,
  clock)` (latency, jitter, loss, duplicates, reordering; real or virtual clock). EOS implements a Link in its own
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
- **Relay** (`relay_create(cfg, I, P)`, `relay_add_link`, `relay_step`, `relay_stop`, `relay_finished`,
  `relay_clock`): owns the clock; finalizes tick T when every present player's input is in or the clock reaches
  T + tolerance (100 ms), and never past the clock while nobody is present; a missing input repeats the player's last
  one (`replaced`). `present` = connected slots
  from their join tick. Broadcasts unacked finalized ticks (as many as fit one datagram, ≤ 32; a longer backlog, up to 384 ticks, goes
  out one window per broadcast in turn, so a client catches up after a stall at a window per tick, not per RTT), keeps the official
  input log, routes snapshots, compares checksums (every 16 ticks). Hello carries protocol, slot (or any), join tick
  and a `compat` id (default `sim.compat_of(game)`: layouts, slots, tick rate, game name and version; a relay with
  compat 0 accepts any); rejects: full, slot taken, incompatible, not started. `ticks = 0` is an endless session.
  `PROTOCOL_VERSION` 5.
- **Client** (`client_create(&GAME, cfg, link, hooks)`, `client_step`, `client_stop`, `client_state`,
  `client_destroy`): verified and predicted frames, rollback from the first mispredicted tick (presence and input
  bytes compared, `sim.inputs_same`; finalized ticks at or below the held prefix are ignored), prediction cap (218 ms = 14 ticks at 64 Hz, the most RING
  allows; a client plays smoothly up to ~300 ms RTT, 166 ms stalled most ticks from ~250 ms), input delay `clamp(ceil((rtt/2 + 8 ms)/tick), 1, 100 ms)`
  re-evaluated each second by ±1, clock slewed ±2% towards relay tick + delay.
- **Host** (`host_create(&GAME, cfg, hooks)`, `host_add_link`, `host_step`, `host_stop`, `host_finished`,
  `host_destroy`): relay + the host's own client (slot 0) joined by loopback. Single player is a host with no remote
  links. Remote players reach the relay through any added link; the relay serves all links at once.

## Hooks (called from `client_step`, on the caller's thread)

- `sample(user, slot, tick, state) -> I`: the local player's input for `tick` (state = latest predicted, or nil).
- `frame(user, sim, Frame_Info{tick, verified, resim_from})`: after a step that computed ticks; the view reads
  `sim.state_at(tick)` and `tick − 1` to interpolate, and `events_at` for `resim_from..tick` (predicted events).
- `verified(user, sim, tick, events)`: each newly verified tick, in order, with its final events (confirm/cancel).
- `status(user, Idle|Connecting|Connected|Failed|Disconnected, detail)`.

## Late join

The relay gives the joiner slot J = max(asked, clock + 500 ms, finalized + 2) and asks the lowest connected client
with a known base for a snapshot at V ≥ J − 1 (requests queue, so several joiners at once work). The snapshot goes
through the relay chunked (1000 B reliable), and only from the provider asked, in order and within its announced
size. If nobody can provide one, the joiner starts from tick 0 and replays the whole log. If the provider leaves
before its snapshot got through, the relay asks another player, or sends an empty `Snap_Begin` (tick 0, 0 bytes):
the joiner starts from tick 0 and replays. A left slot (`Leave`, or a link/channel disconnect) stops being present at
once and can be reused.

## Tests

`tests/netcode`: host + remote clients under `wan` on a virtual clock (checksums agree, relay log replays to the
verified checksum, hooks in order), late join + leave + slot reuse, single player, slot rejection, the delay
formula at 32/60/64/128 Hz, outages and rejoins, everyone leaving, a snapshot provider leaving, stale finalized
ticks, reliable floods, UDP endpoint reuse, oversized messages, another build refused, and a seeded fuzz of the
channel, relay and client decoders. The end-to-end suites run the same code on the virtual clock through
`unified:headless` (`src/headless/SPEC.md`); `dev.py check` runs it in real time over UDP between processes.
