// The input relay (src/netcode/SPEC.md), generic over the game's Input type and player count PLAYERS. No game
// logic: it owns the tick clock, collects inputs stamped with their target tick, finalizes tick T
// once every present player's input for T is in or the clock reaches T + tolerance (a missing
// input becomes the player's last finalized one, flagged "replaced"), places each player's commands
// in order in the first tick it finalizes at or after the tick they were sent for (never repeated,
// never lost), broadcasts finalized ticks unreliably with every unacknowledged tick resent (when a tick
// is finalized, or a heartbeat when none was for a tick), keeps the last RELAY_RING ticks (the whole session
// only in an optional recording), routes late-join snapshots of checksum ticks and checks each against the
// others' checksum before the joiner plays, and compares the clients' checksums: a tick on which they
// disagree is a desync, reported to every client (with a typed diff of two snapshots, when configured). It
// serves any number of links at once (the host's in-process client plus remote peers) and is driven by
// relay_step from the host's own loop. Every distinct person gets a member id for the session (never reused),
// recognized when they come back by the account their link vouches for, else by their client's token; a slot's
// join tick carries that id (the sim's join record).
package netcode

// Used only inside generic procs: @(require) keeps -vet from calling them unused in a program that never
// instantiates those (a game's tests that run the sim offline only).
@(require) import "core:fmt"
@(require) import "core:strings"
@(require) import "core:sync"

import "unified:sim"
import "unified:wire"

Relay_Config :: struct {
	tick_hz:       int,
	seed:          u64,
	ticks:         u32, // session length; 0: endless
	start_players: int, // players 0..start_players-1 must connect before the clock starts (>= 1)
	compat:        u64, // build/game id (sim.compat_of); a Hello with another value is rejected (0: any)
	content:       u64, // the content's hash (sim.content_hash), recorded in the input log
	name:          string, // for log lines
	poll_us:       i64, // 0: DEFAULT_POLL_US
	quiet:         bool,
	// Every start player is in-process (a host's own client): tick 1 is due a tick after Welcome. Otherwise
	// the clock starts START_LEAD_MS after Welcome, so a far start player's first inputs arrive in time.
	local_start:   bool,
	// Optional: the session's input log, written tick by tick as ticks are finalized (sim/log.odin's format;
	// sim.log_sink_memory, sim.log_sink_file). The relay owns the sink: relay_end_recording (or relay_destroy)
	// writes the tick count and closes it. Without one, the session is kept only RELAY_RING ticks back.
	recording:     sim.Log_Sink,
	// Optional, for dev builds: what differs between two snapshots of a tick (desync_diff_of(State)). With it,
	// clients keep the snapshots of their last checksum ticks, and a desync report carries the diff of two of
	// them (a majority player's and a diverged one's) as its detail.
	desync_diff:   proc(a, b: []u8) -> string,
}

RELAY_RING :: 512 // finalized ticks the relay keeps: a client further behind can't be streamed to
#assert(CATCHUP_TICKS < RELAY_RING)
INPUT_RING :: 256
CHECK_RING :: 64
JOIN_LEAD_MS :: 500 // a joiner becomes present this long after the relay clock at its Hello
START_LEAD_MS :: 500 // the clock starts (tick 0 is due) this long after Welcome, unless local_start
BROADCAST_GAP :: 0.75 // ticks at least between two Finalized broadcasts that only carry new ticks (#246; a heartbeat waits a tick)
CHECK_WAIT_MS :: 1000 // a checksum tick is judged once every expected report is in, or this long after it is due
IMAGE_WAIT_MS :: 3000 // how long a typed desync report waits for its two snapshots
IMAGE_MAX :: 256 << 20 // the largest snapshot the relay takes for a desync report
NO_REPORTS :: max(u32) // Relay.report_from of a player that sends no checksums yet

// A received command waiting for the tick it goes in.
@(private)
Wait_Command :: struct {
	want: u32, // the tick the sender predicted it at
	cmd:  sim.Raw_Command,
}

// The checksums the players sent for one checksum tick.
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
	tick:     u32, // the checksum tick on which the players disagree
	diverged: sim.Slots, // the players whose checksum differs from the majority's (with 2 players: from player 0's)
	detail:   string, // what differs (relay.cfg.desync_diff), or ""
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
	player: int,
	image:  [dynamic]u8,
	total:  u32,
	done:   bool, // complete, or not coming
}

