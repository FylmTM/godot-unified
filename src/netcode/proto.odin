// Relay <-> client messages and the timing constants. Each message starts with a u8 type; fields
// are little-endian with explicit sizes; inputs travel as the game's plain-data bytes.
package netcode

import "core:fmt"

import "unified:sim"
import "unified:wire"

// Bump on any wire change: a datagram, a message, the snapshots a late joiner gets (the sim-change skill). Every
// datagram starts with it (channel.odin), so peers on two versions never parse each other's messages.
PROTOCOL_VERSION :: 20
#assert(PROTOCOL_VERSION < 0x80) // the datagram's first byte: 0x80 | PROTOCOL_VERSION
NAME_MAX :: 31 // bytes of a player name (UTF-8, truncated)
PLATFORM_MAX :: 15 // bytes of an account's platform name ("eos")
ACCOUNT_MAX :: 63 // bytes of an account id (an EOS product user id: 32)
TOKEN_SIZE :: 16
NO_MEMBER :: u16(0)

// Real-time constants are in milliseconds and converted with the game's tick length.
TOLERANCE_MS :: 100 // relay hard tolerance: a tick is finalized at the latest this long after it is due
MAX_DELAY_MS :: 100 // input delay ceiling
DELAY_MARGIN_US :: 8_000 // how early an input should reach the relay (want_delay, stamp_ahead)
@(private)
INPUTS_MAX :: 32 // own inputs resent per client packet
COMMAND_QUEUE :: 64 // own commands a client holds until they are verified (more: the send fails)
WINDOW_MAX :: 32 // finalized ticks resent per relay packet (fewer when they don't fit)
CHECKSUM_EVERY :: sim.DEEP_CHECKSUM_EVERY // the ticks whose checksums cover every extra's whole state
@(private)
CATCHUP_TICKS :: 384 // unacked finalized ticks a relay streams ahead of a client (< FIN_RING - 64)
SNAP_CHUNK :: MAX_MESSAGE - 6 // a Snap_Chunk's bytes: what fits next to its type, target and offset
RELAY_TARGET :: u8(0xFE) // a Snap_Request's or Snap_Begin's target: the relay itself (a desync report's snapshot)
@(private)
DESYNC_IMAGES :: 8 // checksum-tick snapshots a client keeps for desync reports (Welcome's Keep_Images)
@(private)
POLL_US :: 1000 // how often a step wants to run between deadlines, to receive packets
ANY_SLOT :: u8(0xFF) // Hello: any free slot
@(private)
ALL_LOCALS :: u8(0xFF) // Reject and Leave: the whole connection (else one local player)
NO_SLOT :: sim.NO_SLOT // a roster entry of a member not seated

// What a client on a link that vouches for no account (LAN, direct UDP) is recognized by when it comes back: 16
// random bytes it keeps (the Godot host in user://). All zero: none. Sent in Hello, never forwarded.
Token :: [TOKEN_SIZE]u8

// A token as text: 32 lowercase hex digits (how the Godot host keeps it in user://, and the relay's key for it).
token_text :: proc(token: Token, allocator := context.temp_allocator) -> string {
	digits := "0123456789abcdef"
	text := make([]u8, 2 * TOKEN_SIZE, allocator)
	for value, i in token {
		text[2 * i] = digits[value >> 4]
		text[2 * i + 1] = digits[value & 0xF]
	}
	return string(text)
}

// A token from its text (token_text): false for anything but 32 hex digits, or all zero (none).
token_parse :: proc(text: string) -> (token: Token, ok: bool) {
	digit :: proc(char: u8) -> (value: u8, ok: bool) {
		switch char {
		case '0' ..= '9':
			return char - '0', true
		case 'a' ..= 'f':
			return char - 'a' + 10, true
		case 'A' ..= 'F':
			return char - 'A' + 10, true
		}
		return 0, false
	}
	if len(text) != 2 * TOKEN_SIZE do return {}, false
	for &value, i in token {
		high, high_ok := digit(text[2 * i])
		low, low_ok := digit(text[2 * i + 1])
		if !high_ok || !low_ok do return {}, false
		value = high << 4 | low
	}
	return token, token != {}
}

