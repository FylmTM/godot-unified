// The input relay (src/netcode/SPEC.md, Relay), generic over the game type: only its Input, PLAYERS and tick rate
// matter, it runs no game code. Driven by relay_step from the host's own loop; serves any number of links at once.
package netcode

// Used only inside generic procs: @(require) keeps -vet from calling them unused in a program that never
// instantiates those (a game's tests that run the sim offline only).
@(require) import "base:intrinsics"
@(require) import "core:fmt"
@(require) import "core:log"
@(require) import "core:strings"

import "unified:sim"
import "unified:wire"

Relay_Config :: struct {
	seed:          u64,
	ticks:         u32, // session length; 0: endless
	start_players: int, // slots 0..start_players-1 must connect before the clock starts (>= 1)
	content:       []u8, // the level (nil: the game's own, sim.Game.content): its hash is recorded in the input log, and part of compat
	compat:        u64, // build/game id a Hello must carry (0: sim.compat_of(game, content))
	// Every start player is in-process (a host's own client): tick 1 is due a tick after Welcome. Otherwise
	// the clock starts START_LEAD_MS after Welcome, so a far start player's first inputs arrive in time.
	local_start:   bool,
	// Optional: the session's input log, written tick by tick as ticks are finalized (sim/log.odin's format;
	// sim.log_sink_memory, headless.log_sink_file). The relay owns the sink: relay_end_recording (or relay_destroy)
	// writes the tick count and closes it. Without one, the session is kept only RELAY_RING ticks back.
	recording:     sim.Log_Sink,
	// Typed desync reports (dev builds): clients keep the snapshots of their last checksum ticks, and a desync report
	// carries what differs between two of them (a majority player's and a diverged one's, sim.snapshot_diff).
	desync_detail: bool,
}

RELAY_RING :: 2048 // finalized ticks the relay keeps: a client further behind can't be streamed to (FIN_RING)
#assert(CATCHUP_TICKS < RELAY_RING)
INPUT_RING :: 256
// Checksum ticks whose reports the relay keeps: a joiner's check of its snapshot's tick S may come as late as it can
// be streamed to (FIN_RING - 64 past S, then RELAY_RING more), and must still find the others' reports of S.
CHECK_RING :: 256
#assert(CHECK_RING * CHECKSUM_EVERY >= FIN_RING - 64 + RELAY_RING)
JOIN_LEAD_MS :: 500 // a joiner becomes present this long after the relay clock at its Hello
START_LEAD_MS :: 500 // the clock starts (tick 0 is due) this long after Welcome, unless local_start
BROADCAST_GAP :: 0.75 // ticks at least between two Finalized broadcasts that only carry new ticks (a heartbeat waits a tick)
CHECK_WAIT_MS :: 1000 // a checksum tick is judged once every expected report is in, or this long after it is due
IMAGE_WAIT_MS :: 3000 // how long a typed desync report waits for its two snapshots
SNAP_STALL_US :: 5_000_000 // a joiner's snapshot provider that sends nothing this long is replaced by another
IMAGE_MAX :: 256 << 20 // the largest snapshot the relay takes for a desync report
NO_REPORTS :: max(u32) // Seat.report_from of a slot that sends no checksums yet

// A received command waiting for the tick it goes in.
@(private)
Wait_Command :: struct {
	want: u32, // the tick the sender predicted it at
	cmd:  sim.Raw_Command,
}

// The checksums the slots sent for one checksum tick.
@(private)
Check :: struct($PLAYERS: int) {
	tick:     u32,
	have:     sim.Slots,
	values:   [PLAYERS]u64,
	judged:   bool, // the majority is known (every expected report came in, or CHECK_WAIT_MS passed)
	majority: u64,
}

// A desync, as the relay tells the clients and a client's `desync` hook gets it.
Desync_Report :: struct {
	tick:     u32, // the checksum tick on which the slots disagree
	diverged: sim.Slots, // the slots whose checksum differs from the majority's (with 2 players: from slot 0's)
	detail:   string, // what differs (Relay_Config.desync_detail), or ""
}

// A person of the session: its member id is its index + 1 (never reused).
@(private)
Relay_Member :: struct {
	key:   string, // what recognizes them: "<platform>:<id>" of a vouched account, "token:<hex>", or "" (nothing)
	entry: Roster_Entry, // what the clients get (the account its link vouched for, never the token)
}

// A typed desync report waiting for the snapshots it diffs.
@(private)
Pending_Image :: struct {
	slot:  int,
	image: [dynamic]u8,
	total: u32,
	done:  bool, // complete, or not coming
}

// What the relay keeps per slot: the connection seated there, its inputs and commands, its late join. A seat is
// emptied with one assignment (seat_reset) when its occupant leaves and before a new one sits down, so nothing of a
// previous occupant survives into the next.
Seat :: struct($Input: typeid) {
	peer:        Peer, // -1: nobody
	member:      u16, // the member seated here (NO_MEMBER: none)
	connected:   bool,
	welcomed:    bool,
	done:        bool, // verified the last tick of a fixed-length session
	base_known:  bool, // finalized ticks can be streamed to this client
	active_from: u32, // first tick the slot is present (0: not joined)
	report_from: u32, // the first checksum tick the slot reports (NO_REPORTS: none yet)
	inputs:      [INPUT_RING]Input,
	input_tick:  [INPUT_RING]u32, // which tick inputs[k] holds
	recv_upto:   u32, // every input up to this tick is in
	client_ack:  u32, // the newest finalized tick the client acked
	resume:      u32, // the tick after the last one a broadcast that stopped short carried (0: start at the oldest)
	cmd_recv:    u32, // the command ack: every seq up to this one is received
	cmd_wait:    [dynamic]Wait_Command, // received, not finalized yet, in seq order (its buffer outlives resets)
	// late join: who sends the joiner its snapshot, and the check of the snapshot before the joiner plays
	provider:    int, // -1: none pending
	snap_min:    u32, // the oldest tick the joiner's snapshot may be of
	snap_total:  u32, // bytes of the snapshot being forwarded (from its Snap_Begin)
	snap_sent:   u32, // bytes forwarded so far
	snap_tick:   u32, // the checksum tick the joiner's snapshot is of
	snap_from:   int, // who sent it
	snap_us:     i64, // when the joiner's snapshot last made progress (asked for, begun, a chunk)
	checking:    bool, // the joiner restores it and sends its checksum; the relay compares
	snap_value:  u64, // the joiner's checksum of its restored snapshot
	snap_have:   bool,
	refused:     sim.Slots, // providers whose snapshot for this joiner failed the check, was unusable or never came
}