Relay :: struct($Input: typeid, $PLAYERS: int) {
	cfg:          Relay_Config,
	tm:           Timing,
	ch:           ^Channel,
	w:            wire.Writer,
	started:      bool, // Welcome sent to the start players
	welcome_us:   i64,
	lead:         u32, // ticks from Welcome to the clock's tick 0
	beats:        u32, // ticks since Welcome, the lead included
	clock:        u32, // beats - lead (0 during the lead)
	clock_pub:    u32, // clock, readable from other threads (atomic)
	finalized:    u32,
	ring:         [RELAY_RING]sim.Inputs(Input, PLAYERS), // finalized tick T in ring[T % RELAY_RING]
	recording:    sim.Log_Stream,
	peer_of:      [PLAYERS]Peer,
	player_of:    [MAX_PEERS]int,
	welcomed:     [PLAYERS]bool,
	members:      [dynamic]Relay_Member, // every person of the session, by member id - 1
	member_of:    [PLAYERS]u16, // the member seated in each slot (NO_MEMBER: none)
	connected:    [PLAYERS]bool,
	done:         [PLAYERS]bool,
	base_known:   [PLAYERS]bool, // finalized ticks can be streamed to this client
	active_from:  [PLAYERS]u32, // first tick the player is present (0: not joined)
	report_from:  [PLAYERS]u32, // the first checksum tick the player reports (NO_REPORTS: none yet)
	// late join: who sends the joiner its snapshot, and the check of the snapshot before the joiner plays
	provider:     [PLAYERS]int, // -1: none pending
	snap_min:     [PLAYERS]u32, // the oldest tick the joiner's snapshot may be of
	snap_total:   [PLAYERS]u32, // bytes of the snapshot being forwarded (from its Snap_Begin)
	snap_sent:    [PLAYERS]u32, // bytes forwarded so far
	snap_tick:    [PLAYERS]u32, // the checksum tick the joiner's snapshot is of
	snap_from:    [PLAYERS]int, // who sent it
	checking:     [PLAYERS]bool, // the joiner restores it and sends its checksum; the relay compares
	snap_value:   [PLAYERS]u64, // the joiner's checksum of its restored snapshot
	snap_have:    [PLAYERS]bool,
	refused:      [PLAYERS]sim.Slots, // providers whose snapshot for this joiner failed the check
	inputs:       [PLAYERS][INPUT_RING]Input,
	input_tick:   [PLAYERS][INPUT_RING]u32, // which tick inputs[player][k] holds
	recv_upto:    [PLAYERS]u32,
	client_ack:   [PLAYERS]u32,
	cmd_recv:     [PLAYERS]u32, // the command ack: every seq up to this one is received
	cmd_wait:     [PLAYERS][dynamic]Wait_Command, // received, not finalized yet, in seq order
	rotate:       [PLAYERS]u32, // which window of a long backlog the next broadcast carries
	echo_time:    [PLAYERS]i64,
	echo_recv:    [PLAYERS]i64,
	broadcast_us: i64, // when the last broadcast went out
	broadcast_to: u32, // the newest finalized tick when it did
	checks:       [CHECK_RING]Check(PLAYERS),
	desyncs:      int, // desync reports (a checksum tick on which some players differ from the majority)
	reports:      [dynamic]Desync_Report, // waiting to go out while a typed report gathers its snapshots
	pending:      [2]Pending_Image, // the typed report's snapshots: a majority player's, a diverged one's
	pending_on:   bool,
	pending_tick: u32,
	pending_us:   i64,
	detailed:     bool, // the session's first desync got its typed report (later ones are its consequences)
	first_desync: Desync_Report, // the first desync reported (its detail owned by the relay)
	replaced:     int,
	ending:       bool,
	end_us:       i64,
	finished:     bool,
}

// Creates a relay for `PLAYERS` players of `Input` with no links yet (relay_add_link), starting its recording
// if cfg has one. The clock starts once cfg.start_players have connected.
relay_create :: proc(cfg: Relay_Config, $Input: typeid, $PLAYERS: int) -> ^Relay(Input, PLAYERS) {
	sim.check_wire(Input)
	_ = tick_command_budget(Input, PLAYERS) // asserts a tick with a command fits a datagram
	assert(cfg.start_players >= 1 && cfg.start_players <= PLAYERS)
	relay := new(Relay(Input, PLAYERS))
	relay.cfg = cfg
	if relay.cfg.poll_us <= 0 {
		relay.cfg.poll_us = DEFAULT_POLL_US
	}
	relay.tm = timing_of(cfg.tick_hz)
	relay.ch = channel_make()
	relay.w = wire.writer_make(MAX_DATAGRAM)
	for player in 0 ..< PLAYERS {
		relay.peer_of[player] = -1
		relay.provider[player] = -1
		relay.report_from[player] = NO_REPORTS
		reserve(&relay.cmd_wait[player], COMMAND_QUEUE)
	}
	for &player in relay.player_of {
		player = -1
	}
	header := sim.Log_Header {
		seed       = cfg.seed,
		content    = cfg.content,
		compat     = cfg.compat, // 0 (a relay that accepts any build): unknown
		players    = PLAYERS,
		input_size = size_of(Input),
	}
	sim.log_stream_begin(&relay.recording, cfg.recording, header)
	return relay
}

// Writes the recording's tick count and closes its sink (once; relay_destroy does it too). False if a write failed.
relay_end_recording :: proc(relay: ^Relay($Input, $PLAYERS)) -> bool {
	return sim.log_stream_end(&relay.recording)
}