// Tick timing derived from the game's tick rate.
Timing :: struct {
	tick_hz:        int,
	tick_us:        f64,
	tolerance:      u32, // ticks
	min_delay:      u32, // ticks: the input delay's floor (sim.Game.input_delay_min_ticks, at least 1)
	max_delay:      u32, // ticks: the input delay's ceiling (MAX_DELAY_MS)
	// How far a client may predict past its verified tick: sim.ring_size(tick_hz) - 2, the most the ring
	// allows (a rollback target is always in it): 250 ms at 32 Hz (the ring's floor), 218 ms at 64, 234 ms at
	// 128. A client runs about one round trip plus its input delay ahead of what it has verified, so this
	// bounds the round trip it plays smoothly at (~300 ms at 64 Hz); past it the client stalls every tick.
	prediction_cap: u32,
}

// Converts a duration in microseconds to whole ticks, rounding up (0 for none); the timing formulas use it
// without core:math, which netcode may not import.
ceil_ticks :: proc(us: f64, tick_us: f64) -> u32 {
	ticks := us / tick_us
	if ticks <= 0 {
		return 0
	}
	whole := u32(ticks) // truncation is floor for ticks > 0; netcode stays off core:math (see tests/lint)
	if f64(whole) < ticks {
		whole += 1
	}
	return whole
}

// Derives a game's tick timing (tick length, tolerance, delay floor and ceiling, prediction cap) from its tick rate
// and its least input delay (sim.Game.input_delay_min_ticks; 0: one tick); the relay and each client compute it once
// at creation.
timing_of :: proc(tick_hz: int, input_delay_min_ticks := 0) -> Timing {
	timing := Timing {
		tick_hz   = tick_hz,
		tick_us   = 1_000_000 / f64(tick_hz),
		min_delay = u32(max(input_delay_min_ticks, 1)),
	}
	timing.tolerance = max(ceil_ticks(TOLERANCE_MS * 1000, timing.tick_us), 2)
	timing.max_delay = max(ceil_ticks(MAX_DELAY_MS * 1000, timing.tick_us), 1)
	timing.prediction_cap = u32(sim.ring_size(tick_hz) - 2)
	return timing
}

// How far ahead of the relay clock a client stamps its inputs, in ticks: half a round trip and the margin, so an
// input reaches the relay just before its tick is due. ceil((rtt/2 + 8 ms) / tick).
stamp_ahead :: proc(rtt_us: f64, timing: Timing) -> u32 {
	return ceil_ticks(rtt_us / 2 + DELAY_MARGIN_US, timing.tick_us)
}

// The input delay k in ticks (the lag a player feels) for a round trip: the least that keeps the prediction depth
// (about RTT + ½ − k ticks) inside the cap, never below `min_delay` (the client's: Timing.min_delay) or above
// max_delay. clamp(ceil((rtt + 8 ms) / tick) + 1 − cap, min_delay, max_delay). The client passes the round trip's high
// end (RTT + 4 × its mean deviation), so jitter doesn't push the prediction past the cap.
want_delay :: proc(rtt_us: f64, timing: Timing, min_delay: u32 = 1) -> u32 {
	needed := i64(ceil_ticks(rtt_us + DELAY_MARGIN_US, timing.tick_us)) + 1 - i64(timing.prediction_cap)
	floor := max(min_delay, 1)
	return u32(clamp(needed, i64(floor), i64(max(timing.max_delay, floor))))
}

// The longest round trip a game plays smoothly at, in microseconds: the largest high end (RTT + 4 × its mean
// deviation, what want_delay takes) whose delay stays at the ceiling, so the prediction stays inside the cap.
// (cap + max_delay − 1) ticks − the margin. Past it the client stalls a tick at a time (its inputs still count).
round_trip_ceiling_us :: proc(timing: Timing) -> f64 {
	return f64(timing.prediction_cap + timing.max_delay - 1) * timing.tick_us - DELAY_MARGIN_US
}