// The relay, generic over the game type G (only its Input, PLAYERS and tick rate matter).
Relay :: struct($G: typeid) where intrinsics.type_is_specialization_of(G, sim.Game) {
	cfg:                 Relay_Config,
	compat:              u64,
	desync_diff:         proc(a, b: []u8) -> string, // cfg.desync_detail: the game State's snapshot diff
	tm:                  Timing,
	ch:                  ^Channel,
	w:                   wire.Writer,
	poll_us:             i64, // how often relay_step wants to run between deadlines (a host's: none until a remote link)
	seats:               [sim.part(G, sim.GAME_PLAYERS)]Seat(sim.part(G, sim.GAME_INPUT)),
	slot_of:             [MAX_PEERS]int, // a channel peer's slot (-1: none)
	checks:              [CHECK_RING]Check(sim.part(G, sim.GAME_PLAYERS)),
	started:             bool, // Welcome sent to the start players
	welcome_us:          i64,
	lead:                u32, // ticks from Welcome to the clock's tick 0
	beats:               u32, // ticks since Welcome, the lead included
	clock:               u32, // beats - lead (0 during the lead)
	finalized:           u32,
	ring:                [RELAY_RING]sim.Inputs(G), // finalized tick T in ring[T % RELAY_RING]
	recording:           sim.Log_Stream,
	members:             [dynamic]Relay_Member, // every person of the session, by member id - 1
	broadcast_us:        i64, // when the last broadcast went out
	broadcast_to:        u32, // the newest finalized tick when it did
	desyncs:             int, // desync reports (a checksum tick on which some slots differ from the majority)
	reports:             [dynamic]Desync_Report, // waiting to go out while a typed report gathers its snapshots
	pending:             [2]Pending_Image, // the typed report's snapshots: a majority slot's, a diverged one's
	pending_on:          bool,
	pending_tick:        u32,
	pending_us:          i64,
	detailed:            bool, // the session's first desync got its typed report (later ones are its consequences)
	first_desync:        Desync_Report, // the first desync reported (its detail owned by the relay)
	replaced:            int, // inputs that came too late, replaced by the slot's previous one
	// Late joiners let in unchecked: no other player's checksum of their snapshot's tick came (src/netcode/SPEC.md,
	// Late join).
	unchecked_snapshots: int,
	ending:              bool,
	end_us:              i64,
	finished:            bool,
}

// Creates a relay for `game` with no links yet (relay_add_link), starting its recording if cfg has one. The clock
// starts once cfg.start_players have connected.
relay_create :: proc(game: ^$G, cfg: Relay_Config) -> ^Relay(G) {
	State :: sim.part(G, sim.GAME_STATE)
	Input :: sim.part(G, sim.GAME_INPUT)
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	sim.check_wire(Input)
	_ = tick_command_budget(Input, PLAYERS) // asserts a tick with a command fits a datagram
	assert(cfg.start_players >= 1 && cfg.start_players <= PLAYERS)
	relay := new(Relay(G))
	relay.cfg = cfg
	relay.cfg.content = nil // borrowed only here
	relay.compat = cfg.compat != 0 ? cfg.compat : sim.compat_of(game, cfg.content)
	if cfg.desync_detail {
		relay.desync_diff = proc(a, b: []u8) -> string {return sim.snapshot_diff(State, a, b)}
	}
	relay.tm = timing_of(game.tick_hz)
	relay.ch = channel_make()
	relay.w = wire.writer_make(MAX_DATAGRAM)
	relay.poll_us = POLL_US
	for &seat in relay.seats {
		seat_reset(&seat)
		reserve(&seat.cmd_wait, COMMAND_QUEUE)
	}
	for &slot in relay.slot_of {
		slot = -1
	}
	header := sim.Log_Header {
		seed       = cfg.seed,
		content    = sim.content_hash(sim.game_content(game, cfg.content)),
		compat     = relay.compat,
		players    = PLAYERS,
		input_size = size_of(Input),
	}
	sim.log_stream_begin(&relay.recording, cfg.recording, header)
	return relay
}

// Empties a seat (nobody there), keeping only its command buffer.
@(private)
seat_reset :: proc(seat: ^Seat($Input)) {
	waiting := seat.cmd_wait
	clear(&waiting)
	seat^ = {
		peer        = -1,
		provider    = -1,
		report_from = NO_REPORTS,
		cmd_wait    = waiting,
	}
}

// Writes the recording's tick count and closes its sink (once; relay_destroy does it too). False if a write failed.
relay_end_recording :: proc(relay: ^Relay($G)) -> bool {
	return sim.log_stream_end(&relay.recording)
}

// Ends the recording if still open, closes every link the relay owns and frees it.
relay_destroy :: proc(relay: ^Relay($G)) {
	relay_end_recording(relay)
	channel_destroy(relay.ch)
	delete(relay.w.buf)
	for member in relay.members {
		delete(member.key)
	}
	delete(relay.members)
	for &seat in relay.seats {
		delete(seat.cmd_wait)
	}
	for report in relay.reports {
		delete(report.detail)
	}
	delete(relay.reports)
	for &pending in relay.pending {
		delete(pending.image)
	}
	delete(relay.first_desync.detail)
	free(relay)
}

// Adds a transport; the relay owns it from now on. Peers on every link are served alike.
relay_add_link :: proc(relay: ^Relay($G), link: Link) -> int {
	return channel_add_link(relay.ch, link)
}