// Ends the recording if still open, closes every link the relay owns and frees it.
relay_destroy :: proc(relay: ^Relay($Input, $PLAYERS)) {
	relay_end_recording(relay)
	channel_destroy(relay.ch)
	delete(relay.w.buf)
	for member in relay.members {
		delete(member.key)
	}
	delete(relay.members)
	for &waiting in relay.cmd_wait {
		delete(waiting)
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
relay_add_link :: proc(relay: ^Relay($Input, $PLAYERS), link: Link) -> int {
	return channel_add_link(relay.ch, link)
}

// The relay's tick clock, readable from any thread.
relay_clock :: proc(relay: ^Relay($Input, $PLAYERS)) -> u32 {
	return sync.atomic_load(&relay.clock_pub)
}

// A finalized tick's inputs, while the relay keeps it (finalized - RELAY_RING < tick <= finalized; else nil).
relay_tick :: proc(relay: ^Relay($Input, $PLAYERS), tick: u32) -> ^sim.Inputs(Input, PLAYERS) {
	if tick == 0 || tick > relay.finalized || relay.finalized - tick >= RELAY_RING {
		return nil
	}
	return &relay.ring[tick % RELAY_RING]
}

// Ends the session: every connected client gets End; the relay is finished once they acked it
// (or after 3 s). Keep stepping until relay_finished.
relay_stop :: proc(relay: ^Relay($Input, $PLAYERS), now: i64) {
	if relay.ending {
		return
	}
	for player in 0 ..< PLAYERS {
		if relay.connected[player] {
			relay_send(relay, player, msg_begin(&relay.w, .End), .Reliable, now)
		}
	}
	relay.ending = true
	relay.end_us = now
}

// Whether the relay is done: after relay_stop (or the last tick of a fixed-length session), every client acked
// End or 3 s passed. The loop stepping the relay stops on it.
relay_finished :: proc(relay: ^Relay($Input, $PLAYERS)) -> bool {
	return relay.finished
}

@(private)
relay_log :: proc(relay: ^Relay($Input, $PLAYERS), format: string, args: ..any) {
	if !relay.cfg.quiet {
		fmt.eprintf("%s: ", relay.cfg.name)
		fmt.eprintfln(format, ..args)
	}
}

@(private)
relay_send :: proc(relay: ^Relay($Input, $PLAYERS), player: int, writer: ^wire.Writer, delivery: Delivery, now: i64) {
	if relay.peer_of[player] >= 0 {
		channel_send(relay.ch, relay.peer_of[player], writer.buf[:], delivery, now)
	}
}

@(private)
ms_ticks :: proc(relay: ^Relay($Input, $PLAYERS), ms: int) -> u32 {
	return ceil_ticks(f64(ms) * 1000, relay.tm.tick_us)
}

@(private)
send_welcome :: proc(relay: ^Relay($Input, $PLAYERS), player: int, now: i64) {
	writer := msg_begin(&relay.w, .Welcome)
	wire.w_u8(writer, u8(player))
	wire.w_u16(writer, relay.member_of[player])
	wire.w_u64(writer, relay.cfg.seed)
	wire.w_u16(writer, u16(relay.cfg.tick_hz))
	wire.w_u32(writer, relay.cfg.ticks)
	wire.w_u32(writer, relay.active_from[player])
	flags: Welcome_Flags
	if relay.cfg.desync_diff != nil {
		flags += {.Keep_Images}
	}
	wire.w_u8(writer, transmute(u8)flags)
	relay_send(relay, player, writer, .Reliable, now)
	relay.welcomed[player] = true
}

@(private)
reject :: proc(relay: ^Relay($Input, $PLAYERS), peer: Peer, why: Reject_Reason, now: i64) {
	writer := msg_begin(&relay.w, .Reject)
	wire.w_u8(writer, u8(why))
	channel_send(relay.ch, peer, writer.buf[:], .Reliable, now)
}

// Refuses a player that is in already (its snapshot failed, it fell too far behind): it gets Reject and is gone.
@(private)
refuse_player :: proc(relay: ^Relay($Input, $PLAYERS), player: int, why: Reject_Reason, now: i64) {
	reject(relay, relay.peer_of[player], why, now)
	player_gone(relay, player, fmt.tprintf("refused (%v)", why), now)
}

@(private)
on_hello :: proc(relay: ^Relay($Input, $PLAYERS), peer: Peer, reader: ^wire.Reader, now: i64) {
	protocol := wire.r_u16(reader)
	wanted := wire.r_u8(reader)
	asked_join_tick := wire.r_u32(reader)
	compat := wire.r_u64(reader)
	token: Token
	copy(token[:], wire.r_bytes(reader, TOKEN_SIZE))
	name := r_name(reader)
	if !reader.ok || relay.player_of[peer] >= 0 || relay.ending {
		return
	}
	if protocol != PROTOCOL_VERSION || (relay.cfg.compat != 0 && compat != relay.cfg.compat) {
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
	// Newest wins: a person still seated who connects again (a restarted game) replaces their old connection.
	if known >= 0 && relay.members[known].entry.connected {
		old := int(relay.members[known].entry.slot)
		old_peer := relay.peer_of[old]
		player_gone(relay, old, "replaced by a new connection", now)
		channel_drop(relay.ch, old_peer)
	}
	if known < 0 && len(relay.members) >= int(max(u16)) {
		reject(relay, peer, .Full, now) // 65,535 people in one session
		return
	}
	player := -1
	if wanted == ANY_PLAYER {
		limit := relay.started ? PLAYERS : relay.cfg.start_players
		for other in 0 ..< limit {
			if !relay.connected[other] {
				player = other
				break
			}
		}
		if player < 0 {
			reject(relay, peer, .Full, now)
			return
		}
	} else {
		player = int(wanted)
		if player >= PLAYERS {
			reject(relay, peer, .Full, now)
			return
		}
		if relay.connected[player] {
			reject(relay, peer, .Player_Taken, now)
			return
		}
		if !relay.started && player >= relay.cfg.start_players {
			reject(relay, peer, .Not_Started, now)
			return
		}
	}
	// A joiner starts from another player's snapshot: with nobody to send one, it can't join.
	provider := -1
	if relay.started {
		relay.refused[player] = {}
		if provider = pick_provider(relay, player); provider < 0 {
			reject(relay, peer, .No_Snapshot, now)
			relay_log(relay, "a player asking for %d refused: no player can send a snapshot", player)
			return
		}
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
	entry.slot = u8(player)
	entry.connected = true
	relay.member_of[player] = entry.member
	relay.peer_of[player] = peer
	relay.player_of[peer] = player
	relay.connected[player] = true
	relay.done[player] = false
	relay.cmd_recv[player] = 0 // a new client numbers its commands from 1
	relay.checking[player] = false
	clear(&relay.cmd_wait[player])
	send_roster_entry(relay, known, now)
	for k in 0 ..< len(relay.members) {
		if k != known {
			send_roster_entry(relay, k, now, player)
		}
	}
	if !relay.started {
		relay.active_from[player] = 1
		relay.report_from[player] = 1
		relay.base_known[player] = true
		for other in 0 ..< relay.cfg.start_players {
			if !relay.connected[other] {
				return
			}
		}
		relay.started = true
		relay.welcome_us = now
		relay.lead = relay.cfg.local_start ? 0 : ms_ticks(relay, START_LEAD_MS)
		for other in 0 ..< relay.cfg.start_players {
			send_welcome(relay, other, now)
		}
		relay_log(relay, "%d players connected, clock started", relay.cfg.start_players)
		return
	}
	// Late join or rejoin: the player becomes present at a future tick J.
	join_tick := max(asked_join_tick, relay.clock + ms_ticks(relay, JOIN_LEAD_MS), relay.finalized + 2)
	relay.active_from[player] = join_tick
	relay.report_from[player] = NO_REPORTS
	relay.recv_upto[player] = join_tick - 1
	relay.base_known[player] = false
	relay.client_ack[player] = 0
	relay.snap_min[player] = join_tick - 1
	send_welcome(relay, player, now)
	request_snapshot(relay, player, provider, now)
	relay_log(
		relay,
		"member %d joins slot %d at tick %d (clock %d), snapshot from slot %d",
		relay.member_of[player],
		player,
		join_tick,
		relay.clock,
		provider,
	)
}

// The member a key recognizes (-1: none, or no key).
@(private)
find_member :: proc(relay: ^Relay($Input, $PLAYERS), key: string) -> int {
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

// The lowest connected player that can send `joiner` a snapshot and didn't send it a bad one (-1: none).
@(private)
pick_provider :: proc(relay: ^Relay($Input, $PLAYERS), joiner: int) -> int {
	for other in 0 ..< PLAYERS {
		if other != joiner &&
		   relay.connected[other] &&
		   relay.welcomed[other] &&
		   relay.base_known[other] &&
		   !relay.checking[other] &&
		   relay.provider[other] < 0 &&
		   other not_in relay.refused[joiner] {
			return other
		}
	}
	return -1
}

@(private)
request_snapshot :: proc(relay: ^Relay($Input, $PLAYERS), joiner, provider: int, now: i64) {
	relay.provider[joiner] = provider
	relay.snap_total[joiner] = 0
	relay.snap_sent[joiner] = 0
	writer := msg_begin(&relay.w, .Snap_Request)
	wire.w_u8(writer, u8(joiner))
	wire.w_u32(writer, relay.snap_min[joiner])
	relay_send(relay, provider, writer, .Reliable, now)
}

// The joiner's snapshot didn't get through (its provider left) or failed the check: ask another player, or refuse
// the joiner.
@(private)
restart_snapshot :: proc(relay: ^Relay($Input, $PLAYERS), joiner: int, why: string, now: i64) {
	relay.provider[joiner] = -1
	relay.checking[joiner] = false
	relay.base_known[joiner] = false
	relay.client_ack[joiner] = 0
	relay.report_from[joiner] = NO_REPORTS
	if provider := pick_provider(relay, joiner); provider >= 0 {
		request_snapshot(relay, joiner, provider, now)
		relay_log(relay, "player %d: %s, asking player %d", joiner, why, provider)
		return
	}
	relay_log(relay, "player %d: %s, and nobody else can send a snapshot", joiner, why)
	refuse_player(relay, joiner, card(relay.refused[joiner]) > 0 ? .Bad_Snapshot : .No_Snapshot, now)
}

@(private)
have_input :: #force_inline proc(relay: ^Relay($Input, $PLAYERS), player: int, tick: u32) -> bool {
	return relay.input_tick[player][tick % INPUT_RING] == tick
}

@(private)
on_inputs :: proc(relay: ^Relay($Input, $PLAYERS), player: int, reader: ^wire.Reader, now: i64) {
	client_time := r_i64(reader)
	finalized_ack := wire.r_u32(reader)
	first := wire.r_u32(reader)
	count := u32(wire.r_u8(reader))
	if !reader.ok {
		return
	}
	relay.echo_time[player] = client_time
	relay.echo_recv[player] = now
	if relay.base_known[player] {
		relay.client_ack[player] = max(relay.client_ack[player], min(finalized_ack, relay.finalized))
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
		   tick < relay.active_from[player] ||
		   have_input(relay, player, tick) {
			continue // late inputs for finalized ticks are dropped; the first copy of a tick wins
		}
		relay.inputs[player][tick % INPUT_RING] = input
		relay.input_tick[player][tick % INPUT_RING] = tick
	}
	for have_input(relay, player, relay.recv_upto[player] + 1) {
		relay.recv_upto[player] += 1
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
		if seq <= relay.cmd_recv[player] {
			continue
		}
		if seq != relay.cmd_recv[player] + 1 || len(relay.cmd_wait[player]) >= COMMAND_QUEUE {
			return // a gap (never from an honest client) or a flood: the rest comes again
		}
		waiting := Wait_Command {
			// a wanted tick far ahead would hold back the sender's later commands: clamp it
			want = min(want, relay.finalized + INPUT_RING),
			cmd = {
				kind = kind,
				slot = u8(player),
				size = u8(size),
			},
		}
		copy(waiting.cmd.data[:], bytes)
		append(&relay.cmd_wait[player], waiting)
		relay.cmd_recv[player] = seq
	}
}

@(private)
on_checksum :: proc(relay: ^Relay($Input, $PLAYERS), player: int, reader: ^wire.Reader, now: i64) {
	_ = wire.r_u8(reader) // the sender's player; the relay knows it
	tick := wire.r_u32(reader)
	value := wire.r_u64(reader)
	if !reader.ok || tick % CHECKSUM_EVERY != 0 || tick == 0 {
		return
	}
	if relay.checking[player] {
		// A joiner's first checksum is of its restored snapshot; judge_snapshots compares it.
		if tick == relay.snap_tick[player] && !relay.snap_have[player] {
			relay.snap_value[player] = value
			relay.snap_have[player] = true
		}
		return
	}
	if tick < relay.report_from[player] || tick > relay.finalized {
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
		// A late report (a player catching up): measured against the majority already known.
		if value != check.majority {
			report_desync(relay, tick, {player}, now)
		}
		return
	}
	check.values[player] = value
	check.have += {player}
}

// The players expected to report `tick`'s checksum: connected, streamed to, past their snapshot check, and
// reporting from that tick on.
@(private)
expected_reports :: proc(relay: ^Relay($Input, $PLAYERS), tick: u32) -> (expected: sim.Slots) {
	for player in 0 ..< PLAYERS {
		if relay.connected[player] &&
		   relay.welcomed[player] &&
		   relay.base_known[player] &&
		   !relay.checking[player] &&
		   relay.report_from[player] <= tick {
			expected += {player}
		}
	}
	return
}

// Judges the checksum ticks whose reports are in (or waited for long enough): the majority value (ties: the lowest
// player's, so with 2 players player 0, the host, wins), and a desync when anyone differs from it.
@(private)
judge_checks :: proc(relay: ^Relay($Input, $PLAYERS), now: i64) {
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
		for player in 0 ..< PLAYERS {
			if player not_in check.have {
				continue
			}
			votes := 0
			for other in 0 ..< PLAYERS {
				if other in check.have && check.values[other] == check.values[player] {
					votes += 1
				}
			}
			if votes > best {
				best = votes
				check.majority = check.values[player]
			}
		}
		diverged: sim.Slots
		for player in 0 ..< PLAYERS {
			if player in check.have && check.values[player] != check.majority {
				diverged += {player}
			}
		}
		if diverged != {} {
			report_desync(relay, check.tick, diverged, now)
		}
	}
}

// The majority's checksum of `tick`, once judged.
@(private)
majority_of :: proc(relay: ^Relay($Input, $PLAYERS), tick: u32) -> (value: u64, judged: bool) {
	check := &relay.checks[(tick / CHECKSUM_EVERY) % CHECK_RING]
	if check.tick != tick || !check.judged || check.have == {} {
		return
	}
	return check.majority, true
}

// Joiners whose restored snapshot's checksum is in: once the others' majority for that tick is known, the joiner
// plays (Snap_Ok) or gets a snapshot from someone else.
@(private)
judge_snapshots :: proc(relay: ^Relay($Input, $PLAYERS), now: i64) {
	wait := ms_ticks(relay, CHECK_WAIT_MS)
	for joiner in 0 ..< PLAYERS {
		if !relay.checking[joiner] || !relay.snap_have[joiner] {
			continue
		}
		tick := relay.snap_tick[joiner]
		majority, judged := majority_of(relay, tick)
		if !judged {
			check := &relay.checks[(tick / CHECKSUM_EVERY) % CHECK_RING]
			if (check.tick == tick || check.tick < tick) && relay.clock < tick + 2 * wait {
				continue // the reports are on their way
			}
			// Nobody reported the tick (or it left the ring): nothing to compare with.
			relay_log(relay, "player %d: snapshot of tick %d not checked: no other checksum of it", joiner, tick)
			majority = relay.snap_value[joiner]
		}
		if relay.snap_value[joiner] != majority {
			relay.refused[joiner] += {relay.snap_from[joiner]}
			restart_snapshot(
				relay,
				joiner,
				fmt.tprintf(
					"the snapshot of tick %d from player %d differs from the others",
					tick,
					relay.snap_from[joiner],
				),
				now,
			)
			continue
		}
		relay.checking[joiner] = false
		relay.report_from[joiner] = max(relay.active_from[joiner], tick + 1)
		writer := msg_begin(&relay.w, .Snap_Ok)
		wire.w_u32(writer, tick)
		relay_send(relay, joiner, writer, .Reliable, now)
	}
}

// A desync on `tick`: counted and logged; told to every client, after the typed report's snapshots (when the
// relay has a desync_diff and this is the session's first desync) or at once.
@(private)
report_desync :: proc(relay: ^Relay($Input, $PLAYERS), tick: u32, diverged: sim.Slots, now: i64) {
	relay.desyncs += 1
	relay_log(relay, "DESYNC at tick %d: players %v differ from the majority", tick, diverged)
	report := Desync_Report {
		tick     = tick,
		diverged = diverged,
	}
	if relay.desyncs == 1 {
		relay.first_desync = report
	}
	if relay.cfg.desync_diff != nil && !relay.detailed && !relay.pending_on {
		check := &relay.checks[(tick / CHECKSUM_EVERY) % CHECK_RING]
		majority_player, diverged_player := -1, -1
		for player in 0 ..< PLAYERS {
			if player in check.have && relay.connected[player] {
				if player in diverged && diverged_player < 0 {
					diverged_player = player
				} else if player not_in diverged && majority_player < 0 {
					majority_player = player
				}
			}
		}
		if check.tick == tick && majority_player >= 0 && diverged_player >= 0 {
			relay.detailed = true
			relay.pending_on = true
			relay.pending_tick = tick
			relay.pending_us = now
			for &pending, k in relay.pending {
				clear(&pending.image)
				pending.player = k == 0 ? majority_player : diverged_player
				pending.total = 0
				pending.done = false
				writer := msg_begin(&relay.w, .Snap_Request)
				wire.w_u8(writer, RELAY_TARGET)
				wire.w_u32(writer, tick)
				relay_send(relay, pending.player, writer, .Reliable, now)
			}
			inject_at(&relay.reports, 0, report) // first in the queue: it goes out with its detail
			return
		}
	}
	append(&relay.reports, report)
}

// Sends the queued desync reports, once a typed report has its snapshots (or gave up waiting for them).
@(private)
send_reports :: proc(relay: ^Relay($Input, $PLAYERS), now: i64) {
	if relay.pending_on {
		if !(relay.pending[0].done && relay.pending[1].done) && now - relay.pending_us < IMAGE_WAIT_MS * 1000 {
			return
		}
		detail := "the snapshots of that tick were not available"
		if relay.pending[0].done && relay.pending[1].done && relay.pending[0].total > 0 && relay.pending[1].total > 0 {
			detail = relay.cfg.desync_diff(relay.pending[0].image[:], relay.pending[1].image[:])
			if detail == "" {
				detail = "the two snapshots are the same"
			}
		}
		relay.reports[0].detail = strings.clone(detail)
		if relay.first_desync.tick == relay.reports[0].tick && relay.first_desync.detail == "" {
			relay.first_desync.detail = strings.clone(detail)
		}
		relay_log(relay, "desync at tick %d: %s", relay.reports[0].tick, detail)
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
		for player in 0 ..< PLAYERS {
			if relay.connected[player] && relay.welcomed[player] {
				relay_send(relay, player, writer, .Reliable, now)
			}
		}
		delete(report.detail)
	}
	clear(&relay.reports)
}

// A typed desync report's snapshot coming in from one of the two players asked.
@(private)
take_image :: proc(relay: ^Relay($Input, $PLAYERS), player: int, kind: Msg, reader: ^wire.Reader) {
	if !relay.pending_on {
		return
	}
	for &pending in relay.pending {
		if pending.player != player || pending.done {
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
active :: proc(relay: ^Relay($Input, $PLAYERS), player: int, tick: u32) -> bool {
	return relay.active_from[player] != 0 && tick >= relay.active_from[player] && relay.connected[player]
}

@(private)
finalize :: proc(relay: ^Relay($Input, $PLAYERS)) {
	for relay.cfg.ticks == 0 || relay.finalized < relay.cfg.ticks {
		tick := relay.finalized + 1
		anyone := false
		for player in 0 ..< PLAYERS {
			if !active(relay, player, tick) {
				continue
			}
			anyone = true
			if !have_input(relay, player, tick) && relay.clock < tick + relay.tm.tolerance {
				return
			}
		}
		if !anyone && tick > relay.clock {
			return // nobody plays: empty ticks keep pace with the clock, never run ahead of it
		}
		tick_inputs := &relay.ring[tick % RELAY_RING]
		previous := relay_tick(relay, tick - 1)
		tick_inputs^ = {}
		for player in 0 ..< PLAYERS {
			if !active(relay, player, tick) {
				continue
			}
			tick_inputs.present += {player}
			if tick == relay.active_from[player] {
				tick_inputs.member[player] = relay.member_of[player] // the join record
			}
			if have_input(relay, player, tick) {
				tick_inputs.input[player] = relay.inputs[player][tick % INPUT_RING]
			} else {
				if previous != nil && player in previous.present {
					tick_inputs.input[player] = previous.input[player]
				} // else just joined: there is no previous input to repeat
				tick_inputs.replaced += {player}
				relay.replaced += 1
			}
		}
		take_commands(relay, tick, tick_inputs)
		sim.log_stream_tick(&relay.recording, tick_inputs)
		relay.finalized = tick
	}
}

// Puts the waiting commands that are due into `tick`: each present player's in seq order, those sent for
// it or earlier, at most COMMANDS_PER_PLAYER each and TICK_COMMANDS in all, within the bytes a tick may
// carry (round-robin over the players, so one can't crowd the others out). The rest wait for the next tick.
@(private)
take_commands :: proc(relay: ^Relay($Input, $PLAYERS), tick: u32, tick_inputs: ^sim.Inputs(Input, PLAYERS)) {
	taken: [PLAYERS]int
	total, bytes := 0, 0
	budget := tick_command_budget(Input, PLAYERS)
	for k in 0 ..< sim.COMMANDS_PER_PLAYER {
		for player in 0 ..< PLAYERS {
			waiting := &relay.cmd_wait[player]
			if taken[player] != k || k >= len(waiting) || !active(relay, player, tick) || waiting[k].want > tick {
				continue
			}
			size := sim.COMMAND_HEAD + int(waiting[k].cmd.size)
			if total == sim.TICK_COMMANDS || bytes + size > budget {
				continue
			}
			taken[player] += 1
			total += 1
			bytes += size
		}
	}
	if total == 0 {
		return
	}
	for player in 0 ..< PLAYERS {
		waiting := &relay.cmd_wait[player]
		for k in 0 ..< taken[player] {
			tick_inputs.commands[tick_inputs.command_count] = waiting[k].cmd
			tick_inputs.command_count += 1
		}
		remove_range(waiting, 0, taken[player])
	}
}

@(private)
broadcast :: proc(relay: ^Relay($Input, $PLAYERS), now: i64) {
	window := u32(WINDOW_MAX)
	relay.broadcast_us = now
	relay.broadcast_to = relay.finalized
	for player in 0 ..< PLAYERS {
		if !relay.welcomed[player] || !relay.connected[player] {
			continue
		}
		writer := msg_begin(&relay.w, .Finalized)
		// Relay time: when tick 0 was due, so negative during the lead.
		w_i64(writer, i64(f64(now - relay.welcome_us) - f64(relay.lead) * relay.tm.tick_us))
		w_i64(writer, relay.echo_time[player])
		w_i64(writer, relay.echo_time[player] != 0 ? now - relay.echo_recv[player] : 0)
		wire.w_u32(writer, max(relay.recv_upto[player], relay.finalized))
		wire.w_u32(writer, relay.cmd_recv[player])
		first := relay.client_ack[player] + 1
		last := first - 1
		if relay.base_known[player] {
			// A backlog longer than a window (catching up after a stall, a late join) goes out one
			// window per broadcast in turn, so it streams at a window per tick instead of a window
			// per round trip.
			backlog := min(relay.finalized + 1 - first, CATCHUP_TICKS)
			if windows := (backlog + window - 1) / window; windows > 1 {
				relay.rotate[player] = (relay.rotate[player] + 1) % windows
				first += relay.rotate[player] * window
			}
			last = min(relay.finalized, first + window - 1)
		}
		wire.w_u32(writer, first)
		count_at := len(writer.buf)
		wire.w_u8(writer, 0)
		written := 0
		base: ^sim.Inputs(Input, PLAYERS) // the tick before in this packet (nil: the empty tick)
		for tick := first; tick <= last; tick += 1 {
			tick_inputs := relay_tick(relay, tick)
			if tick_inputs == nil {
				break
			}
			// Ticks with commands or many changes are larger: stop at the message limit (every tick alone
			// fits, see tick_command_budget), the rest goes in a later packet.
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
		relay_send(relay, player, writer, .Unreliable, now)
	}
}

// Sends a member's roster entry to every connected client (or only to slot `to`).
@(private)
send_roster_entry :: proc(relay: ^Relay($Input, $PLAYERS), member: int, now: i64, to := -1) {
	writer := msg_begin(&relay.w, .Roster)
	w_roster_entry(writer, &relay.members[member].entry)
	for player in 0 ..< PLAYERS {
		if relay.connected[player] && (to < 0 || to == player) {
			relay_send(relay, player, writer, .Reliable, now)
		}
	}
}

@(private)
player_gone :: proc(relay: ^Relay($Input, $PLAYERS), player: int, why: string, now: i64) {
	relay.connected[player] = false
	relay.welcomed[player] = false
	relay.checking[player] = false
	relay.player_of[relay.peer_of[player]] = -1
	relay.peer_of[player] = -1
	relay.provider[player] = -1
	relay.report_from[player] = NO_REPORTS
	clear(&relay.cmd_wait[player]) // a left player's commands that never reached a tick go with it
	member := int(relay.member_of[player])
	relay.member_of[player] = NO_MEMBER
	relay_log(relay, "member %d (slot %d) %s", member, player, why)
	if member != int(NO_MEMBER) {
		entry := &relay.members[member - 1].entry
		entry.slot = NO_SLOT
		entry.connected = false
		send_roster_entry(relay, member - 1, now) // the entry stays: a "left" message can still name them
	}
	for &pending in relay.pending {
		if relay.pending_on && pending.player == player {
			pending.done = true
		}
	}
	for other in 0 ..< PLAYERS {
		if relay.provider[other] == player && relay.connected[other] {
			restart_snapshot(relay, other, fmt.tprintf("snapshot provider %d left", player), now)
		}
	}
}

@(private)
handle_relay_msg :: proc(relay: ^Relay($Input, $PLAYERS), peer: Peer, data: []u8, now: i64) {
	reader := wire.reader_make(data)
	kind := Msg(wire.r_u8(&reader))
	if kind == .Hello {
		on_hello(relay, peer, &reader, now)
		return
	}
	player := relay.player_of[peer]
	if player < 0 {
		return
	}
	#partial switch kind {
	case .Inputs:
		if int(wire.r_u8(&reader)) == player {
			on_inputs(relay, player, &reader, now)
		}
	case .Checksum:
		on_checksum(relay, player, &reader, now)
	case .Snap_Begin, .Snap_Chunk:
		forward_snapshot(relay, player, kind, &reader, data, now)
	case .Done:
		relay.done[player] = true
	case .Leave:
		player_gone(relay, player, "left", now)
		channel_drop(relay.ch, peer)
	}
}

// Forwards a snapshot message from the provider the relay asked (anything else is dropped), or takes a desync
// report's snapshot.
@(private)
forward_snapshot :: proc(
	relay: ^Relay($Input, $PLAYERS),
	player: int,
	kind: Msg,
	reader: ^wire.Reader,
	data: []u8,
	now: i64,
) {
	target := wire.r_u8(reader)
	if reader.ok && target == RELAY_TARGET {
		take_image(relay, player, kind, reader)
		return
	}
	joiner := int(target)
	if !reader.ok ||
	   joiner >= PLAYERS ||
	   relay.peer_of[joiner] < 0 ||
	   relay.provider[joiner] != player ||
	   len(data) > MAX_MESSAGE {
		return
	}
	if kind == .Snap_Begin {
		tick := wire.r_u32(reader)
		total := wire.r_u32(reader)
		// A snapshot of a checksum tick (the joiner's checksum of it is compared with the others'), still in the
		// ring (the ticks after it are streamed from there).
		if !reader.ok ||
		   tick < relay.snap_min[joiner] ||
		   tick % CHECKSUM_EVERY != 0 ||
		   relay_tick(relay, tick) == nil ||
		   total == 0 {
			return
		}
		relay.snap_total[joiner] = total
		relay.snap_sent[joiner] = 0
		relay.snap_tick[joiner] = tick
		relay.snap_from[joiner] = player
		relay.snap_have[joiner] = false
		// Stream finalized ticks from the snapshot's tick on (that tick's inputs seed the joiner's
		// prediction of the others).
		relay.client_ack[joiner] = tick - 1
		relay.base_known[joiner] = true
		relay_log(relay, "forwarding player %d's snapshot of tick %d to player %d", player, tick, joiner)
	} else {
		offset := wire.r_u32(reader)
		size := u32(len(reader.data) - reader.pos)
		if !reader.ok ||
		   relay.snap_total[joiner] == 0 ||
		   offset != relay.snap_sent[joiner] ||
		   size > relay.snap_total[joiner] - offset {
			return
		}
		relay.snap_sent[joiner] += size
		if relay.snap_sent[joiner] == relay.snap_total[joiner] {
			// Complete: the joiner restores it and sends its checksum, which judge_snapshots checks.
			relay.provider[joiner] = -1
			relay.checking[joiner] = true
		}
	}
	channel_send(relay.ch, relay.peer_of[joiner], data, .Reliable, now)
}

// One step of the relay: receive, advance the clock, finalize, broadcast, judge checksums, flush. Returns when it
// wants to run next (a now_us value): the next clock tick, or sooner to poll the links.
relay_step :: proc(relay: ^Relay($Input, $PLAYERS), now: i64) -> (wake_us: i64) {
	for event in channel_poll(relay.ch, now) {
		switch event.kind {
		case .Connected:
		case .Disconnected:
			if player := relay.player_of[event.peer]; player >= 0 {
				player_gone(relay, player, "disconnected", now)
			}
		case .Message:
			handle_relay_msg(relay, event.peer, event.data, now)
		}
	}
	if relay.started && !relay.finished {
		relay.beats = u32(f64(now - relay.welcome_us) / relay.tm.tick_us)
		relay.clock = relay.beats > relay.lead ? relay.beats - relay.lead : 0
		sync.atomic_store(&relay.clock_pub, relay.clock)
		finalize(relay)
		// A client whose unacked ticks left the ring can't be streamed to any more.
		for player in 0 ..< PLAYERS {
			if relay.connected[player] &&
			   relay.base_known[player] &&
			   relay.finalized - relay.client_ack[player] > RELAY_RING {
				refuse_player(relay, player, .Too_Far_Behind, now)
			}
		}
		if broadcast_due(relay, now) {
			broadcast(relay, now)
		}
		judge_checks(relay, now)
		judge_snapshots(relay, now)
		send_reports(relay, now)
	}
	if !relay.ending && relay.started && relay.cfg.ticks != 0 && relay.finalized == relay.cfg.ticks {
		all_done := true
		for player in 0 ..< PLAYERS {
			if relay.welcomed[player] && relay.connected[player] && !relay.done[player] {
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
		for player in 0 ..< PLAYERS {
			if relay.peer_of[player] >= 0 && !channel_idle(relay.ch, relay.peer_of[player]) {
				idle = false
			}
		}
		relay.finished = idle || now - relay.end_us > 3_000_000
	}
	wake_us = now + relay.cfg.poll_us
	if relay.started {
		wake_us = min(wake_us, relay.welcome_us + i64(f64(relay.beats + 1) * relay.tm.tick_us) + 1)
		if relay.finalized != relay.broadcast_to {
			wake_us = min(wake_us, relay.broadcast_us + i64(BROADCAST_GAP * relay.tm.tick_us) + 1) // a held broadcast
		}
	}
	return
}

// Whether the Finalized broadcast goes out now: newly finalized ticks, at most once per BROADCAST_GAP (#246: under
// jitter the players' inputs arrive apart and each arrival can finalize a tick), and a heartbeat when nothing was
// finalized for a tick (during the lead too: the clients time their clocks from these).
@(private)
broadcast_due :: proc(relay: ^Relay($Input, $PLAYERS), now: i64) -> bool {
	since := f64(now - relay.broadcast_us)
	return(
		since >= relay.tm.tick_us ||
		(relay.finalized != relay.broadcast_to && since >= BROADCAST_GAP * relay.tm.tick_us) \
	)
}