// A relay <-> client message's type byte. Each value says its direction (c->r, r->c), its delivery (R reliable, U
// unreliable) and its fields, in order.
Msg :: enum u8 {
	// c->r R: the connection's fields, then the seats it asks for (write_hello): compat u64, token [16]u8, sent at
	// i64 (the client's clock when this Hello first went out: the relay orders one person's tries by it), resume tick
	// u32 and checksum u64 (reserved for resuming from the client's own verified tick; 0: none), seat count u8, then
	// per seat: local u8, slot u8 (ANY_SLOT: any), join tick u32 (0: at start), name len u8 + bytes, profile size u8 +
	// the Profile's bytes
	Hello = 1,
	// r->c R: seed u64, tick_hz u16, ticks u32 (0: endless), flags u8 (Welcome_Flags), setup size u16 + the session's
	// Setup's bytes, resume from u32 (reserved for resuming; 0: none), seat count u8, then per seat granted: local u8,
	// slot u8, member u16, first tick u32 (write_welcome)
	Welcome,
	// r->c R: reason u8, local u8 (ALL_LOCALS: the Hello, the connection; else that local player's Join)
	Reject,
	// c->r U: local u8 (which of the connection's seats), finalized ack u32, first tick u32, count u8, inputs
	// (window_write_input: each its changes from the one before, the first from the zero input); then the unacked
	// commands: first seq u32, count u8, per command: wanted tick u32, kind u8, size u8, bytes. One message per seat.
	Inputs,
	// r->c U: relay time i64, first u32, count u8, seat count u8, per seat of the connection: local u8, input ack u32,
	// command ack u32; then the ticks (window_write_tick: each tick's changes from the one before it in the packet, and
	// its join records)
	Finalized,
	Checksum, // c->r R: tick u32, checksum u64 (a joiner's first: of its restored snapshot)
	// r->c R: target u8 (a joiner, or RELAY_TARGET), min tick u32: for a joiner, the snapshot of the first checksum
	// tick >= min the client verifies; for the relay, the kept snapshot of that checksum tick
	Snap_Request,
	Snap_Begin, // c->r(->c) R: target u8, tick u32, total bytes u32 (to the relay, 0: not kept)
	Snap_Chunk, // c->r(->c) R: target u8, offset u32, bytes
	Done, // c->r R: the client verified the last tick of a fixed-length session
	End, // r->c R: the session is over (or the host left)
	Leave, // c->r R: local u8: that local player leaves (ALL_LOCALS, or its last one: the client leaves)
	// r->c R: one member's entry: member u16, slot u8 (NO_SLOT: none), local u8, connected u8, name, platform, account
	// id (each len u8 + bytes). Sent on every change to everyone connected, and every entry to a newcomer.
	Roster,
	Snap_Ok, // r->c R: tick u32: the joiner's restored snapshot matches the others' checksum of that tick
	Desync, // r->c R: tick u32, diverged u32 (sim.Slots), detail len u16 + bytes ("" unless typed reports are on)
	// c->r R: another local player of a connection that is in: local u8, slot u8 (ANY_SLOT: any), join tick u32,
	// name len u8 + bytes, profile size u8 + bytes (a Hello's seat)
	Join,
	Seated, // r->c R: the answer to a Join: local u8, slot u8, member u16, first tick u32 (a Welcome's seat)
}

// What Welcome asks of the client beyond playing.
Welcome_Flags :: bit_set[enum u8 {
	Keep_Images, // keep the snapshots of the last DESYNC_IMAGES checksum ticks: the relay may ask for one
	Start, // a start client: build tick 0 from the seed and the Setup (else a snapshot comes)
};u8]

LOCAL_MAX :: 4 // the most seats (local players) one connection holds

// One seat a Hello asks for: which of the client's local players, the slot (ANY_SLOT: any free one), the earliest
// tick to become present (0: as soon as possible), the player's name and the Profile's bytes.
@(private)
Seat_Ask :: struct {
	local:     u8,
	slot:      u8,
	join_tick: u32,
	name:      Player_Name,
	profile:   Text(sim.PROFILE_MAX),
}

// What a Hello says (write_hello, read_hello): the connection's fields, then the seats it asks for.
Hello :: struct {
	compat:          u64,
	token:           Token,
	sent_us:         i64, // the client's clock when this Hello first went out
	resume_tick:     u32, // reserved: the client's newest verified tick to resume from (0: none)
	resume_checksum: u64,
	seat_count:      int,
	seats:           [LOCAL_MAX]Seat_Ask,
}

// One seat a Welcome grants: the local player, its slot, its member id and the first tick it is present.
@(private)
Seat_Grant :: struct {
	local:      u8,
	slot:       u8,
	member:     u16,
	first_tick: u32,
}