// A finalized tick's inputs, while the relay keeps it (finalized - RELAY_RING < tick <= finalized; else nil).
relay_tick :: proc(relay: ^Relay($G), tick: u32) -> ^sim.Inputs(G) {
	if tick == 0 || tick > relay.finalized || relay.finalized - tick >= RELAY_RING {
		return nil
	}
	return &relay.ring[tick % RELAY_RING]
}

// Ends the session: every connected client gets End; the relay is finished once they acked it
// (or after 3 s). Keep stepping until relay_finished.
relay_stop :: proc(relay: ^Relay($G), now: i64) {
	if relay.ending {
		return
	}
	for &seat, slot in relay.seats {
		if seat.connected {
			relay_send(relay, slot, msg_begin(&relay.w, .End), .Reliable, now)
		}
	}
	relay.ending = true
	relay.end_us = now
}

// Whether the relay is done: after relay_stop (or the last tick of a fixed-length session), every client acked
// End or 3 s passed. The loop stepping the relay stops on it.
relay_finished :: proc(relay: ^Relay($G)) -> bool {
	return relay.finished
}

@(private)
relay_send :: proc(relay: ^Relay($G), slot: int, writer: ^wire.Writer, delivery: Delivery, now: i64) {
	if peer := relay.seats[slot].peer; peer >= 0 {
		channel_send(relay.ch, peer, writer.buf[:], delivery, now)
	}
}

@(private)
ms_ticks :: proc(relay: ^Relay($G), ms: int) -> u32 {
	return ceil_ticks(f64(ms) * 1000, relay.tm.tick_us)
}

@(private)
send_welcome :: proc(relay: ^Relay($G), slot: int, now: i64) {
	seat := &relay.seats[slot]
	writer := msg_begin(&relay.w, .Welcome)
	wire.w_u8(writer, u8(slot))
	wire.w_u16(writer, seat.member)
	wire.w_u64(writer, relay.cfg.seed)
	wire.w_u16(writer, u16(relay.tm.tick_hz))
	wire.w_u32(writer, relay.cfg.ticks)
	wire.w_u32(writer, seat.active_from)
	flags: Welcome_Flags
	if relay.desync_diff != nil {
		flags += {.Keep_Images}
	}
	wire.w_u8(writer, transmute(u8)flags)
	relay_send(relay, slot, writer, .Reliable, now)
	seat.welcomed = true
}

@(private)
reject :: proc(relay: ^Relay($G), peer: Peer, why: Reject_Reason, now: i64) {
	writer := msg_begin(&relay.w, .Reject)
	wire.w_u8(writer, u8(why))
	channel_send(relay.ch, peer, writer.buf[:], .Reliable, now)
}

// Refuses a slot that is in already (its snapshot failed, it fell too far behind): it gets Reject and is gone.
@(private)
refuse_seat :: proc(relay: ^Relay($G), slot: int, why: Reject_Reason, now: i64) {
	reject(relay, relay.seats[slot].peer, why, now)
	seat_left(relay, slot, fmt.tprintf("refused (%v)", why), now)
}

@(private)
on_hello :: proc(relay: ^Relay($G), peer: Peer, reader: ^wire.Reader, now: i64) {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	wanted := wire.r_u8(reader)
	asked_join_tick := wire.r_u32(reader)
	compat := wire.r_u64(reader)
	token: Token
	copy(token[:], wire.r_bytes(reader, TOKEN_SIZE))
	name := r_text(reader, NAME_MAX)
	if !reader.ok || relay.slot_of[peer] >= 0 {
		return
	}
	if relay.ending {
		channel_send(relay.ch, peer, msg_begin(&relay.w, .End).buf[:], .Reliable, now) // not 30 s of silence
		return
	}
	if compat != relay.compat {
		reject(relay, peer, .Incompatible, now)
		return
	}
	// Who it is: the account the link vouches for, else the client's token (never what the client says it is).
	account, vouched := channel_account(relay.ch, peer)
	vouched &&= account.id != ""
	key := ""
	if vouched {
		key = fmt.tprintf("%s:%s", account.platform, account.id)
	} else if token != {} {
		key = fmt.tprintf("token:%s", token_text(token))
	}
	known := find_member(relay, key)
	// Newest wins: a person still seated who connects again (a restarted game) replaces their old connection, once
	// the new one is accepted (its seat counts as free until then).
	replaced := -1
	if known >= 0 && relay.members[known].entry.connected {
		replaced = int(relay.members[known].entry.slot)
	}
	if known < 0 && len(relay.members) >= int(max(u16)) {
		reject(relay, peer, .Full, now) // 65,535 people in one session
		return
	}
	slot := -1
	if wanted == ANY_SLOT {
		limit := relay.started ? PLAYERS : relay.cfg.start_players
		for other in 0 ..< limit {
			if !relay.seats[other].connected || other == replaced {
				slot = other
				break
			}
		}
		if slot < 0 {
			reject(relay, peer, .Full, now)
			return
		}
	} else {
		slot = int(wanted)
		if slot >= PLAYERS {
			reject(relay, peer, .Full, now)
			return
		}
		if relay.seats[slot].connected && slot != replaced {
			reject(relay, peer, .Slot_Taken, now)
			return
		}
		if !relay.started && slot >= relay.cfg.start_players {
			reject(relay, peer, .Not_Started, now)
			return
		}
	}
	// A joiner starts from another player's snapshot: with nobody to send one, it can't join.
	provider := -1
	if relay.started {
		if provider = pick_provider(relay, slot, {}, replaced); provider < 0 {
			reject(relay, peer, .No_Snapshot, now)
			log.infof("a client asking for slot %d refused: nobody can send it a snapshot", slot)
			return
		}
	}
	if replaced >= 0 {
		old_peer := relay.seats[replaced].peer
		seat_left(relay, replaced, "replaced by a new connection", now)
		channel_drop(relay.ch, old_peer)
	}
	if known < 0 {
		append(&relay.members, Relay_Member{key = strings.clone(key)})
		known = len(relay.members) - 1
		entry := &relay.members[known].entry
		entry.member = u16(known + 1)
		if vouched {
			entry.platform = text_of(PLATFORM_MAX, account.platform)
			entry.account = text_of(ACCOUNT_MAX, account.id)
		}
	}
	entry := &relay.members[known].entry
	entry.name = name
	entry.slot = u8(slot)
	entry.connected = true
	seat := &relay.seats[slot]
	seat_reset(seat) // a new occupant: nothing of the previous one's (inputs, commands, snapshot) carries over
	seat.member = entry.member
	seat.peer = peer
	seat.connected = true
	relay.slot_of[peer] = slot
	send_roster_entry(relay, known, now)
	for k in 0 ..< len(relay.members) {
		if k != known {
			send_roster_entry(relay, k, now, slot)
		}
	}
	if !relay.started {
		seat.active_from = 1
		seat.report_from = 1
		seat.base_known = true
		for other in 0 ..< relay.cfg.start_players {
			if !relay.seats[other].connected {
				return
			}
		}
		relay.started = true
		relay.welcome_us = now
		relay.lead = relay.cfg.local_start ? 0 : ms_ticks(relay, START_LEAD_MS)
		for other in 0 ..< relay.cfg.start_players {
			send_welcome(relay, other, now)
		}
		log.infof("%d players connected, clock started", relay.cfg.start_players)
		return
	}
	// Late join or rejoin: the slot becomes present at a future tick J.
	join_tick := max(asked_join_tick, relay.clock + ms_ticks(relay, JOIN_LEAD_MS), relay.finalized + 2)
	seat.active_from = join_tick
	seat.recv_upto = join_tick - 1
	seat.snap_min = join_tick - 1
	send_welcome(relay, slot, now)
	request_snapshot(relay, slot, provider, now)
	log.infof(
		"member %d joins slot %d at tick %d (clock %d), snapshot from slot %d",
		seat.member,
		slot,
		join_tick,
		relay.clock,
		provider,
	)
}

