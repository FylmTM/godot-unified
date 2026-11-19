// The input relay (src/netcode/README.md, Relay), generic over the game type: only its Input, PLAYERS and tick rate
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

// A relay's session (relay_create) of game G: its seed, Setup, length, start players and build id, and the optional
// recording and typed desync reports. Written as a literal at the call (`relay_create(&GAME, {seed = 7})`).
Relay_Config :: struct($G: typeid) {
	seed:          u64,
	setup:         Maybe(sim.part(G, sim.GAME_SETUP)), // the session's Setup, sent in Welcome (nil: the game's, Game.setup)
	ticks:         u32, // session length; 0: endless
	start_players: int, // slots 0..start_players-1 must connect before the clock starts (>= 1)
	compat:        u64, // build/game id a Hello must carry (0: sim.compat_of(game))
	// Every start player is in-process (a host's own client): tick 1 is due a tick after Welcome. Otherwise
	// the clock starts START_LEAD_MS after Welcome, so a far start player's first inputs arrive in time.
	local_start:   bool,
	// Optional: the session's input log, written tick by tick as ticks are finalized (sim/log.odin's format;
	// sim.log_sink_memory, headless.log_sink_file). The relay owns the sink: relay_end_recording (or relay_destroy)
	// writes the tick count and closes it; a recording that never ended still reads to its last tick. Without one, the
	// session is kept only RELAY_RING ticks back. A shipped game leaves it off, or records to disk as an opt-in for bug
	// reports.
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
IMAGE_WAIT_MS :: 3000 // how long a typed desync report waits for its two snapshots to make progress (asked, bytes)
// The most a typed desync report waits for its snapshots in all (30 MB at REL_RATE): past it the queued reports go
// out without the detail, so no client can hold the desync reports back by sending slowly.
IMAGE_GIVE_UP_MS :: 30_000
SNAP_STALL_US :: 5_000_000 // a joiner's snapshot provider that sends nothing this long is replaced by another
// A seated connection heard from within this long (4 keepalives) is live: an earlier try's Hello of the same person
// doesn't replace it (on_hello).
SEATED_LIVE_US :: 4 * KEEPALIVE_US
IMAGE_MAX :: 256 << 20 // the largest snapshot the relay takes for a desync report
NO_REPORTS :: max(u32) // Conn.report_from of a connection that sends no checksums yet

// A received command waiting for the tick it goes in.
@(private)
Wait_Command :: struct {
	want: u32, // the tick the sender predicted it at
	cmd:  sim.Raw_Command,
}

// A set of connections, by channel peer (Relay_Conn.refused).
Peers :: bit_set[0 ..< MAX_PEERS;u64]

// The checksums the connections sent for one checksum tick: one vote per connection (one sim), whatever its seats.
@(private)
Check :: struct {
	tick:     u32,
	have:     Peers,
	values:   [MAX_PEERS]u64,
	slots:    [MAX_PEERS]sim.Slots, // each reporting connection's slots when it reported (a desync names them)
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
	conn:  Peer, // whom it is asked of
	image: [dynamic]u8,
	total: u32,
	done:  bool, // complete, or not coming
}

// What the relay keeps per client connection (relay.conns, by channel peer): one sim, so one stream of finalized
// ticks and its acks, one checksum report per checksum tick, one late join with its snapshot, and the seats it holds
// (src/netcode/README.md, Relay: Connections and seats). Emptied with one assignment (relay_conn_reset) when it ends.
Relay_Conn :: struct {
	connected:   bool,
	welcomed:    bool,
	done:        bool, // verified the last tick of a fixed-length session
	base_known:  bool, // finalized ticks can be streamed to this client
	hello_us:    i64, // its Hello's sent time (the client's clock): newest wins by it (on_hello)
	token:       Token, // its Hello's: who its local players are on a link that vouches for no account (a Join's key)
	locals:      [LOCAL_MAX]i8, // the slot each of its local players holds (-1: none)
	report_from: u32, // the first checksum tick it reports (NO_REPORTS: none yet)
	client_ack:  u32, // the newest finalized tick the client acked
	resume:      u32, // the tick after the last one a broadcast that stopped short carried (0: start at the oldest)
	sent_upto:   u32, // the newest tick a broadcast carried to this client (from its snapshot's on)
	// late join: who sends the joiner its snapshot, and the check of the snapshot before the joiner plays
	provider:    Peer, // the connection asked for it (-1: none pending)
	snap_min:    u32, // the oldest tick the joiner's snapshot may be of
	snap_total:  u32, // bytes of the snapshot being forwarded (from its Snap_Begin)
	snap_sent:   u32, // bytes forwarded so far
	snap_tick:   u32, // the checksum tick the joiner's snapshot is of
	snap_from:   Peer, // who sent it
	snap_us:     i64, // when the joiner's snapshot last made progress (asked for, begun, a chunk)
	checking:    bool, // the joiner restores it and sends its checksum; the relay compares
	snap_value:  u64, // the joiner's checksum of its restored snapshot
	snap_have:   bool,
	refused:     Peers, // providers whose snapshot for this joiner failed the check, was unusable or never came
	bad_check:   bool, // a snapshot for this joiner failed the check (refused: Bad_Snapshot, else No_Snapshot)
}

// What the relay keeps per slot: who sits there (a connection's local player), their Profile, inputs and commands. A
// seat is emptied with one assignment (seat_reset) when its occupant leaves and before a new one sits down, so nothing
// of a previous occupant survives into the next.
Seat :: struct($Input, $Profile: typeid) {
	conn:        Peer, // the connection seated here (-1: nobody)
	local:       u8, // which of its local players
	member:      u16, // the member seated here (NO_MEMBER: none)
	profile:     Profile, // what its Hello brought: written beside its join record
	active_from: u32, // first tick the slot is present (0: not joined)
	inputs:      [INPUT_RING]Input,
	input_tick:  [INPUT_RING]u32, // which tick inputs[k] holds
	recv_upto:   u32, // every input up to this tick is in
	cmd_recv:    u32, // the command ack: every seq up to this one is received
	cmd_wait:    [dynamic]Wait_Command, // received, not finalized yet, in seq order (its buffer outlives resets)
}

// The relay, generic over the game type G (only its Input, PLAYERS and tick rate matter).
Relay :: struct($G: typeid) where intrinsics.type_is_specialization_of(G, sim.Game) {
	cfg:                 Relay_Config(G),
	setup:               sim.part(G, sim.GAME_SETUP), // the session's: what every client creates its sim with
	compat:              u64,
	desync_diff:         proc(a, b: []u8) -> string, // cfg.desync_detail: the game State's snapshot diff
	tm:                  Timing,
	ch:                  ^Channel,
	w:                   wire.Writer,
	poll_us:             i64, // how often relay_step wants to run between deadlines (a host's: none until a remote link)
	seats:               [sim.part(
		G,
		sim.GAME_PLAYERS,
	)]Seat(sim.part(G, sim.GAME_INPUT), sim.part(G, sim.GAME_PROFILE)),
	conns:               [MAX_PEERS]Relay_Conn, // by channel peer
	checks:              [CHECK_RING]Check,
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
	pending:             [2]Pending_Image, // the typed report's snapshots: a majority connection's, a diverged one's
	pending_on:          bool,
	pending_tick:        u32,
	pending_us:          i64, // when the typed report last made progress (asked, an answer or bytes of one came)
	pending_from:        i64, // when the typed report asked for its snapshots
	detailed:            bool, // the session's first desync got its typed report (later ones are its consequences)
	first_desync:        Desync_Report, // the first desync reported (its detail owned by the relay)
	replaced:            int, // inputs that came too late, replaced by the slot's previous one
	// Late joiners let in unchecked: no other player's checksum of their snapshot's tick came (src/netcode/README.md,
	// Late join and rejoin).
	unchecked_snapshots: int,
	ending:              bool,
	end_us:              i64,
	finished:            bool,
}

// Creates a relay for `game` with no links yet (relay_add_link), starting its recording if cfg has one. The clock
// starts once cfg.start_players have connected. Panics on a Setup that does not read as sent (sim.setup_violation).
relay_create :: proc(game: ^$G, cfg: Relay_Config(G)) -> ^Relay(G) {
	State :: sim.part(G, sim.GAME_STATE)
	Input :: sim.part(G, sim.GAME_INPUT)
	Profile :: sim.part(G, sim.GAME_PROFILE)
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	sim.check_wire(Input)
	if reason := game_violation(game); reason != "" {
		panic(reason)
	}
	_ = tick_command_budget(Input, PLAYERS, size_of(Profile)) // asserts a tick with a command fits a datagram
	assert(cfg.start_players >= 1 && cfg.start_players <= PLAYERS)
	relay := new(Relay(G))
	relay.cfg = cfg
	relay.setup = cfg.setup.? or_else game.setup
	if reason := sim.setup_violation(game, &relay.setup); reason != "" {
		panic(fmt.tprintf("%s: the session's Setup %s", game.name, reason))
	}
	relay.compat = cfg.compat != 0 ? cfg.compat : sim.compat_of(game)
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
	for &conn in relay.conns {
		relay_conn_reset(&conn)
	}
	header := sim.log_header(game, cfg.seed, &relay.setup, sim.content_hash(game.levels), relay.compat)
	sim.log_stream_begin(&relay.recording, cfg.recording, header)
	return relay
}

// Empties a seat (nobody there), keeping only its command buffer.
@(private)
seat_reset :: proc(seat: ^Seat($Input, $Profile)) {
	waiting := seat.cmd_wait
	clear(&waiting)
	seat^ = {
		conn     = -1,
		cmd_wait = waiting,
	}
}

// Empties a connection's record (no client there).
@(private)
relay_conn_reset :: proc(conn: ^Relay_Conn) {
	conn^ = {
		locals      = -1,
		provider    = -1,
		snap_from   = -1,
		report_from = NO_REPORTS,
	}
}

// The connection seated in `slot` (nil: nobody), for tests and tools that look at a player's stream or late join.
relay_conn :: proc(relay: ^Relay($G), slot: int) -> ^Relay_Conn {
	peer := relay.seats[slot].conn
	return &relay.conns[peer] if peer >= 0 else nil
}

// The lowest slot a connection holds (-1: none): what a log line and a Snap_Request's target name it by.
@(private)
conn_slot :: proc(relay: ^Relay($G), peer: Peer) -> int {
	lowest := -1
	for slot in relay.conns[peer].locals {
		if slot >= 0 && (lowest < 0 || int(slot) < lowest) do lowest = int(slot)
	}
	return lowest
}

// The slots a connection holds.
@(private)
conn_slots :: proc(relay: ^Relay($G), peer: Peer) -> (slots: sim.Slots) {
	for slot in relay.conns[peer].locals {
		if slot >= 0 do slots += {int(slot)}
	}
	return
}

// The connections that hold a seat, in the order of their lowest slots (the host's first): the order a provider is
// picked in and a checksum tie is broken by.
@(private)
conns_by_slot :: proc(relay: ^Relay($G)) -> (order: [MAX_PEERS]Peer, count: int) {
	seen: Peers
	for &seat in relay.seats {
		if seat.conn >= 0 && int(seat.conn) not_in seen {
			seen += {int(seat.conn)}
			order[count] = seat.conn
			count += 1
		}
	}
	return
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
	for &conn, peer in relay.conns {
		if conn.connected {
			relay_send(relay, Peer(peer), msg_begin(&relay.w, .End), .Reliable, now)
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

// Sends a message to a client connection (nothing when it has none).
@(private)
relay_send :: proc(relay: ^Relay($G), peer: Peer, writer: ^wire.Writer, delivery: Delivery, now: i64) {
	if peer >= 0 && relay.conns[peer].connected {
		channel_send(relay.ch, peer, writer.buf[:], delivery, now)
	}
}

@(private)
ms_ticks :: proc(relay: ^Relay($G), ms: int) -> u32 {
	return ceil_ticks(f64(ms) * 1000, relay.tm.tick_us)
}

// Welcomes a connection: the session's seed, rate, length and Setup, and every seat it holds. `start`: a start client,
// which builds tick 0 itself (Welcome_Flags.Start); every other gets a snapshot.
@(private)
send_welcome :: proc(relay: ^Relay($G), peer: Peer, start: bool, now: i64) {
	conn := &relay.conns[peer]
	welcome := Welcome {
		seed    = relay.cfg.seed,
		tick_hz = relay.tm.tick_hz,
		ticks   = relay.cfg.ticks,
		setup   = sim.bytes_of(&relay.setup),
	}
	for slot in conn.locals {
		if slot < 0 do continue
		seat := &relay.seats[slot]
		welcome.seats[welcome.seat_count] = {
			local      = seat.local,
			slot       = u8(slot),
			member     = seat.member,
			first_tick = seat.active_from,
		}
		welcome.seat_count += 1
	}
	if relay.desync_diff != nil do welcome.flags += {.Keep_Images}
	if start do welcome.flags += {.Start}
	clear(&relay.w.buf)
	write_welcome(&relay.w, &welcome)
	relay_send(relay, peer, &relay.w, .Reliable, now)
	conn.welcomed = true
}

// The first tick at or after `from` on which no seat joins: the relay seats one new player per tick, so a tick carries
// at most one join record and its Profile (the widest tick stays bounded, src/netcode/README.md, Relay).
@(private)
free_join_tick :: proc(relay: ^Relay($G), from: u32) -> u32 {
	tick := from
	for taken := true; taken; {
		taken = false
		for &seat in relay.seats {
			if seat.conn >= 0 && seat.active_from == tick {
				taken = true
				tick += 1
				break
			}
		}
	}
	return tick
}

// Refuses a Hello (`local` ALL_LOCALS: the whole connection) or one Join (that local player only).
@(private)
reject :: proc(relay: ^Relay($G), peer: Peer, why: Reject_Reason, now: i64, local := ALL_LOCALS) {
	writer := msg_begin(&relay.w, .Reject)
	wire.w_u8(writer, u8(why))
	wire.w_u8(writer, local)
	channel_send(relay.ch, peer, writer.buf[:], .Reliable, now)
}

// Refuses a connection that is in already (its snapshot failed, it fell too far behind): it gets Reject and is gone,
// with every seat it held.
@(private)
refuse_conn :: proc(relay: ^Relay($G), peer: Peer, why: Reject_Reason, now: i64) {
	reject(relay, peer, why, now)
	conn_left(relay, peer, fmt.tprintf("refused (%v)", why), now)
}

// A client's Hello: every seat it asks for fits, or it is refused whole (Reject, ALL_LOCALS) and nobody is seated.
@(private)
on_hello :: proc(relay: ^Relay($G), peer: Peer, reader: ^wire.Reader, now: i64) {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	hello, hello_ok := read_hello(reader)
	if !hello_ok || relay.conns[peer].connected {
		return
	}
	if relay.ending {
		channel_send(relay.ch, peer, msg_begin(&relay.w, .End).buf[:], .Reliable, now) // not 30 s of silence
		return
	}
	asks := hello.seats[:hello.seat_count]
	if hello.compat != relay.compat || !asks_valid(relay, asks) {
		reject(relay, peer, .Incompatible, now)
		return
	}
	base := client_key(relay, peer, hello.token)
	known: [LOCAL_MAX]int
	// Newest wins: a person still seated who connects again (a restarted game) replaces their old connection, once
	// the new one is accepted (its seats count as free until then). Newest by when each try's Hello went out, not by
	// which arrives last: an earlier try's Hello that comes late (lost once and resent, or on a slower path; its
	// player cancelled it and tried again) is refused while the seated connection is live. A silent one is
	// replaced whatever the order (a crashed game; another machine, whose clock says nothing about this one's).
	replaced: Peers
	new_members := 0
	for &ask, i in asks {
		known[i] = find_member(relay, member_key(base, ask.local))
		if known[i] < 0 {
			new_members += 1
			continue
		}
		if !relay.members[known[i]].entry.connected do continue
		seated := relay.seats[relay.members[known[i]].entry.slot].conn
		if hello.sent_us < relay.conns[seated].hello_us && channel_silence_us(relay.ch, seated, now) < SEATED_LIVE_US {
			reject(relay, peer, .Newer_Connection, now)
			log.infof("member %d: an earlier try's Hello after the seated one's, refused", known[i] + 1)
			return
		}
		replaced += {int(seated)}
	}
	if len(relay.members) + new_members > int(max(u16)) {
		reject(relay, peer, .Full, now) // 65,535 people in one session
		return
	}
	slots: [LOCAL_MAX]int
	taken: sim.Slots
	for &ask, i in asks {
		slot, why := pick_slot(relay, ask.slot, replaced, taken, extra = i > 0)
		if why != nil {
			reject(relay, peer, why.?, now)
			return
		}
		slots[i] = slot
		taken += {slot}
	}
	// A joiner starts from another player's snapshot: with nobody to send one, it can't join.
	provider := Peer(-1)
	if relay.started {
		if provider = pick_provider(relay, peer, {}, replaced); provider < 0 {
			reject(relay, peer, .No_Snapshot, now)
			log.infof("a client asking for slot %d refused: nobody can send it a snapshot", slots[0])
			return
		}
	}
	for other in replaced {
		conn_left(relay, Peer(other), "replaced by a new connection", now)
		channel_drop(relay.ch, Peer(other), now)
	}
	conn := &relay.conns[peer]
	relay_conn_reset(conn) // a new connection: nothing of the previous one's on this peer (stream, snapshot) carries over
	conn.connected = true
	conn.hello_us = hello.sent_us
	conn.token = hello.token
	for &ask, i in asks {
		seat_member(relay, peer, slots[i], &ask, member_key(base, ask.local), i == 0, now)
	}
	if !relay.started {
		conn.report_from = 1
		conn.base_known = true
		for other in 0 ..< relay.cfg.start_players {
			if relay.seats[other].conn < 0 {
				return
			}
		}
		relay.started = true
		relay.welcome_us = now
		relay.lead = relay.cfg.local_start ? 0 : ms_ticks(relay, START_LEAD_MS)
		// One new player per tick: the seated players become present on ticks 1, 2, ... in slot order.
		next := u32(1)
		for &seat in relay.seats {
			if seat.conn >= 0 {
				seat.active_from = next
				next += 1
			}
		}
		for &other, other_peer in relay.conns {
			if other.connected do send_welcome(relay, Peer(other_peer), true, now)
		}
		log.infof("%d players connected, clock started", next - 1)
		return
	}
	// Late join or rejoin: each seat becomes present at a future tick J, one new player per tick.
	for &ask, i in asks {
		late_join_tick(relay, slots[i], ask.join_tick)
	}
	first := relay.seats[slots[0]].active_from
	for slot in slots[1:len(asks)] do first = min(first, relay.seats[slot].active_from)
	conn.snap_min = first - 1
	send_welcome(relay, peer, false, now)
	request_snapshot(relay, peer, provider, now)
	log.infof(
		"member %d joins slot %d at tick %d (clock %d; %d seats), snapshot from slot %d",
		relay.seats[slots[0]].member,
		slots[0],
		relay.seats[slots[0]].active_from,
		relay.clock,
		len(asks),
		conn_slot(relay, provider),
	)
}

// Whether a Hello's or Join's seats can be read: each local below LOCAL_MAX and asked once, each Profile this build's
// size. A Profile of another size comes only from a modified client (compat covers the layout); what its bytes hold is
// the sim's to read.
@(private)
asks_valid :: proc(relay: ^Relay($G), asks: []Seat_Ask) -> bool {
	Profile :: sim.part(G, sim.GAME_PROFILE)
	locals: bit_set[0 ..< LOCAL_MAX]
	for &ask in asks {
		if ask.local >= LOCAL_MAX || int(ask.local) in locals || int(ask.profile.len) != size_of(Profile) {
			return false
		}
		locals += {int(ask.local)}
	}
	return true
}

// Who a connection is (Relay_Member.key): the account its link vouches for, else the client's token (never what the
// client says it is); "" for nothing.
@(private)
client_key :: proc(relay: ^Relay($G), peer: Peer, token: Token) -> string {
	account, vouched := channel_account(relay.ch, peer)
	if vouched && account.id != "" {
		return fmt.tprintf("%s:%s", account.platform, account.id)
	}
	return fmt.tprintf("token:%s", token_text(token)) if token != {} else ""
}

// The member key of a connection's local player: the connection's for local 0, then `<key>#<local>`, so each local
// player comes back as themselves ("" stays "": nobody to recognize).
@(private)
member_key :: proc(base: string, local: u8) -> string {
	if base == "" || local == 0 do return base
	return fmt.tprintf("%s#%d", base, local)
}

// The slot for a seat asked for as `wanted` (ANY_SLOT: the lowest free), free meaning empty or held by a connection in
// `replaced`, and not in `taken`; or why there is none. Before the clock starts a connection's first seat goes among
// the start slots; its `extra` local players may take any.
@(private)
pick_slot :: proc(
	relay: ^Relay($G),
	wanted: u8,
	replaced: Peers,
	taken: sim.Slots,
	extra: bool,
) -> (
	slot: int,
	why: Maybe(Reject_Reason),
) {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	free :: proc(relay: ^Relay($G), slot: int, replaced: Peers, taken: sim.Slots) -> bool {
		conn := relay.seats[slot].conn
		return slot not_in taken && (conn < 0 || int(conn) in replaced)
	}
	if wanted == ANY_SLOT {
		limit := relay.started || extra ? PLAYERS : relay.cfg.start_players
		for other in 0 ..< limit {
			if free(relay, other, replaced, taken) do return other, nil
		}
		return -1, .Full
	}
	slot = int(wanted)
	switch {
	case slot >= PLAYERS:
		return -1, .Full
	case !free(relay, slot, replaced, taken):
		return -1, .Slot_Taken
	case !relay.started && !extra && slot >= relay.cfg.start_players:
		return -1, .Not_Started
	}
	return slot, nil
}

// Seats a connection's local player in `slot`: the member `key` recognizes (a new one when none), its roster entry
// sent to everyone and everyone's to the connection.
@(private)
seat_member :: proc(relay: ^Relay($G), peer: Peer, slot: int, ask: ^Seat_Ask, key: string, first: bool, now: i64) {
	known := find_member(relay, key)
	if known < 0 {
		append(&relay.members, Relay_Member{key = strings.clone(key)})
		known = len(relay.members) - 1
		entry := &relay.members[known].entry
		entry.member = u16(known + 1)
		if account, vouched := channel_account(relay.ch, peer); vouched && account.id != "" {
			entry.platform = text_of(PLATFORM_MAX, account.platform)
			entry.account = text_of(ACCOUNT_MAX, account.id)
		}
	}
	entry := &relay.members[known].entry
	entry.name = ask.name
	entry.slot = u8(slot)
	entry.local = ask.local
	entry.connected = true
	seat := &relay.seats[slot]
	seat_reset(seat) // a new occupant: nothing of the previous one's (inputs, commands) carries over
	seat.member = entry.member
	seat.conn = peer
	seat.local = ask.local
	copy(sim.bytes_of(&seat.profile), ask.profile.bytes[:ask.profile.len])
	relay.conns[peer].locals[ask.local] = i8(slot)
	send_roster_entry(relay, known, now)
	if first {
		for k in 0 ..< len(relay.members) {
			if k != known do send_roster_entry(relay, k, now, peer) // a new connection: everyone else's entry
		}
	}
}

// A seat that joins a running session: present from the first tick at or after max(asked, clock + JOIN_LEAD_MS,
// finalized + 2) on which no other seat joins.
@(private)
late_join_tick :: proc(relay: ^Relay($G), slot: int, asked: u32) {
	seat := &relay.seats[slot]
	join_tick := max(asked, relay.clock + ms_ticks(relay, JOIN_LEAD_MS), relay.finalized + 2)
	seat.active_from = free_join_tick(relay, join_tick)
	seat.recv_upto = seat.active_from - 1
}

// Another local player of a connection that is in (Join): it gets a join tick as a late joiner's and needs no
// snapshot (the connection's sim has the session); Seated answers, or Reject naming that local player.
@(private)
on_join :: proc(relay: ^Relay($G), peer: Peer, reader: ^wire.Reader, now: i64) {
	conn := &relay.conns[peer]
	ask: Seat_Ask
	ask.local = wire.r_u8(reader)
	ask.slot = wire.r_u8(reader)
	ask.join_tick = wire.r_u32(reader)
	ask.name = r_text(reader, NAME_MAX)
	ask.profile = r_text(reader, sim.PROFILE_MAX)
	if !reader.ok || !conn.welcomed || !relay.started || relay.ending {
		return
	}
	if ask.local < LOCAL_MAX && conn.locals[ask.local] >= 0 {
		return // seated already: a resent Join
	}
	if !asks_valid(relay, {ask}) {
		reject(relay, peer, .Incompatible, now, ask.local)
		return
	}
	key := member_key(client_key(relay, peer, conn.token), ask.local)
	if known := find_member(relay, key); known >= 0 && relay.members[known].entry.connected {
		// The same person seated on another connection: the newest wins, that seat empties.
		other := int(relay.members[known].entry.slot)
		other_conn := relay.seats[other].conn
		seat_left(relay, other, "replaced by a new connection", now)
		if conn_slots(relay, other_conn) == {} {
			conn_left(relay, other_conn, "replaced by a new connection", now)
			channel_drop(relay.ch, other_conn, now)
		}
	}
	slot, why := pick_slot(relay, ask.slot, {}, {}, extra = true)
	if why != nil {
		reject(relay, peer, why.?, now, ask.local)
		return
	}
	seat_member(relay, peer, slot, &ask, key, false, now)
	late_join_tick(relay, slot, ask.join_tick)
	seat := &relay.seats[slot]
	writer := msg_begin(&relay.w, .Seated)
	wire.w_u8(writer, seat.local)
	wire.w_u8(writer, u8(slot))
	wire.w_u16(writer, seat.member)
	wire.w_u32(writer, seat.active_from)
	relay_send(relay, peer, writer, .Reliable, now)
	log.infof(
		"member %d joins slot %d at tick %d, a local player beside slot %d",
		seat.member,
		slot,
		seat.active_from,
		conn_slot(relay, peer),
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

// The connection holding the lowest slot that can send `joiner` a snapshot and isn't in `refused` (-1: none), other
// than those `leaving` (connections about to be replaced).
@(private)
pick_provider :: proc(relay: ^Relay($G), joiner: Peer, refused: Peers, leaving := Peers{}) -> Peer {
	order, count := conns_by_slot(relay)
	for other in order[:count] {
		conn := &relay.conns[other]
		if other != joiner &&
		   int(other) not_in leaving &&
		   conn.connected &&
		   conn.welcomed &&
		   conn.base_known &&
		   !conn.checking &&
		   conn.provider < 0 &&
		   int(other) not_in refused {
			return other
		}
	}
	return -1
}

// Asks `provider` for a snapshot for `joiner` (a Snap_Request whose target is the joiner's lowest slot).
@(private)
request_snapshot :: proc(relay: ^Relay($G), joiner, provider: Peer, now: i64) {
	conn := &relay.conns[joiner]
	conn.provider = provider
	conn.snap_total = 0
	conn.snap_sent = 0
	conn.snap_us = now
	writer := msg_begin(&relay.w, .Snap_Request)
	wire.w_u8(writer, u8(conn_slot(relay, joiner)))
	wire.w_u32(writer, conn.snap_min)
	relay_send(relay, provider, writer, .Reliable, now)
}

// The joiner's snapshot didn't get through (its provider left) or failed the check: ask another connection, or
// refuse the joiner.
@(private)
restart_snapshot :: proc(relay: ^Relay($G), joiner: Peer, why: string, now: i64) {
	conn := &relay.conns[joiner]
	conn.provider = -1
	conn.checking = false
	conn.base_known = false
	conn.client_ack = 0
	conn.report_from = NO_REPORTS
	slot := conn_slot(relay, joiner)
	if provider := pick_provider(relay, joiner, conn.refused); provider >= 0 {
		request_snapshot(relay, joiner, provider, now)
		log.infof("slot %d: %s, asking slot %d", slot, why, conn_slot(relay, provider))
		return
	}
	log.warnf("slot %d: %s, and nobody else can send a snapshot", slot, why)
	refuse_conn(relay, joiner, conn.bad_check ? .Bad_Snapshot : .No_Snapshot, now)
}

@(private)
have_input :: #force_inline proc(seat: ^Seat($Input, $Profile), tick: u32) -> bool {
	return seat.input_tick[tick % INPUT_RING] == tick
}

// A seat's Inputs message (its local byte read already): its inputs and commands, and the connection's finalized ack.
@(private)
on_inputs :: proc(relay: ^Relay($G), slot: int, reader: ^wire.Reader, now: i64) {
	Input :: sim.part(G, sim.GAME_INPUT)
	seat := &relay.seats[slot]
	conn := &relay.conns[seat.conn]
	finalized_ack := wire.r_u32(reader)
	first := wire.r_u32(reader)
	count := u32(wire.r_u8(reader))
	if !reader.ok {
		return
	}
	if conn.base_known {
		conn.client_ack = max(conn.client_ack, min(finalized_ack, relay.finalized))
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
		if !reader.ok || size > sim.COMMAND_MAX {
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
on_checksum :: proc(relay: ^Relay($G), peer: Peer, reader: ^wire.Reader, now: i64) {
	conn := &relay.conns[peer]
	tick := wire.r_u32(reader)
	value := wire.r_u64(reader)
	if !reader.ok || tick % CHECKSUM_EVERY != 0 || tick == 0 {
		return
	}
	if conn.checking {
		// A joiner's first checksum is of its restored snapshot; judge_snapshots compares it.
		if tick == conn.snap_tick && !conn.snap_have {
			conn.snap_value = value
			conn.snap_have = true
		}
		return
	}
	if tick < conn.report_from || tick > relay.finalized {
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
		// A late report (a connection catching up): measured against the majority already known.
		if value != check.majority {
			report_desync(relay, tick, conn_slots(relay, peer), now)
		}
		return
	}
	check.values[peer] = value
	check.slots[peer] = conn_slots(relay, peer)
	check.have += {int(peer)}
}

// The connections expected to report `tick`'s checksum: connected, streamed to, past their snapshot check, and
// reporting from that tick on.
@(private)
expected_reports :: proc(relay: ^Relay($G), tick: u32) -> (expected: Peers) {
	for &conn, peer in relay.conns {
		if conn.connected && conn.welcomed && conn.base_known && !conn.checking && conn.report_from <= tick {
			expected += {peer}
		}
	}
	return
}

// The lowest slot a connection held when it reported `check` (MAX_PLAYERS for none).
@(private)
check_slot :: proc(check: ^Check, peer: int) -> int {
	for slot in check.slots[peer] do return slot
	return sim.MAX_PLAYERS
}

// Judges the checksum ticks whose reports are in (or waited for long enough): the majority value among the
// connections, one vote each (ties: the connection that held the lowest slot, so with 2 players the host wins), and a
// desync naming the slots of every connection that differs from it.
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
		best, best_slot := 0, sim.MAX_PLAYERS + 1
		for peer in check.have {
			votes := 0
			for other in check.have {
				if check.values[other] == check.values[peer] {
					votes += 1
				}
			}
			if slot := check_slot(&check, peer); votes > best || (votes == best && slot < best_slot) {
				best, best_slot = votes, slot
				check.majority = check.values[peer]
			}
		}
		diverged: sim.Slots
		for peer in check.have {
			if check.values[peer] != check.majority {
				diverged += check.slots[peer]
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
	for &conn, joiner in relay.conns {
		if !conn.connected || !conn.checking || !conn.snap_have {
			continue
		}
		tick := conn.snap_tick
		majority, judged := majority_of(relay, tick)
		if !judged {
			check := &relay.checks[(tick / CHECKSUM_EVERY) % CHECK_RING]
			if (check.tick == tick || check.tick < tick) && relay.clock < tick + 2 * wait {
				continue // the reports are on their way
			}
			// Nobody reported the tick (or it left the ring): nothing to compare with.
			slot := conn_slot(relay, Peer(joiner))
			log.infof("slot %d: snapshot of tick %d not checked: no other checksum of it", slot, tick)
			majority = conn.snap_value
			relay.unchecked_snapshots += 1
		}
		if conn.snap_value != majority {
			conn.refused += {int(conn.snap_from)}
			conn.bad_check = true
			from := conn_slot(relay, conn.snap_from)
			restart_snapshot(
				relay,
				Peer(joiner),
				fmt.tprintf("the snapshot of tick %d from slot %d differs from the others", tick, from),
				now,
			)
			continue
		}
		conn.checking = false
		active_from := max(u32)
		for slot in conn.locals {
			if slot >= 0 do active_from = min(active_from, relay.seats[slot].active_from)
		}
		conn.report_from = max(active_from, tick + 1)
		writer := msg_begin(&relay.w, .Snap_Ok)
		wire.w_u32(writer, tick)
		relay_send(relay, Peer(joiner), writer, .Reliable, now)
	}
}

// A desync on `tick` (`diverged`: the slots of the connections that differ): counted and logged; told to every
// client, after the typed report's snapshots (when the relay has desync_detail and this is the session's first
// desync) or at once.
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
		majority_conn, diverged_conn := Peer(-1), Peer(-1)
		order, count := conns_by_slot(relay)
		for peer in order[:count] {
			if int(peer) not_in check.have || check.slots[peer] != conn_slots(relay, peer) {
				continue // it did not report, or another connection reported from this peer since
			}
			if check.slots[peer] & diverged != {} && diverged_conn < 0 {
				diverged_conn = peer
			} else if check.slots[peer] & diverged == {} && majority_conn < 0 {
				majority_conn = peer
			}
		}
		if check.tick == tick && majority_conn >= 0 && diverged_conn >= 0 {
			relay.detailed = true
			relay.pending_on = true
			relay.pending_tick = tick
			relay.pending_us = now
			relay.pending_from = now
			for &pending, k in relay.pending {
				clear(&pending.image)
				pending.conn = k == 0 ? majority_conn : diverged_conn
				pending.total = 0
				pending.done = false
				writer := msg_begin(&relay.w, .Snap_Request)
				wire.w_u8(writer, RELAY_TARGET)
				wire.w_u32(writer, tick)
				relay_send(relay, pending.conn, writer, .Reliable, now)
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
		if !(relay.pending[0].done && relay.pending[1].done) &&
		   now - relay.pending_us < IMAGE_WAIT_MS * 1000 &&
		   now - relay.pending_from < IMAGE_GIVE_UP_MS * 1000 {
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
		for &conn, peer in relay.conns {
			if conn.connected && conn.welcomed {
				relay_send(relay, Peer(peer), writer, .Reliable, now)
			}
		}
		delete(report.detail)
	}
	clear(&relay.reports)
}

// A typed desync report's snapshot coming in from one of the two connections asked.
@(private)
take_image :: proc(relay: ^Relay($G), peer: Peer, kind: Msg, reader: ^wire.Reader, now: i64) {
	if !relay.pending_on {
		return
	}
	for &pending in relay.pending {
		if pending.conn != peer || pending.done {
			continue
		}
		if kind == .Snap_Begin {
			tick := wire.r_u32(reader)
			total := wire.r_u32(reader)
			if !reader.ok || pending.total != 0 {
				return // a connection answers once: another Snap_Begin restarts nothing
			}
			pending.total = tick == relay.pending_tick && total <= IMAGE_MAX ? total : 0
			pending.done = pending.total == 0
			relay.pending_us = now // the answer: a large image arrives at the pace, bytes at a time
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
		if len(bytes) == 0 {
			return // no progress
		}
		append(&pending.image, ..bytes)
		pending.done = u32(len(pending.image)) == pending.total
		relay.pending_us = now
		return
	}
}

@(private)
active :: #force_inline proc(seat: ^Seat($Input, $Profile), tick: u32) -> bool {
	return seat.active_from != 0 && tick >= seat.active_from && seat.conn >= 0
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
				tick_inputs.joins[slot] = seat.member // the join record, with the Profile its Hello brought
				tick_inputs.profiles[slot] = seat.profile
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
		assert(sim.join_count(tick_inputs.joins[:]) <= 1, "one new player per tick (free_join_tick)")
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
	Profile :: sim.part(G, sim.GAME_PROFILE)
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	taken: [PLAYERS]int
	total, bytes := 0, 0
	budget := tick_command_budget(Input, PLAYERS, size_of(Profile))
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
	for &conn, index in relay.conns {
		peer := Peer(index)
		if !conn.welcomed || !conn.connected {
			continue
		}
		if !conn.base_known {
			finalized_message(relay, peer, conn.client_ack + 1, conn.client_ack, now) // the relay time and acks only
			conn.resume = 0
			continue
		}
		// The unacked ticks, up to CATCHUP_TICKS of them. When they don't fit one message (WINDOW_MAX ticks, or
		// MAX_MESSAGE bytes), each broadcast carries on where the one before stopped, and starts again at the oldest
		// once one reached the newest: the client gets a message of ticks per broadcast, not one per round trip (its
		// ack is what moves the oldest).
		newest := min(relay.finalized, conn.client_ack + CATCHUP_TICKS) // the newest tick this client is streamed
		first := conn.client_ack + 1
		if conn.resume > first && conn.resume <= newest {
			first = conn.resume
		}
		carried := first + finalized_message(relay, peer, first, newest, now) - 1 // the newest tick it carried
		conn.resume = carried < newest ? carried + 1 : 0
		// Ticks no broadcast carried yet wait for the cycle to come round to them, a broadcast per message of
		// backlog: while the cycle is behind them, a second message carries them now.
		fresh := max(conn.sent_upto, conn.client_ack) + 1
		if fresh > carried && fresh <= newest {
			carried = max(carried, fresh + finalized_message(relay, peer, fresh, newest, now) - 1)
		}
		conn.sent_upto = max(conn.sent_upto, carried)
	}
}

// Sends a connection a Finalized with the relay time, the ticks from `first` on, up to `newest` (none when newest <
// first; as many as fit one message) and each of its seats' input and command acks. Returns how many ticks it carried.
@(private)
finalized_message :: proc(relay: ^Relay($G), peer: Peer, first, newest: u32, now: i64) -> (written: u32) {
	conn := &relay.conns[peer]
	writer := msg_begin(&relay.w, .Finalized)
	// Relay time: when tick 0 was due, so negative during the lead.
	w_i64(writer, i64(f64(now - relay.welcome_us) - f64(relay.lead) * relay.tm.tick_us))
	wire.w_u32(writer, first)
	count_at := len(writer.buf)
	wire.w_u8(writer, 0)
	seats_at := len(writer.buf)
	wire.w_u8(writer, 0)
	assert(len(writer.buf) == FINALIZED_HEAD)
	seats := 0
	for slot in conn.locals {
		if slot < 0 do continue
		seat := &relay.seats[slot]
		wire.w_u8(writer, seat.local)
		wire.w_u32(writer, max(seat.recv_upto, relay.finalized))
		wire.w_u32(writer, seat.cmd_recv)
		seats += 1
	}
	writer.buf[seats_at] = u8(seats)
	base: ^sim.Inputs(G) // the tick before in this packet (nil: the empty tick)
	last := min(newest, first + WINDOW_MAX - 1)
	for tick := first; newest >= first && tick <= last; tick += 1 {
		tick_inputs := relay_tick(relay, tick)
		if tick_inputs == nil {
			break
		}
		// Ticks with commands or many changes are larger: stop at the message limit (every tick alone fits, see
		// tick_command_budget), the rest goes in the next broadcast.
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
	relay_send(relay, peer, writer, .Unreliable, now)
	return
}

// Sends a member's roster entry to every connected client (or only to connection `to`).
@(private)
send_roster_entry :: proc(relay: ^Relay($G), member: int, now: i64, to := Peer(-1)) {
	writer := msg_begin(&relay.w, .Roster)
	w_roster_entry(writer, &relay.members[member].entry)
	for &conn, peer in relay.conns {
		if conn.connected && (to < 0 || to == Peer(peer)) {
			relay_send(relay, Peer(peer), writer, .Reliable, now)
		}
	}
}

// The seat's occupant is gone (its connection left, disconnected, was refused or replaced): the seat is emptied and
// the member's roster entry says so.
@(private)
seat_left :: proc(relay: ^Relay($G), slot: int, why: string, now: i64) {
	seat := &relay.seats[slot]
	member := int(seat.member)
	if seat.conn >= 0 {
		relay.conns[seat.conn].locals[seat.local] = -1
	}
	seat_reset(seat) // a left player's commands that never reached a tick go with it
	log.infof("member %d (slot %d) %s", member, slot, why)
	if member != int(NO_MEMBER) {
		entry := &relay.members[member - 1].entry
		entry.slot = NO_SLOT
		entry.connected = false
		send_roster_entry(relay, member - 1, now) // the entry stays: a "left" message can still name them
	}
}

// A connection is gone (left, disconnected, refused, replaced): every seat it held is emptied, its record too, and a
// joiner it was sending a snapshot to asks someone else.
@(private)
conn_left :: proc(relay: ^Relay($G), peer: Peer, why: string, now: i64) {
	conn := &relay.conns[peer]
	slot := conn_slot(relay, peer)
	for local in conn.locals {
		if local >= 0 do seat_left(relay, int(local), why, now)
	}
	relay_conn_reset(conn)
	for &pending in relay.pending {
		if relay.pending_on && pending.conn == peer {
			pending.done = true
		}
	}
	for &other, joiner in relay.conns {
		if other.provider == peer && other.connected {
			restart_snapshot(relay, Peer(joiner), fmt.tprintf("snapshot provider %d left", slot), now)
		}
	}
}

@(private)
handle_relay_msg :: proc(relay: ^Relay($G), peer: Peer, data: []u8, now: i64) {
	// A message of a connection that ended earlier in this poll (after its Leave in one datagram): nothing behind it to
	// seat or answer. (A peer that started over in this poll: the channel delivers none of its old connection's
	// messages, so they never reach the new connection on this peer number.)
	if !channel_connected(relay.ch, peer) {
		return
	}
	reader := wire.reader_make(data)
	kind := Msg(wire.r_u8(&reader))
	if kind == .Hello {
		on_hello(relay, peer, &reader, now)
		return
	}
	conn := &relay.conns[peer]
	if !conn.connected {
		if kind == .Leave {
			channel_drop(relay.ch, peer, now) // refused earlier: its connection is free at once, not in DISCONNECT_US
		}
		return
	}
	#partial switch kind {
	case .Inputs:
		local := wire.r_u8(&reader)
		if local < LOCAL_MAX && conn.locals[local] >= 0 {
			on_inputs(relay, int(conn.locals[local]), &reader, now)
		}
	case .Join:
		on_join(relay, peer, &reader, now)
	case .Checksum:
		on_checksum(relay, peer, &reader, now)
	case .Snap_Begin, .Snap_Chunk:
		forward_snapshot(relay, peer, kind, &reader, data, now)
	case .Done:
		conn.done = true
	case .Leave:
		local := wire.r_u8(&reader)
		if reader.ok && local < LOCAL_MAX && conn.locals[local] >= 0 {
			seat_left(relay, int(conn.locals[local]), "left (its connection plays on)", now)
			if conn_slots(relay, peer) != {} do return
		}
		conn_left(relay, peer, "left", now) // the client, or its last local player
		channel_drop(relay.ch, peer, now)
	}
}

// Forwards a snapshot message from the provider the relay asked (anything else is dropped), or takes a desync
// report's snapshot. Its target names the joiner by its lowest slot (request_snapshot).
@(private)
forward_snapshot :: proc(relay: ^Relay($G), from: Peer, kind: Msg, reader: ^wire.Reader, data: []u8, now: i64) {
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	target := wire.r_u8(reader)
	if reader.ok && target == RELAY_TARGET {
		take_image(relay, from, kind, reader, now)
		return
	}
	if !reader.ok || int(target) >= PLAYERS || relay.seats[target].conn < 0 || len(data) > MAX_MESSAGE {
		return
	}
	joiner := relay.seats[target].conn
	conn := &relay.conns[joiner]
	if conn.provider != from {
		return
	}
	// Before its answer's Snap_Begin (snap_total 0), what the provider sends for this joiner is the rest of its answer
	// to an earlier request (the seat's previous occupant's, sent before this request reached it), queued ahead of
	// this one: a snapshot older than this request allows, or chunks of one. Dropped, not held against the provider,
	// and a sign of life while the answer behind it can still be streamed from the ring.
	if kind == .Snap_Begin {
		tick := wire.r_u32(reader)
		total := wire.r_u32(reader)
		if reader.ok && conn.snap_total == 0 && tick < conn.snap_min {
			stale_snapshot_message(relay, conn, now)
			return
		}
		// A snapshot of a checksum tick (the joiner's checksum of it is compared with the others'), still in the
		// ring (the ticks after it are streamed from there).
		if !reader.ok ||
		   tick < conn.snap_min ||
		   tick % CHECKSUM_EVERY != 0 ||
		   relay_tick(relay, tick) == nil ||
		   total == 0 {
			conn.refused += {int(from)} // it would send the same again: ask another connection
			restart_snapshot(
				relay,
				joiner,
				fmt.tprintf("slot %d's snapshot of tick %d is not usable", conn_slot(relay, from), tick),
				now,
			)
			return
		}
		conn.snap_us = now
		conn.snap_total = total
		conn.snap_sent = 0
		conn.snap_tick = tick
		// A snapshot that replaces this one is never older: the joiner keeps the finalized ticks streamed to it from
		// here on, and acks of them may still be on their way when the next Snap_Begin is forwarded.
		conn.snap_min = tick
		conn.snap_from = from
		conn.snap_have = false
		// Stream finalized ticks from the snapshot's tick on (that tick's inputs seed the joiner's
		// prediction of the others).
		conn.client_ack = tick - 1
		conn.sent_upto = tick - 1
		conn.base_known = true
		log.infof("forwarding slot %d's snapshot of tick %d to slot %d", conn_slot(relay, from), tick, target)
	} else {
		offset := wire.r_u32(reader)
		size := u32(len(reader.data) - reader.pos)
		if reader.ok && conn.snap_total == 0 {
			stale_snapshot_message(relay, conn, now)
			return
		}
		if !reader.ok || offset != conn.snap_sent || size > conn.snap_total - offset {
			return
		}
		conn.snap_sent += size
		conn.snap_us = now
		if conn.snap_sent == conn.snap_total {
			// Complete: the joiner restores it and sends its checksum, which judge_snapshots checks.
			conn.provider = -1
			conn.checking = true
		}
	}
	channel_send(relay.ch, joiner, data, .Reliable, now)
}

// A joiner's provider is still sending what it answered an earlier request with (forward_snapshot): it lives, while
// the ticks from the joiner's snap_min on are in the ring (the snapshot it answers this request with is of one of
// them). Past that it is replaced once SNAP_STALL_US pass, as if silent.
@(private)
stale_snapshot_message :: proc(relay: ^Relay($G), conn: ^Relay_Conn, now: i64) {
	if relay.finalized < conn.snap_min + RELAY_RING {
		conn.snap_us = now
	}
}

// One step of the relay: receive, advance the clock, finalize, broadcast, judge checksums, flush. Returns when it
// wants to run next (a now_us value): the next clock tick, or sooner to poll the links.
relay_step :: proc(relay: ^Relay($G), now: i64) -> (wake_us: i64) {
	for event in channel_poll(relay.ch, now) {
		switch event.kind {
		case .Connected, .Incompatible:
		case .Disconnected:
			if relay.conns[event.peer].connected {
				conn_left(relay, event.peer, "disconnected", now)
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
		for &conn, peer in relay.conns {
			if conn.connected && conn.base_known && relay.finalized - conn.client_ack > RELAY_RING {
				refuse_conn(relay, Peer(peer), .Too_Far_Behind, now)
			}
		}
		if broadcast_due(relay, now) {
			broadcast(relay, now)
		}
		judge_checks(relay, now)
		judge_snapshots(relay, now)
		for &conn, joiner in relay.conns {
			if provider := conn.provider; provider >= 0 && conn.connected && now - conn.snap_us > SNAP_STALL_US {
				conn.refused += {int(provider)}
				why := fmt.tprintf("no snapshot from slot %d", conn_slot(relay, provider))
				restart_snapshot(relay, Peer(joiner), why, now)
			}
		}
		send_reports(relay, now)
	}
	if !relay.ending && relay.started && relay.cfg.ticks != 0 && relay.finalized == relay.cfg.ticks {
		all_done := true
		for &conn in relay.conns {
			if conn.welcomed && conn.connected && !conn.done {
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
		for &conn, peer in relay.conns {
			if conn.connected && !channel_idle(relay.ch, Peer(peer)) {
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