// What a Welcome says (write_welcome, read_welcome): the session's fields, then the seats granted.
Welcome :: struct {
	seed:        u64,
	tick_hz:     int,
	ticks:       u32, // 0: endless
	flags:       Welcome_Flags,
	setup:       []u8, // the session's Setup's bytes (read_welcome: a view into the message)
	resume_from: u32, // reserved: the tick a resumed connection is streamed from (0: none)
	seat_count:  int,
	seats:       [LOCAL_MAX]Seat_Grant,
}

// Writes a Hello message (its type byte first) into an empty writer. Public for tests (a crafted Hello).
write_hello :: proc(writer: ^wire.Writer, hello: ^Hello) {
	wire.w_u8(writer, u8(Msg.Hello))
	wire.w_u64(writer, hello.compat)
	wire.w_bytes(writer, hello.token[:])
	w_i64(writer, hello.sent_us)
	wire.w_u32(writer, hello.resume_tick)
	wire.w_u64(writer, hello.resume_checksum)
	wire.w_u8(writer, u8(hello.seat_count))
	for &seat in hello.seats[:hello.seat_count] {
		wire.w_u8(writer, seat.local)
		wire.w_u8(writer, seat.slot)
		wire.w_u32(writer, seat.join_tick)
		w_text(writer, &seat.name)
		w_text(writer, &seat.profile)
	}
}

// Reads a Hello after its type byte; false when it is malformed (cut short, no seat or more than LOCAL_MAX, a name or
// profile too long).
@(private)
read_hello :: proc(reader: ^wire.Reader) -> (hello: Hello, ok: bool) {
	hello.compat = wire.r_u64(reader)
	copy(hello.token[:], wire.r_bytes(reader, TOKEN_SIZE))
	hello.sent_us = r_i64(reader)
	hello.resume_tick = wire.r_u32(reader)
	hello.resume_checksum = wire.r_u64(reader)
	hello.seat_count = int(wire.r_u8(reader))
	if !reader.ok || hello.seat_count < 1 || hello.seat_count > LOCAL_MAX {
		return
	}
	for &seat in hello.seats[:hello.seat_count] {
		seat.local = wire.r_u8(reader)
		seat.slot = wire.r_u8(reader)
		seat.join_tick = wire.r_u32(reader)
		seat.name = r_text(reader, NAME_MAX)
		seat.profile = r_text(reader, sim.PROFILE_MAX)
	}
	return hello, reader.ok
}

// Writes a Welcome message (its type byte first) into an empty writer. Public for tests (a crafted Welcome).
write_welcome :: proc(writer: ^wire.Writer, welcome: ^Welcome) {
	wire.w_u8(writer, u8(Msg.Welcome))
	wire.w_u64(writer, welcome.seed)
	wire.w_u16(writer, u16(welcome.tick_hz))
	wire.w_u32(writer, welcome.ticks)
	wire.w_u8(writer, transmute(u8)welcome.flags)
	wire.w_u16(writer, u16(len(welcome.setup)))
	wire.w_bytes(writer, welcome.setup)
	wire.w_u32(writer, welcome.resume_from)
	wire.w_u8(writer, u8(welcome.seat_count))
	for seat in welcome.seats[:welcome.seat_count] {
		wire.w_u8(writer, seat.local)
		wire.w_u8(writer, seat.slot)
		wire.w_u16(writer, seat.member)
		wire.w_u32(writer, seat.first_tick)
	}
}

// Reads a Welcome after its type byte; false when it is malformed (cut short, no seat or more than LOCAL_MAX, a Setup
// over sim.SETUP_MAX bytes).
@(private)
read_welcome :: proc(reader: ^wire.Reader) -> (welcome: Welcome, ok: bool) {
	welcome.seed = wire.r_u64(reader)
	welcome.tick_hz = int(wire.r_u16(reader))
	welcome.ticks = wire.r_u32(reader)
	welcome.flags = transmute(Welcome_Flags)wire.r_u8(reader)
	setup_size := int(wire.r_u16(reader))
	if setup_size > sim.SETUP_MAX {
		return
	}
	welcome.setup = wire.r_bytes(reader, setup_size)
	welcome.resume_from = wire.r_u32(reader)
	welcome.seat_count = int(wire.r_u8(reader))
	if !reader.ok || welcome.seat_count < 1 || welcome.seat_count > LOCAL_MAX {
		return
	}
	for &seat in welcome.seats[:welcome.seat_count] {
		seat.local = wire.r_u8(reader)
		seat.slot = wire.r_u8(reader)
		seat.member = wire.r_u16(reader)
		seat.first_tick = wire.r_u32(reader)
	}
	return welcome, reader.ok
}