// The member a key recognizes (-1: none, or no key).
@(private)
find_member :: proc(relay: ^Relay($G), key: string) -> int {
	if key == "" {
		return -1
	}
	for member, k in relay.members {
		if member.key == key {
			return k
		}
	}
	return -1
}

// The lowest connected slot that can send `joiner` a snapshot and isn't in `refused` (-1: none), other than
// `leaving` (a seat about to be replaced).
@(private)
pick_provider :: proc(relay: ^Relay($G), joiner: int, refused: sim.Slots, leaving := -1) -> int {
	for &seat, other in relay.seats {
		if other != joiner &&
		   other != leaving &&
		   seat.connected &&
		   seat.welcomed &&
		   seat.base_known &&
		   !seat.checking &&
		   seat.provider < 0 &&
		   other not_in refused {
			return other
		}
	}
	return -1
}

@(private)
request_snapshot :: proc(relay: ^Relay($G), joiner, provider: int, now: i64) {
	seat := &relay.seats[joiner]
	seat.provider = provider
	seat.snap_total = 0
	seat.snap_sent = 0
	seat.snap_us = now
	writer := msg_begin(&relay.w, .Snap_Request)
	wire.w_u8(writer, u8(joiner))
	wire.w_u32(writer, seat.snap_min)
	relay_send(relay, provider, writer, .Reliable, now)
}

// The joiner's snapshot didn't get through (its provider left) or failed the check: ask another slot, or refuse
// the joiner.
@(private)
restart_snapshot :: proc(relay: ^Relay($G), joiner: int, why: string, now: i64) {
	seat := &relay.seats[joiner]
	seat.provider = -1
	seat.checking = false
	seat.base_known = false
	seat.client_ack = 0
	seat.report_from = NO_REPORTS
	if provider := pick_provider(relay, joiner, seat.refused); provider >= 0 {
		request_snapshot(relay, joiner, provider, now)
		log.infof("slot %d: %s, asking slot %d", joiner, why, provider)
		return
	}
	log.warnf("slot %d: %s, and nobody else can send a snapshot", joiner, why)
	refuse_seat(relay, joiner, card(seat.refused) > 0 ? .Bad_Snapshot : .No_Snapshot, now)
}

@(private)
have_input :: #force_inline proc(seat: ^Seat($Input), tick: u32) -> bool {
	return seat.input_tick[tick % INPUT_RING] == tick
}

@(private)
on_inputs :: proc(relay: ^Relay($G), slot: int, reader: ^wire.Reader, now: i64) {
	Input :: sim.part(G, sim.GAME_INPUT)
	seat := &relay.seats[slot]
	finalized_ack := wire.r_u32(reader)
	first := wire.r_u32(reader)
	count := u32(wire.r_u8(reader))
	if !reader.ok {
		return
	}
	if seat.base_known {
		seat.client_ack = max(seat.client_ack, min(finalized_ack, relay.finalized))
	}
	input: Input // each input as its changes from the one before it, the first from the zero input
	malformed := false
	for k in 0 ..< count {
		if !window_read_input(reader, &input) {
			malformed = true // the inputs after it, and the commands, can't be found
			break
		}
		tick := first + k
		if tick <= relay.finalized ||
		   tick >= relay.finalized + INPUT_RING ||
		   (relay.cfg.ticks != 0 && tick > relay.cfg.ticks) ||
		   tick < seat.active_from ||
		   have_input(seat, tick) {
			continue // late inputs for finalized ticks are dropped; the first copy of a tick wins
		}
		seat.inputs[tick % INPUT_RING] = input
		seat.input_tick[tick % INPUT_RING] = tick
	}
	seat.recv_upto = max(seat.recv_upto, relay.finalized) // a finalized tick's input is no longer waited for
	for have_input(seat, seat.recv_upto + 1) {
		seat.recv_upto += 1
	}
	if malformed {
		return
	}
	// Commands: the sender's unacked ones, from `first_seq` on. Each seq is taken once, in order; one the
	// relay already has (a resend, a duplicate) is skipped.
	first_seq := wire.r_u32(reader)
	command_count := u32(wire.r_u8(reader))
	for k in 0 ..< command_count {
		want := wire.r_u32(reader)
		kind := wire.r_u8(reader)
		size := int(wire.r_u8(reader))
		bytes := wire.r_bytes(reader, size)
		if !reader.ok || size > sim.COMMAND_MAX || size == 0 {
			return
		}
		seq := first_seq + k
		if seq <= seat.cmd_recv {
			continue
		}
		if seq != seat.cmd_recv + 1 || len(seat.cmd_wait) >= COMMAND_QUEUE {
			return // a gap (never from an honest client) or a flood: the rest comes again
		}
		waiting := Wait_Command {
			// a wanted tick far ahead would hold back the sender's later commands: clamp it
			want = min(want, relay.finalized + INPUT_RING),
			cmd = {
				kind = kind,
				slot = u8(slot),
				size = u8(size),
			},
		}
		copy(waiting.cmd.data[:], bytes)
		append(&seat.cmd_wait, waiting)
		seat.cmd_recv = seq
	}
}

