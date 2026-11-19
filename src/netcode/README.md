# `unified:netcode`: input relay, prediction, rollback

Nobody sends game state: every client runs the whole deterministic sim, and the relay only orders inputs. The
relay's input log is the session: seed, levels and log replay to the same checksums anywhere.

Generic over the game: `Relay(G)`, `Client(G)`, `Host(G)`, `G` a `sim.Game`. It steps, saves, snapshots and
checksums through `unified:sim` and writes its bytes with `unified:wire`. A game touches it through a `Lobby` (online
play: `eos.lobby`), `Hooks` (through `unified:godot`'s driver, or directly in its tests) and `headless.session_run`;
it implements no transport. `unified:eos` implements a `Link` and a `Lobby`. The library logs through
`context.logger` (`core:log`): silent unless the host sets a logger.

Nothing runs a thread or loop of its own: the host application calls `relay_step`, `client_step` or `host_step` from
its own loop and sleeps until the wake time it returns (`sleep_until`); tests step whole sessions on one thread on a
`Virtual_Clock`, which makes them deterministic and fast. The wake time is the next deadline (a tick of the relay or
the client, a held broadcast) or the poll interval, whichever is sooner. Remote links are polled (EOS links can't
wait on a socket). A host with no remote links doesn't poll: its relay and client hand each other what they send
within the same `host_step`, so it wakes at its deadlines only.

The session thread allocates nothing in steady state: queued messages, delayed datagrams and early reliable messages
take reused slots (`Slot_Pool`), the loopback hub's inboxes are byte queues swapped whole, a client's kept desync
ticks are the sim's keep slots.

## Pieces

- **Link**: the transport interface, stable and small. Implementations: in-process loopback (a `Hub`), UDP, the
  network simulator, EOS P2P (in `unified:eos`).
- **Lobby**: online play: finds a session by a short code and hands each side a `Link`.
- **Network simulator** (`netsim.odin`): impairs any link, seeded, for tests, headless sessions and the dev UI's
  Conditions panel.
- **Channel**: reliability over any number of links (below).
- **Relay**: owns the clock; finalizes ticks, broadcasts them, routes and checks late-join snapshots, judges
  checksums. It runs no game code: only the game's Input, player count and tick rate matter to it.
- **Client**: the verified and predicted frames, rollback, the clock and input delay, snapshots for joiners.
- **Host**: the relay plus the host's own client (slot 0) joined by loopback. Single player is a host with no remote
  links. The host leaving ends the session: the host is the relay. A single-player host can pause: it runs its relay
  and client on session time, its clock less the time spent paused, so from their side no time passed and the session
  resumes byte for byte as if never paused; a remote link refuses the pause and ends one (online a pause is the game's
  state, `src/sim/README.md`, Game time).

## The wire

- **Versions.** Every datagram's first byte carries `PROTOCOL_VERSION`, so two builds never parse each other's
  datagrams: one of another version is answered with a notice that never changes, which no version ever answers, and a
  client that gets one from its relay fails at once ("a different game build"). A lobby adds the version to the build
  it matches (`Lobby_Build`), so a joiner on another one is told before it connects.
- **Round trip**: one measure, the channel's. Each datagram's ack names the datagram that arrived last and how long it
  waited before the ack went out, so the sender's sample is the path alone. The last arrival, not the newest seq:
  under jitter the newest is the one that came fast, and sampling only it would read the round trip short. The
  channel uses it for its resend timeout; the client averages it (with its mean deviation) for its clock and input
  delay.
- **Messages** (`Msg`, each value with its fields). The relay knows a sender's slot from its connection: no message
  carries its own slot, so a client speaks only for itself. Byte layouts live in the headers: datagrams in
  `channel.odin`, ticks and inputs in `window.odin`.
- **Widths.** A game's widest tick (every Input byte changed, a player joining with their Profile:
  `window_tick_max_bytes`) must leave
  `TICKS_PER_MESSAGE_MIN` of them per Finalized message, and `relay_create` refuses a wider game (`game_violation`,
  which the Godot host reports with the sim's): fewer ticks per message leave no room to make up a lost one, and
  clients on a lossy network stall on most ticks. The bound is on players and Input bytes together: more players
  leave fewer bytes per Input. A game at the bound costs its host upstream: on a lossy path every unacked tick rides again each
  broadcast, so it grows with the players and the tick rate (`uni bench` prints what a game sends).

## Channel

Reliable and unreliable messages over any number of links (the relay serves its host's in-process client and remote
peers at once), every (link, link peer) pair one channel peer, with the same minimal protocol on every link.

- **Acks.** Every datagram acks the peer's newest seq and a 32-bit history. While a burst arrives the receiver adds
  the older acks (up to `ACK_EXT_WORDS` words more, when they fit) for `ACK_EXT_HOLD_US` after seqs too old for the
  header arrived, so outside a burst they cost nothing.
- **Delivery.** A reliable message rides in datagrams until one carrying it is acked, is resent after 1.5 × the
  smoothed round trip + 15 ms (clamped), and is delivered once, in order. Unreliable ones are delivered as they
  arrive, possibly duplicated or reordered.
- **Bounds.** At most `REL_IN_FLIGHT` datagrams carrying reliable messages are in flight past the peer's newest ack,
  so one ack covers a whole burst (a snapshot): the rest waits for it instead of being resent though it arrived.
  Reliable bytes to a peer are paced by a token bucket (`REL_BURST` at once, refilled at `REL_RATE`): a fixed pace,
  not congestion control, so a burst never floods a home uplink or a default socket buffer. A sender keeps at most
  `REL_WINDOW` reliable messages past its oldest unacked one, and a receiver drops anything further ahead, so a peer
  can't grow the out-of-order buffer at will.
- **Timeouts.** A keepalive keeps idle peers connected. A peer is dropped after `DISCONNECT_US` of silence, or
  `FIRST_ANSWER_US` for one that never answered (a transport like EOS sets up its path after the first hello).
- **Epochs.** Each side's connection has an epoch (a fresh value each time it opens one, never one an earlier
  connection of the process had: a client made again must not read as the old one), sent in every datagram with the
  peer's last one seen. A datagram echoing an epoch other than ours was meant for an earlier connection: it is dropped
  unread while a newer connection runs, and otherwise answered by a new connection, whose epoch ends the
  sender's stale side at once, so no side sits half-open. A new epoch from an active peer means it started over (a
  restarted program on the same address, or on a link that numbers a person, not a socket: EOS): the old connection
  ends with `Disconnected` and the datagram opens the new one. The old connection's messages read in the same poll
  are not delivered: they would reach the new connection, which has its peer number (its Leave would end it).