// Why the relay refused a Hello, or a client it had seated (Reject). The client fails with it, except Too_Far_Behind,
// which disconnects it.
Reject_Reason :: enum u8 {
	Full = 1,
	Slot_Taken,
	Incompatible,
	Not_Started, // a slot not among the starting ones asked for before the clock started
	No_Snapshot, // a joiner: no other player can send a snapshot (or the one who could left)
	Bad_Snapshot, // a joiner: its snapshot differs from the other players' checksum, and nobody else can send one
	Too_Far_Behind, // the client fell further behind than the relay keeps ticks (RELAY_RING)
	// the same person (account or token) is seated on a connection whose Hello went out later, and it is live: this
	// one is an earlier try whose Hello came late (src/netcode/README.md, Members: newest wins)
	Newer_Connection,
	Closed, // the session takes no new players (relay_set_open; a player who was in may come back)
}

// Short text as fixed bytes (plain data, no allocation): a player's name, an account's platform and id.
Text :: struct($N: int) {
	len:   u8,
	bytes: [N]u8,
}

// A player's display name.
Player_Name :: Text(NAME_MAX)

// Packs text into a Text(N), cut at N bytes (a cut may split a UTF-8 sequence: the texts are display-only).
text_of :: proc($N: int, text: string) -> (out: Text(N)) {
	out.len = u8(copy(out.bytes[:], text))
	return
}

// The text, a view into its bytes (valid while the Text is).
text_string :: proc(text: ^Text($N)) -> string {
	return string(text.bytes[:text.len])
}

// A member's entry in the relay's roster, as clients get it.
Roster_Entry :: struct {
	member:    u16,
	slot:      u8, // NO_SLOT: not seated
	local:     u8, // which of its connection's local players (a second one shares the first one's account)
	connected: bool,
	name:      Player_Name,
	platform:  Text(PLATFORM_MAX), // the account its link vouched for ("": none, as on LAN)
	account:   Text(ACCOUNT_MAX),
}

@(private)
w_text :: proc(writer: ^wire.Writer, text: ^Text($N)) {
	wire.w_u8(writer, text.len)
	wire.w_bytes(writer, text.bytes[:text.len])
}

// A text longer than N fails the reader (never leaves bytes in the stream).
@(private)
r_text :: proc(reader: ^wire.Reader, $N: int) -> (text: Text(N)) {
	size := int(wire.r_u8(reader))
	if size > N {
		reader.ok = false
		return
	}
	copy(text.bytes[:], wire.r_bytes(reader, size))
	text.len = u8(size)
	return
}

@(private)
w_roster_entry :: proc(writer: ^wire.Writer, entry: ^Roster_Entry) {
	wire.w_u16(writer, entry.member)
	wire.w_u8(writer, entry.slot)
	wire.w_u8(writer, entry.local)
	wire.w_u8(writer, u8(entry.connected))
	w_text(writer, &entry.name)
	w_text(writer, &entry.platform)
	w_text(writer, &entry.account)
}

@(private)
r_roster_entry :: proc(reader: ^wire.Reader) -> (entry: Roster_Entry) {
	entry.member = wire.r_u16(reader)
	entry.slot = wire.r_u8(reader)
	entry.local = wire.r_u8(reader)
	entry.connected = wire.r_u8(reader) != 0
	entry.name = r_text(reader, NAME_MAX)
	entry.platform = r_text(reader, PLATFORM_MAX)
	entry.account = r_text(reader, ACCOUNT_MAX)
	return
}

@(private)
msg_begin :: proc(writer: ^wire.Writer, msg: Msg) -> ^wire.Writer {
	clear(&writer.buf)
	wire.w_u8(writer, u8(msg))
	return writer
}

@(private)
w_i64 :: proc(writer: ^wire.Writer, value: i64) {
	wire.w_u64(writer, u64(value))
}

@(private)
r_i64 :: proc(reader: ^wire.Reader) -> i64 {
	return i64(wire.r_u64(reader))
}