@(private)
on_checksum :: proc(relay: ^Relay($G), slot: int, reader: ^wire.Reader, now: i64) {
	seat := &relay.seats[slot]
	tick := wire.r_u32(reader)
	value := wire.r_u64(reader)
	if !reader.ok || tick % CHECKSUM_EVERY != 0 || tick == 0 {
		return
	}
	if seat.checking {
		// A joiner's first checksum is of its restored snapshot; judge_snapshots compares it.
		if tick == seat.snap_tick && !seat.snap_have {
			seat.snap_value = value
			seat.snap_have = true
		}
		return
	}
	if tick < seat.report_from || tick > relay.finalized {
		return // a client verifies only finalized ticks: a later one would take a ring slot no honest report reaches
	}
	check := &relay.checks[(tick / CHECKSUM_EVERY) % CHECK_RING]
	if check.tick != tick {
		if check.tick > tick {
			return // older than the ring keeps
		}
		check^ = {
			tick = tick,
		}
	}
	if check.judged {
		// A late report (a slot catching up): measured against the majority already known.
		if value != check.majority {
			report_desync(relay, tick, {slot}, now)
		}
		return
	}
	check.values[slot] = value
	check.have += {slot}
}

// The slots expected to report `tick`'s checksum: connected, streamed to, past their snapshot check, and
// reporting from that tick on.
@(private)
expected_reports :: proc(relay: ^Relay($G), tick: u32) -> (expected: sim.Slots) {
	for &seat, slot in relay.seats {
		if seat.connected && seat.welcomed && seat.base_known && !seat.checking && seat.report_from <= tick {
			expected += {slot}
		}
	}
	return
}

// Judges the checksum ticks whose reports are in (or waited for long enough): the majority value (ties: the lowest
// slot's, so with 2 players slot 0, the host, wins), and a desync when anyone differs from it.
@(private)
judge_checks :: proc(relay: ^Relay($G), now: i64) {
	wait := ms_ticks(relay, CHECK_WAIT_MS)
	for &check in relay.checks {
		if check.tick == 0 || check.judged {
			continue
		}
		if !(expected_reports(relay, check.tick) <= check.have) && relay.clock < check.tick + wait {
			continue
		}
		check.judged = true
		best := 0
		for slot in check.have {
			votes := 0
			for other in check.have {
				if check.values[other] == check.values[slot] {
					votes += 1
				}
			}
			if votes > best {
				best = votes
				check.majority = check.values[slot]
			}
		}
		diverged: sim.Slots
		for slot in check.have {
			if check.values[slot] != check.majority {
				diverged += {slot}
			}
		}
		if diverged != {} {
			report_desync(relay, check.tick, diverged, now)
		}
	}
}

// The majority's checksum of `tick`, once judged.
@(private)
majority_of :: proc(relay: ^Relay($G), tick: u32) -> (value: u64, judged: bool) {
	check := &relay.checks[(tick / CHECKSUM_EVERY) % CHECK_RING]
	if check.tick != tick || !check.judged || check.have == {} {
		return
	}
	return check.majority, true
}

// Joiners whose restored snapshot's checksum is in: once the others' majority for that tick is known, the joiner
// plays (Snap_Ok) or gets a snapshot from someone else.
@(private)
judge_snapshots :: proc(relay: ^Relay($G), now: i64) {
	wait := ms_ticks(relay, CHECK_WAIT_MS)
	for &seat, joiner in relay.seats {
		if !seat.checking || !seat.snap_have {
			continue
		}
		tick := seat.snap_tick
		majority, judged := majority_of(relay, tick)
		if !judged {
			check := &relay.checks[(tick / CHECKSUM_EVERY) % CHECK_RING]
			if (check.tick == tick || check.tick < tick) && relay.clock < tick + 2 * wait {
				continue // the reports are on their way
			}
			// Nobody reported the tick (or it left the ring): nothing to compare with.
			log.infof("slot %d: snapshot of tick %d not checked: no other checksum of it", joiner, tick)
			majority = seat.snap_value
			relay.unchecked_snapshots += 1
		}
		if seat.snap_value != majority {
			seat.refused += {seat.snap_from}
			restart_snapshot(
				relay,
				joiner,
				fmt.tprintf("the snapshot of tick %d from slot %d differs from the others", tick, seat.snap_from),
				now,
			)
			continue
		}
		seat.checking = false
		seat.report_from = max(seat.active_from, tick + 1)
		writer := msg_begin(&relay.w, .Snap_Ok)
		wire.w_u32(writer, tick)
		relay_send(relay, joiner, writer, .Reliable, now)
	}
}