- **Goodbye.** A connection dropped after a goodbye, or replaced (by the relay, or by the peer starting over), never
  comes back: its last datagram acks the goodbye, and a datagram of it arriving later (a Hello resent before the
  Leave, a duplicate) is never read.
- **Connections.** A channel holds one per seat of the largest game and a few that seat nobody (`MAX_PEERS`): a peer
  being refused, one opened only to tell a peer its connection ended. Without them a full session answers nobody
  else.
- A datagram whose header doesn't validate never gets a connection (or a transport peer number).

## Relay

- **Connections and seats.** The relay keeps two records apart: a **connection** (`Relay_Conn`, by channel peer) is one
  client program, one sim, so it has one stream of finalized ticks, one checksum report per checksum tick, one late
  join with its snapshot; a **seat** (`Seat`, by slot) is one player, a member with their Profile, inputs and
  commands. A connection holds up to `LOCAL_MAX` seats, its **local players** (a couch, or friends on a remote-play
  stream, who arrive as pads on the host's machine); when it goes, every seat it held empties. A snapshot is asked
  for, sent and checked per connection.
- **Local players.** A Hello asks for every seat the client has so far, all or nothing (`Full` and nobody is seated:
  the menu can retry with fewer). A local player added later sends a **Join** on the connection: it gets a join tick as
  a late joiner's and needs no snapshot, since the connection's sim has the session (`Seated` answers, or a `Reject`
  naming that local player). A **Leave** names one local player, whose seat empties at once while the others play on;
  the client's last one, or `ALL_LOCALS`, ends the connection. Each seat sends its own Inputs (so each keeps the whole
  window of loss cover) and each Finalized carries every seat's input and command acks; the widths budget for a full
  couch's (`FINALIZED_HEAD_MAX`).
- **Open and closed.** A relay starts open; closed (`relay_set_open`), a Hello or Join of a person it does not know is
  refused (`Closed`) while the players in stay and one who drops comes back: the gate that works for a UDP socket and
  a lobby alike, keeping every link. Single player is a host with no remote links (`host_solo`), so opening it to
  friends is `host_add_link` on the running host: its relay polls from then on, the first joiner is an ordinary late
  joiner, no timer starts over.
- **Hello** asks for a slot or any free one (slots go lowest-free). The relay checks `compat` (`sim.compat_of`), finds
  who it is (Members) and, once the session runs, someone who can send the joiner a snapshot; `Reject_Reason` names
  each refusal. A Hello while the session ends gets End, not silence.