@(private)
FINALIZED_HEAD :: 15 // type u8, relay time i64, first u32, count u8, seat count u8 (asserted in finalized_message)
@(private)
FINALIZED_SEAT :: 9 // a seat's acks in a Finalized: local u8, input ack u32, command ack u32
@(private)
FINALIZED_HEAD_MAX :: FINALIZED_HEAD + LOCAL_MAX * FINALIZED_SEAT // what the widths budget for: a full couch
INPUTS_HEAD :: 11 // type u8, local u8, finalized ack u32, first u32, count u8 (asserted in inputs_message)
@(private)
COMMANDS_HEAD :: 5 // first seq u32, count u8
@(private)
COMMAND_SEND_HEAD :: 6 // wanted tick u32, kind u8, size u8

// The fewest ticks at their widest (window_tick_max_bytes: every Input byte changed, a player joining) a Finalized
// message must hold. The relay streams a client one message of ticks per broadcast and a second for ticks no
// broadcast carried yet; fewer ticks per message leave too little room to make up a lost one, and clients on a lossy
// network stall on most ticks.
@(private)
TICKS_PER_MESSAGE_MIN :: 4

// Why the netcode can't play a game ("" when it can; temp-allocated): fewer than TICKS_PER_MESSAGE_MIN of its widest
// ticks fit a Finalized message (its players times its Input's bytes is too wide), or its least input delay is below
// zero or past the delay ceiling. relay_create panics with it; the Godot host reports it with sim.game_violation's.
game_violation :: proc(game: ^$G) -> string {
	Input :: sim.part(G, sim.GAME_INPUT)
	Profile :: sim.part(G, sim.GAME_PROFILE)
	PLAYERS :: sim.part(G, sim.GAME_PLAYERS)
	if reason := delay_violation(game.name, game.tick_hz, game.input_delay_min_ticks); reason != "" {
		return reason
	}
	widest := window_tick_max_bytes(Input, PLAYERS, nil, size_of(Profile))
	return width_violation(game.name, PLAYERS, size_of(Input), widest)
}

// Why a game's least input delay can't be played ("" when it can): below zero, or past the delay ceiling
// (MAX_DELAY_MS in ticks), which the round-trip ceiling and the stamp lead's neighbours are sized against
// (src/netcode/README.md, Timing).
@(private)
delay_violation :: proc(name: string, tick_hz, input_delay_min_ticks: int) -> string {
	ceiling := int(timing_of(tick_hz).max_delay)
	if input_delay_min_ticks >= 0 && input_delay_min_ticks <= ceiling {
		return ""
	}
	return fmt.tprintf(
		"%s: input_delay_min_ticks is %d: it is 0 (one tick) to %d ticks (the %d ms delay ceiling at %d Hz)",
		name,
		input_delay_min_ticks,
		ceiling,
		MAX_DELAY_MS,
		tick_hz,
	)
}

// game_violation's body (a non-generic home for its import: -vet).
@(private)
width_violation :: proc(name: string, players, input_bytes, tick_bytes: int) -> string {
	fit := (MAX_MESSAGE - FINALIZED_HEAD_MAX) / tick_bytes
	if fit >= TICKS_PER_MESSAGE_MIN {
		return ""
	}
	return fmt.tprintf(
		"%s: a tick of %d players with %d-byte Inputs takes up to %d bytes, so %d fit a message and the relay needs %d: fewer players or a narrower Input",
		name,
		players,
		input_bytes,
		tick_bytes,
		fit,
		TICKS_PER_MESSAGE_MIN,
	)
}

// The bytes a finalized tick's commands may take (their count byte aside), so that the tick alone always fits one
// message however much it changed (window_tick_max_bytes, with a Profile of `profile_size` bytes). A packet holds up
// to WINDOW_MAX ticks, as many as fit.
@(private)
tick_command_budget :: proc($Input: typeid, $PLAYERS: int, profile_size: int) -> int {
	budget := MAX_MESSAGE - FINALIZED_HEAD_MAX - window_tick_max_bytes(Input, PLAYERS, nil, profile_size) - 1
	assert(budget >= sim.COMMAND_HEAD + sim.COMMAND_MAX, "a tick with one command does not fit a datagram")
	return budget
}

// Own inputs per client packet: what fits one message next to at least one command of the largest size, every
// input changed.
@(private)
inputs_window :: proc($Input: typeid) -> u32 {
	room := MAX_MESSAGE - INPUTS_HEAD - COMMANDS_HEAD - COMMAND_SEND_HEAD - sim.COMMAND_MAX
	return u32(min(room / window_input_max_bytes(Input), INPUTS_MAX))
}