// A desync on `tick`: counted and logged; told to every client, after the typed report's snapshots (when the
// relay has desync_detail and this is the session's first desync) or at once.
@(private)
report_desync :: proc(relay: ^Relay($G), tick: u32, diverged: sim.Slots, now: i64) {
	relay.desyncs += 1
	log.warnf("DESYNC at tick %d: slots %v differ from the majority", tick, diverged)
	report := Desync_Report {
		tick     = tick,
		diverged = diverged,
	}
	if relay.desyncs == 1 {
		relay.first_desync = report
	}
	if relay.desync_diff != nil && !relay.detailed && !relay.pending_on {
		check := &relay.checks[(tick / CHECKSUM_EVERY) % CHECK_RING]
		majority_slot, diverged_slot := -1, -1
		for slot in check.have {
			if !relay.seats[slot].connected {
				continue
			}
			if slot in diverged && diverged_slot < 0 {
				diverged_slot = slot
			} else if slot not_in diverged && majority_slot < 0 {
				majority_slot = slot
			}
		}
		if check.tick == tick && majority_slot >= 0 && diverged_slot >= 0 {
			relay.detailed = true
			relay.pending_on = true
			relay.pending_tick = tick
			relay.pending_us = now
			for &pending, k in relay.pending {
				clear(&pending.image)
				pending.slot = k == 0 ? majority_slot : diverged_slot
				pending.total = 0
				pending.done = false
				writer := msg_begin(&relay.w, .Snap_Request)
				wire.w_u8(writer, RELAY_TARGET)
				wire.w_u32(writer, tick)
				relay_send(relay, pending.slot, writer, .Reliable, now)
			}
			inject_at(&relay.reports, 0, report) // first in the queue: it goes out with its detail
			return
		}
	}
	append(&relay.reports, report)
}

// Sends the queued desync reports, once a typed report has its snapshots (or gave up waiting for them).
@(private)
send_reports :: proc(relay: ^Relay($G), now: i64) {
	if relay.pending_on {
		if !(relay.pending[0].done && relay.pending[1].done) && now - relay.pending_us < IMAGE_WAIT_MS * 1000 {
			return
		}
		detail := "the snapshots of that tick were not available"
		if relay.pending[0].done && relay.pending[1].done && relay.pending[0].total > 0 && relay.pending[1].total > 0 {
			detail = relay.desync_diff(relay.pending[0].image[:], relay.pending[1].image[:])
			if detail == "" {
				detail = "the two snapshots are the same"
			}
		}
		relay.reports[0].detail = strings.clone(detail)
		if relay.first_desync.tick == relay.reports[0].tick && relay.first_desync.detail == "" {
			relay.first_desync.detail = strings.clone(detail)
		}
		log.warnf("desync at tick %d: %s", relay.reports[0].tick, detail)
		relay.pending_on = false
		for &pending in relay.pending {
			delete(pending.image)
			pending.image = nil
		}
	}
	for &report in relay.reports {
		writer := msg_begin(&relay.w, .Desync)
		wire.w_u32(writer, report.tick)
		wire.w_u32(writer, transmute(u32)report.diverged)
		detail := report.detail[:min(len(report.detail), MAX_MESSAGE - len(writer.buf) - 2)]
		wire.w_u16(writer, u16(len(detail)))
		wire.w_bytes(writer, transmute([]u8)detail)
		for &seat, slot in relay.seats {
			if seat.connected && seat.welcomed {
				relay_send(relay, slot, writer, .Reliable, now)
			}
		}
		delete(report.detail)
	}
	clear(&relay.reports)
}

// A typed desync report's snapshot coming in from one of the two slots asked.
@(private)
take_image :: proc(relay: ^Relay($G), slot: int, kind: Msg, reader: ^wire.Reader) {
	if !relay.pending_on {
		return
	}
	for &pending in relay.pending {
		if pending.slot != slot || pending.done {
			continue
		}
		if kind == .Snap_Begin {
			tick := wire.r_u32(reader)
			total := wire.r_u32(reader)
			if !reader.ok {
				return
			}
			pending.total = tick == relay.pending_tick && total <= IMAGE_MAX ? total : 0
			clear(&pending.image)
			pending.done = pending.total == 0
			return
		}
		offset := wire.r_u32(reader)
		bytes := reader.data[reader.pos:]
		if !reader.ok ||
		   pending.total == 0 ||
		   int(offset) != len(pending.image) ||
		   u32(len(bytes)) > pending.total - offset {
			return
		}
		append(&pending.image, ..bytes)
		pending.done = u32(len(pending.image)) == pending.total
		return
	}
}

@(private)
active :: #force_inline proc(seat: ^Seat($Input), tick: u32) -> bool {
	return seat.active_from != 0 && tick >= seat.active_from && seat.connected
}

@(private)
finalize :: proc(relay: ^Relay($G)) {
	for relay.cfg.ticks == 0 || relay.finalized < relay.cfg.ticks {
		tick := relay.finalized + 1
		anyone := false
		for &seat in relay.seats {
			if !active(&seat, tick) {
				continue
			}
			anyone = true
			if !have_input(&seat, tick) && relay.clock < tick + relay.tm.tolerance {
				return
			}
		}
		if !anyone && tick > relay.clock {
			return // nobody plays: empty ticks keep pace with the clock, never run ahead of it
		}
		tick_inputs := &relay.ring[tick % RELAY_RING]
		previous := relay_tick(relay, tick - 1)
		tick_inputs^ = {}
		for &seat, slot in relay.seats {
			if !active(&seat, tick) {
				continue
			}
			tick_inputs.present += {slot}
			if tick == seat.active_from {
				tick_inputs.joins[slot] = seat.member // the join record
			}
			if have_input(&seat, tick) {
				tick_inputs.input[slot] = seat.inputs[tick % INPUT_RING]
			} else {
				if previous != nil && slot in previous.present {
					tick_inputs.input[slot] = previous.input[slot]
				} // else just joined: there is no previous input to repeat
				tick_inputs.replaced += {slot}
				relay.replaced += 1
			}
		}
		take_commands(relay, tick, tick_inputs)
		sim.log_stream_tick(&relay.recording, tick_inputs)
		relay.finalized = tick
	}
}