- **One new player per tick.** A tick carries at most one join record and its Profile: the start players become
  present on ticks 1, 2, ... in slot order, and a late join takes the first tick at or after its join tick on which no
  other seat joins (four players at 64 Hz are all in after 47 ms). So the widest tick has one join, a Profile of up to
  `sim.PROFILE_MAX` bytes is legal at any player count, and the join term never grows with the players. In-memory
  `Inputs` and the input log stay general: an offline run still seats everyone on tick 1.
- **Setup and Profiles.** The relay sends the session's Setup in every Welcome (a start client builds tick 0 with
  it, `Welcome_Flags.Start`; a joiner's snapshot carries it), records it in the log's header, and writes each seat's
  Profile, from its Hello, beside its join record. A Profile of another size than the build's is refused
  (`Incompatible`: only a modified client sends one); what its bytes hold is the sim's to read
  (`src/sim/README.md`, Bytes from another machine), so a client predicts its own join with its own Profile and its
  character is right on its first predicted tick.
- **Start**: the clock starts once the start players have connected: they get Welcome and tick 0 is due
  `START_LEAD_MS` later, so a far start player's inputs for tick 1 arrive in time. The lead covers the path, not a lost
  Welcome: a start player whose Welcome is resent has its first ticks' inputs replaced, a moment of standing still
  that every peer agrees on. During the lead the relay already broadcasts, with a negative relay time. A host's relay
  skips the lead (`Relay_Config.local_start`): its only start player is in-process.
- **Finalizing**: tick T is final once every present player's input for T is in, or the clock reaches T + tolerance
  (`TOLERANCE_MS`), never past the clock while nobody is present. A tick can be final before it is due. A missing
  input repeats the player's last one (`replaced`). Present: connected slots from their join tick; a slot's join tick
  carries its join record (the member seated there).
- **Broadcast**: newly finalized ticks, at most once per `BROADCAST_GAP` of a tick (under jitter each player's input
  arriving can finalize a tick), and a heartbeat when nothing was finalized for a tick (the clients time their clocks
  from it). Each Finalized carries the relay time, the input and command acks, and the client's unacked finalized
  ticks, up to `CATCHUP_TICKS` of them, as many as fit one message (at most `WINDOW_MAX`). When they don't fit, each
  broadcast carries on where the last one stopped and starts again at the oldest once one reached the newest: a
  message of ticks per broadcast, never one per round trip; while that cycle is behind ticks no broadcast carried
  yet, a second message carries them. A client whose unacked ticks have left the ring (`RELAY_RING`) is refused
  (`Too_Far_Behind`).