// Puts the waiting commands that are due into `tick`: each present slot's in seq order, those sent for
// it or earlier, at most COMMANDS_PER_SLOT each and TICK_COMMANDS in all, within the bytes a tick may
// carry (round-robin over the slots, so one can't crowd the others out). The rest wait for the next tick.
@(private)
take_commands :: proc(relay: ^Relay($G), tick: u32, tick_inputs: ^sim.Inputs(G)) {
	Input :: sim.part(G, sim.GAME_INPUT)
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	taken: [PLAYERS]int
	total, bytes := 0, 0
	budget := tick_command_budget(Input, PLAYERS)
	for k in 0 ..< sim.COMMANDS_PER_SLOT {
		for &seat, slot in relay.seats {
			waiting := &seat.cmd_wait
			if taken[slot] != k || k >= len(waiting) || !active(&seat, tick) || waiting[k].want > tick {
				continue
			}
			size := sim.COMMAND_HEAD + int(waiting[k].cmd.size)
			if total == sim.TICK_COMMANDS || bytes + size > budget {
				continue
			}
			taken[slot] += 1
			total += 1
			bytes += size
		}
	}
	if total == 0 {
		return
	}
	for &seat, slot in relay.seats {
		for k in 0 ..< taken[slot] {
			tick_inputs.commands[tick_inputs.command_count] = seat.cmd_wait[k].cmd
			tick_inputs.command_count += 1
		}
		remove_range(&seat.cmd_wait, 0, taken[slot])
	}
}

@(private)
broadcast :: proc(relay: ^Relay($G), now: i64) {
	relay.broadcast_us = now
	relay.broadcast_to = relay.finalized
	for &seat, slot in relay.seats {
		if !seat.welcomed || !seat.connected {
			continue
		}
		writer := msg_begin(&relay.w, .Finalized)
		// Relay time: when tick 0 was due, so negative during the lead.
		w_i64(writer, i64(f64(now - relay.welcome_us) - f64(relay.lead) * relay.tm.tick_us))
		wire.w_u32(writer, max(seat.recv_upto, relay.finalized))
		wire.w_u32(writer, seat.cmd_recv)
		first := seat.client_ack + 1
		last := first - 1
		newest := last // the newest tick this client is streamed
		if seat.base_known {
			// The unacked ticks, up to CATCHUP_TICKS of them. When they don't fit one message (WINDOW_MAX ticks, or
			// MAX_MESSAGE bytes), each broadcast carries on where the one before stopped, and starts again at the
			// oldest once one reached the newest: the client gets a message of ticks per broadcast, not one per round
			// trip (its ack is what moves the oldest).
			newest = min(relay.finalized, seat.client_ack + CATCHUP_TICKS)
			if seat.resume > first && seat.resume <= newest {
				first = seat.resume
			}
			last = min(newest, first + WINDOW_MAX - 1)
		}
		wire.w_u32(writer, first)
		count_at := len(writer.buf)
		assert(count_at + 1 == FINALIZED_HEAD)
		wire.w_u8(writer, 0)
		written: u32 = 0
		base: ^sim.Inputs(G) // the tick before in this packet (nil: the empty tick)
		for tick := first; tick <= last; tick += 1 {
			tick_inputs := relay_tick(relay, tick)
			if tick_inputs == nil {
				break
			}
			// Ticks with commands or many changes are larger: stop at the message limit (every tick alone
			// fits, see tick_command_budget), the rest goes in the next broadcast.
			before := len(writer.buf)
			window_write_tick(writer, tick_inputs, base)
			if len(writer.buf) > MAX_MESSAGE {
				resize(&writer.buf, before)
				break
			}
			base = tick_inputs
			written += 1
		}
		writer.buf[count_at] = u8(written)
		seat.resume = first + written <= newest ? first + written : 0
		relay_send(relay, slot, writer, .Unreliable, now)
	}
}

// Sends a member's roster entry to every connected client (or only to slot `to`).
@(private)
send_roster_entry :: proc(relay: ^Relay($G), member: int, now: i64, to := -1) {
	writer := msg_begin(&relay.w, .Roster)
	w_roster_entry(writer, &relay.members[member].entry)
	for &seat, slot in relay.seats {
		if seat.connected && (to < 0 || to == slot) {
			relay_send(relay, slot, writer, .Reliable, now)
		}
	}
}

// The seat's occupant is gone (left, disconnected, refused, replaced): the seat is emptied, the member's roster entry
// says so, and a joiner it was sending a snapshot to asks someone else.
@(private)
seat_left :: proc(relay: ^Relay($G), slot: int, why: string, now: i64) {
	seat := &relay.seats[slot]
	member := int(seat.member)
	if seat.peer >= 0 {
		relay.slot_of[seat.peer] = -1
	}
	seat_reset(seat) // a left player's commands that never reached a tick go with it
	log.infof("member %d (slot %d) %s", member, slot, why)
	if member != int(NO_MEMBER) {
		entry := &relay.members[member - 1].entry
		entry.slot = NO_SLOT
		entry.connected = false
		send_roster_entry(relay, member - 1, now) // the entry stays: a "left" message can still name them
	}
	for &pending in relay.pending {
		if relay.pending_on && pending.slot == slot {
			pending.done = true
		}
	}
	for &other, joiner in relay.seats {
		if other.provider == slot && other.connected {
			restart_snapshot(relay, joiner, fmt.tprintf("snapshot provider %d left", slot), now)
		}
	}
}

@(private)
handle_relay_msg :: proc(relay: ^Relay($G), peer: Peer, data: []u8, now: i64) {
	// A message of a connection that ended earlier in this poll (a Leave before it in one datagram, a new epoch's
	// Hello after the old one's Leave): nothing behind it to seat or answer. A Hello dropped here is reliable and
	// comes again on the peer's new connection.
	if !channel_connected(relay.ch, peer) {
		return
	}
	reader := wire.reader_make(data)
	kind := Msg(wire.r_u8(&reader))
	if kind == .Hello {
		on_hello(relay, peer, &reader, now)
		return
	}
	slot := relay.slot_of[peer]
	if slot < 0 {
		return
	}
	#partial switch kind {
	case .Inputs:
		on_inputs(relay, slot, &reader, now)
	case .Checksum:
		on_checksum(relay, slot, &reader, now)
	case .Snap_Begin, .Snap_Chunk:
		forward_snapshot(relay, slot, kind, &reader, data, now)
	case .Done:
		relay.seats[slot].done = true
	case .Leave:
		seat_left(relay, slot, "left", now)
		channel_drop(relay.ch, peer)
	}
}

// Forwards a snapshot message from the provider the relay asked (anything else is dropped), or takes a desync
// report's snapshot.
@(private)
forward_snapshot :: proc(relay: ^Relay($G), slot: int, kind: Msg, reader: ^wire.Reader, data: []u8, now: i64) {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	target := wire.r_u8(reader)
	if reader.ok && target == RELAY_TARGET {
		take_image(relay, slot, kind, reader)
		return
	}
	joiner := int(target)
	if !reader.ok ||
	   joiner >= PLAYERS ||
	   relay.seats[joiner].peer < 0 ||
	   relay.seats[joiner].provider != slot ||
	   len(data) > MAX_MESSAGE {
		return
	}
	seat := &relay.seats[joiner]
	if kind == .Snap_Begin {
		tick := wire.r_u32(reader)
		total := wire.r_u32(reader)
		// A snapshot of a checksum tick (the joiner's checksum of it is compared with the others'), still in the
		// ring (the ticks after it are streamed from there).
		if !reader.ok ||
		   tick < seat.snap_min ||
		   tick % CHECKSUM_EVERY != 0 ||
		   relay_tick(relay, tick) == nil ||
		   total == 0 {
			seat.refused += {slot} // it would send the same again: ask another slot
			restart_snapshot(
				relay,
				joiner,
				fmt.tprintf("slot %d's snapshot of tick %d is not usable", slot, tick),
				now,
			)
			return
		}
		seat.snap_us = now
		seat.snap_total = total
		seat.snap_sent = 0
		seat.snap_tick = tick
		// A snapshot that replaces this one is never older: the joiner keeps the finalized ticks streamed to it from
		// here on, and acks of them may still be on their way when the next Snap_Begin is forwarded.
		seat.snap_min = tick
		seat.snap_from = slot
		seat.snap_have = false
		// Stream finalized ticks from the snapshot's tick on (that tick's inputs seed the joiner's
		// prediction of the others).
		seat.client_ack = tick - 1
		seat.base_known = true
		log.infof("forwarding slot %d's snapshot of tick %d to slot %d", slot, tick, joiner)
	} else {
		offset := wire.r_u32(reader)
		size := u32(len(reader.data) - reader.pos)
		if !reader.ok || seat.snap_total == 0 || offset != seat.snap_sent || size > seat.snap_total - offset {
			return
		}
		seat.snap_sent += size
		seat.snap_us = now
		if seat.snap_sent == seat.snap_total {
			// Complete: the joiner restores it and sends its checksum, which judge_snapshots checks.
			seat.provider = -1
			seat.checking = true
		}
	}
	channel_send(relay.ch, seat.peer, data, .Reliable, now)
}

// One step of the relay: receive, advance the clock, finalize, broadcast, judge checksums, flush. Returns when it
// wants to run next (a now_us value): the next clock tick, or sooner to poll the links.
relay_step :: proc(relay: ^Relay($G), now: i64) -> (wake_us: i64) {
	for event in channel_poll(relay.ch, now) {
		switch event.kind {
		case .Connected, .Incompatible:
		case .Disconnected:
			if slot := relay.slot_of[event.peer]; slot >= 0 {
				seat_left(relay, slot, "disconnected", now)
			}
		case .Message:
			handle_relay_msg(relay, event.peer, event.data, now)
		}
	}
	if relay.started && !relay.finished {
		relay.beats = u32(f64(now - relay.welcome_us) / relay.tm.tick_us)
		relay.clock = relay.beats > relay.lead ? relay.beats - relay.lead : 0
		finalize(relay)
		// A client whose unacked ticks left the ring can't be streamed to any more.
		for &seat, slot in relay.seats {
			if seat.connected && seat.base_known && relay.finalized - seat.client_ack > RELAY_RING {
				refuse_seat(relay, slot, .Too_Far_Behind, now)
			}
		}
		if broadcast_due(relay, now) {
			broadcast(relay, now)
		}
		judge_checks(relay, now)
		judge_snapshots(relay, now)
		for &seat, joiner in relay.seats {
			if provider := seat.provider; provider >= 0 && now - seat.snap_us > SNAP_STALL_US {
				seat.refused += {provider}
				restart_snapshot(relay, joiner, fmt.tprintf("no snapshot from slot %d", provider), now)
			}
		}
		send_reports(relay, now)
	}
	if !relay.ending && relay.started && relay.cfg.ticks != 0 && relay.finalized == relay.cfg.ticks {
		all_done := true
		for &seat in relay.seats {
			if seat.welcomed && seat.connected && !seat.done {
				all_done = false
			}
		}
		if all_done {
			relay_stop(relay, now)
		}
	}
	channel_flush(relay.ch, now)
	if relay.ending && !relay.finished {
		idle := true
		for &seat in relay.seats {
			if seat.peer >= 0 && !channel_idle(relay.ch, seat.peer) {
				idle = false
			}
		}
		relay.finished = idle || now - relay.end_us > 3_000_000
	}
	wake_us = now + relay.poll_us
	if relay.started {
		wake_us = min(wake_us, relay.welcome_us + i64(f64(relay.beats + 1) * relay.tm.tick_us) + 1)
		if relay.finalized != relay.broadcast_to {
			wake_us = min(wake_us, relay.broadcast_us + i64(BROADCAST_GAP * relay.tm.tick_us) + 1) // a held broadcast
		}
	}
	return
}

// Whether the Finalized broadcast goes out now: newly finalized ticks, at most once per BROADCAST_GAP (under jitter
// the players' inputs arrive apart and each arrival can finalize a tick), and a heartbeat when nothing was finalized
// for a tick (during the lead too: the clients time their clocks from these).
@(private)
broadcast_due :: proc(relay: ^Relay($G), now: i64) -> bool {
	since := f64(now - relay.broadcast_us)
	return(
		since >= relay.tm.tick_us ||
		(relay.finalized != relay.broadcast_to && since >= BROADCAST_GAP * relay.tm.tick_us) \
	)
}