- **The window** (`window.odin`): Finalized and Inputs write each tick or input as its changes from the one before it
  in the same packet, so every packet decodes on its own. A tick's commands are budgeted so it fits a packet alone
  however much it changed. A client's Inputs carries its newest unacked inputs, as many as fit beside a command with
  every byte changed (`inputs_window`): each input rides in that many packets, whatever the round trip. Inputs the main
  message moved past before they had (a step that generated several at once: the clock's first step samples the input
  delay's ticks; a jump of the delay or the clock; a client stepped late) ride in messages of their own beside it
  until they have, while they can still be in time, so a starved client sends a bounded few per step.

## Members

A player is a session **member**, the person, not a slot (the sim's side: `src/sim/README.md`, Players).

- The relay gives each distinct person a **member id** for the session (1, 2, ...; never reused; once the ids run
  out a newcomer is refused as `Full`) and keeps account-or-token -> member. The **account** comes from the link
  (`Link.account`), never from the client. On a link that vouches for none (LAN, direct UDP) the client's **token** is
  used instead (`Client_Config.token`; the Godot host keeps it in `user://`), never forwarded. Neither: a new member
  every time.
- A connection's local player 0 is its account or token; local player k is `<key>#k`, so each comes back as
  themselves, and each roster entry says which local player it is (`Roster_Entry.local`; a second local player shows
  the first one's account). Newest wins per person: a Hello whose players are seated on a live connection replaces
  that connection, a Join whose player is seated elsewhere empties that seat.
- Accounts and tokens never enter the deterministic stream: a finalized tick (and the log) carries only member ids,
  in the join record of a slot's join tick. Welcome carries the joiner's member id; the client predicts its own join
  record on its first tick.
- **Newest wins**: a Hello from a member who is still seated replaces their old connection once the new one is
  accepted. The slot is absent from the next tick, and the new connection joins as the same member at a later tick, in
  the lowest free slot (its old one counts as free): a restarted game is back at once instead of after the old
  connection's timeout. Newest by when each try's Hello went out (Hello carries its client's clock), not by which
  arrives last: a cancelled try whose Hello comes late (lost once, or on a slower path) is refused
  (`Newer_Connection`) while the seated connection is live, instead of replacing the try its player made next. A
  silent seated connection is replaced whatever the order (a crashed game): one person's tries on one machine share a
  clock, tries from two machines don't, so between two live ones there the order says nothing.
- **The roster** is one reliable `Roster` message per member change (`Roster_Entry`: the vouched account, never a
  token). Everyone connected gets each change; a joiner gets every entry. Departed members' entries stay (not
  connected, no slot): a "left" message can name them after they are gone. The client keeps them by member id
  (`client_member`).

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

- **Stamp lead** `s = ceil((RTT/2 + margin) / tick)` (`stamp_ahead`, the margin `DELAY_MARGIN_US`): an input reaches
  the relay a margin before its tick is due.
- **Input delay** (the lag a player feels) `k = clamp(ceil((RTT⁺ + margin) / tick) + 1 − cap, 1, max delay)`
  (`want_delay`, the ceiling `MAX_DELAY_MS`): the least delay that keeps the prediction depth inside the cap. RTT⁺ =
  RTT + 4 × its mean deviation (jitter). It rises at once and falls a tick per second.
- **The clock**: L runs `s − k` ticks ahead of the relay clock (behind, when negative), slewed ±2% towards it. More
  than 4 ticks behind it catches up at once, a tick at a time (their inputs sampled), and in one jump for anything
  before the last `OWN_RING` ticks; more than 4 ticks ahead it holds. It starts at the first Finalized after Welcome
  (once the relay's start lead is over), timed by the channel's round trip (measured from the Hello's ack on), so a
  joiner's inputs for its join tick arrive in time. Own inputs are sampled for L + k on every clock tick, also while
  the sim is held back: they count, and the view hitches.
- **Cap** (`Timing.prediction_cap`): the most the sim's ring allows. Past the round-trip ceiling
  (`round_trip_ceiling_us`: depth > cap with k at its ceiling) the sim stalls a tick at a time; inputs still arrive in
  time (sent on the clock, each in a window of packets).
- **A game's floor** (`sim.Game.input_delay_min_ticks`): k never goes below it. It buys shallower corrections, not
  fewer: a guess is wrong as often as the inputs change, and each rollback reaches k − 1 ticks less far back. With k
  at or above RTT/tick + ½ the client predicts nothing and steps ticks as they are finalized, so the lag a player feels
  is the smaller of k and a round trip plus a tick.

**How the timing constants hold each other.** Change one of `TOLERANCE_MS`, `MAX_DELAY_MS`, `DELAY_MARGIN_US`, the ring, the input window or a lead, then check each
line below (`tests/netcode/delay_test.odin` and `policy_test.odin` pin them at 32, 64 and 128 Hz).

- *The stamp lead does not depend on k.* An input for tick S leaves when the relay clock is at S − s and arrives the
  margin before S is due, at any k: the delay only moves the client's clock back. The relay sees the same client at
  any delay.
- *The tolerance is spent from the rollback window.* A tick is final only once every present player's input is in, or
  at S + tolerance, so one player's late inputs hold back everyone's verified tick by up to the tolerance. The delay
  policy keeps a client's depth just inside the cap for its own round trip and leaves nothing for that: a client near
  the cap stalls while another's inputs come late. Raising the tolerance saves a lagging player's inputs and costs
  everyone near the cap a stall.
- *The tolerance is also the loss an input survives.* Each input rides in `inputs_window` packets a tick apart, but
  only those that arrive before S + tolerance count: it survives that many lost packets in a row only while they fit
  the tolerance.
- *The round-trip ceiling* is (cap + k_max − 1) ticks less the margin: the delay ceiling adds to it one for one, at
  that much felt lag for the players near it. A game's floor is at most the delay ceiling (`game_violation`), so it
  never moves the ceiling.
- *A burst of own inputs* reaches back the stamp lead plus the tolerance (never less than the window plus the delay
  ceiling): an input older than that arrives after its tick was finalized.
- *The start and join leads* (`START_LEAD_MS`, `JOIN_LEAD_MS`) cover a round trip at the ceiling plus the tolerance:
  Welcome out, the first inputs back. The stamp lead stays well under `INPUT_RING`, the most ticks ahead the relay
  takes an input.

## Client

- Frames: V (newest verified), P (newest predicted), L (the clock). Predicted ticks use own inputs and commands and
  the others' last finalized inputs repeated, or the game's guess from them (`sim.Game.predict_input`; the relay
  still repeats a missing input whatever the game guesses). A finalized tick that differs from its prediction
  (presence, input bytes, commands; `sim.inputs_same`) restores the tick before it and re-simulates to P. What is
  saved for that: `PREDICTED_SAVE_EVERY`.

## Hooks

Every hook is called from `client_step`, on the caller's thread. In one step: `status`, `seat` and `desync` as the
relay's messages arrive; then `verified` for each newly verified tick, in order, and `verified_state` at most once,
while the sim stands on the newest of them; then `sample` and `commands` for each tick the clock generates, once per
seated local player (`local` says which); then `frame` once, when the step computed ticks.

## Commands

The types and how `tick` reads them: `src/sim/README.md`. Each player's commands arrive exactly once, in order.

- **Client:** a command gets the next seq n and a wanted tick W (the tick generated when the hook sent it) and is
  predicted at W. Unacked commands go with every Inputs packet until the relay acks them: the ack means
  **received**, not finalized; the client keeps predicting a command until a verified tick carries it (at W, or the
  first tick not finalized yet once W is, at most `sim.COMMANDS_PER_SLOT` per tick, in order). Others' commands are
  unknown until finalized.
- **Relay:** takes each seq once, in order (a gap waits for the resend; at most `COMMAND_QUEUE` waiting per slot);
  clamps W to finalized + `INPUT_RING`, so a bogus far tick can't hold back the sender's later commands. Finalizing T,
  it puts in each present slot's waiting commands with W ≤ T: at most `sim.COMMANDS_PER_SLOT` per slot and
  `sim.TICK_COMMANDS` per tick, within the bytes that keep a tick alone inside one datagram, round-robin; the rest
  wait for T + 1. A left player's waiting commands go with it. A placement T ≠ W is a misprediction like any other.

## Late join and rejoin

- The joiner's join tick J is the first tick at or after max(asked, clock + `JOIN_LEAD_MS`, finalized + 2) on which no
  other seat joins. The connection holding the lowest slot that can (and didn't send it a bad one) is asked for a
  snapshot of the first checksum tick S ≥ J − 1 it verifies. It goes through the relay in reliable chunks, only from
  the player asked; the finalized ticks from S on are streamed to the joiner. A provider that leaves, sends nothing for `SNAP_STALL_US`, or sends a snapshot the relay can't use is
  replaced by another, asked for a snapshot no older than the one begun (the joiner keeps the finalized ticks it
  holds from it on, and acks of them may reach the relay after the new Snap_Begin). A provider asked again for a seat
  may still be sending its answer to the seat's previous occupant: what it sends before its new answer's Snap_Begin is
  dropped, not held against it (a sign of life while the ticks from the new request's on are in the ring). How long a
  snapshot may take to arrive: `FIN_RING`.
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

- Every client sends the checksum of every `CHECKSUM_EVERY`th verified tick (`sim.DEEP_CHECKSUM_EVERY`: they cover
  every extra's whole state); a joiner from its first checksum tick after S on.
- The relay judges a checksum tick once every connection expected to report it has, or `CHECK_WAIT_MS` after it is
  due: the majority value, one vote per connection, since a connection is one sim whatever its seats (a tie goes to
  the connection holding the lowest slot: with 2 players, the host). The slots of the connections that differ from it
  are a **desync**: counted, logged, and reported to every client (`Desync_Report`); the `desync` hook gets it, the dev UI
  shows it, `session_run`'s `ok` turns false. A late report that differs from a judged tick is reported too.
  Checksums of ticks the relay has not finalized are dropped.
- **Typed reports** (`desync_detail` on the relay or host config; the Godot host turns it on where the dev UI is):
  clients keep their last `DESYNC_IMAGES` checksum ticks (Welcome's `Keep_Images`) as copies (`sim.snapshot_keep`:
  the block and the extra's save, a memcpy), encoded into portable snapshots only when the relay asks, so it costs
  next to nothing unless a desync happens and stays on in every build. On the session's first desync the relay asks
  a majority player and a diverged one for theirs and diffs them (`sim.snapshot_diff`: table by table, field by
  field, then each extra's image): "tick 4160: enemies[12].pos.x 3.25 vs 3.5". Later desyncs are its consequences
  and carry no detail. Every desync report waits for the two snapshots while their bytes keep coming,
  `IMAGE_GIVE_UP_MS` at most; then they go out without the detail, so a slow or crafted client can't keep the others
  from being told.
