// Relay <-> client messages and the timing constants. Each message starts with a u8 type; fields
// are little-endian with explicit sizes; inputs travel as the game's plain-data bytes.
package netcode

import "unified:sim"
import "unified:wire"

// 4: datagram epochs (channel.odin); 5: compat derived by default, snapshot restart, reliable window; 6: commands;
// 7: snapshots v4, checksums cover Box3D's whole state; 8: a relay time below 0 (the start lead) before tick 0;
// 9: the #8 sitting: adaptive input delay, snapshots of checksum ticks checked against the majority (Snap_Ok),
// desync reports (Desync, Welcome's flags), no replay from tick 0 (new reject reasons); 10: a Finalized packet's
// ticks as their changes from the tick before (window.odin, #192);
// 11: players are session members (#222): Hello's token, Welcome's member id, join records in finalized ticks, a
// roster entry per member; 12: snapshots v6 (the build's compat in the header), a finalized tick with a slot past
// PLAYERS present or replaced is refused (#233, #255).
PROTOCOL_VERSION :: 12
NAME_MAX :: 31 // bytes of a player name (UTF-8, truncated)
PLATFORM_MAX :: 15 // bytes of an account's platform name ("eos")
ACCOUNT_MAX :: 63 // bytes of an account id (an EOS product user id: 32)
TOKEN_SIZE :: 16
NO_MEMBER :: u16(0)

// Real-time constants are in milliseconds and converted with the game's tick length.
TOLERANCE_MS :: 100 // relay hard tolerance: a tick is finalized at the latest this long after it is due
MAX_DELAY_MS :: 100 // input delay ceiling
DELAY_MARGIN_US :: 8_000 // how early an input should reach the relay (want_delay, stamp_ahead)
INPUTS_MAX :: 32 // own inputs resent per client packet
COMMAND_QUEUE :: 64 // own commands a client holds until they are verified (more: the send fails)
WINDOW_MAX :: 32 // finalized ticks resent per relay packet (fewer when they don't fit)
CHECKSUM_EVERY :: sim.DEEP_CHECKSUM_EVERY // the ticks whose checksums cover every extra's whole state
CATCHUP_TICKS :: 384 // unacked finalized ticks a relay streams ahead of a client (< FIN_RING - 64)
SNAP_CHUNK :: 1000
RELAY_TARGET :: u8(0xFE) // a Snap_Request's or Snap_Begin's target: the relay itself (a desync report's snapshot)
DESYNC_IMAGES :: 8 // checksum-tick snapshots a client keeps for desync reports (Welcome's Keep_Images)
DEFAULT_POLL_US :: 1000 // how often a step wants to run between deadlines, to receive packets
ANY_PLAYER :: u8(0xFF) // Hello: any free slot
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
	max_delay:      u32, // ticks
	// How far a client may predict past its verified tick: sim.ring_size(tick_hz) - 2, the most the ring
	// allows (a rollback target is always in it): ~250 ms of ring, so 187 ms at 32 Hz, 218 ms at 64, 234 ms
	// at 128. A client runs about one round trip plus its input delay ahead of what it has verified, so this
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

// Derives a game's tick timing (tick length, tolerance, delay ceiling, prediction cap) from its tick rate;
// the relay and each client compute it once at creation.
timing_of :: proc(tick_hz: int) -> Timing {
	timing := Timing {
		tick_hz = tick_hz,
		tick_us = 1_000_000 / f64(tick_hz),
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
// (about RTT + ½ − k ticks) inside the cap, never below the game's floor `min_delay` (sim.Game.min_input_delay) or
// above max_delay. clamp(ceil((rtt + 8 ms) / tick) + 1 − cap, min_delay, max_delay). The client passes the round
// trip's high end (RTT + 4 × its mean deviation), so jitter doesn't push the prediction past the cap.
want_delay :: proc(rtt_us: f64, timing: Timing, min_delay: u32 = 1) -> u32 {
	needed := i64(ceil_ticks(rtt_us + DELAY_MARGIN_US, timing.tick_us)) + 1 - i64(timing.prediction_cap)
	floor := max(min_delay, 1)
	return u32(clamp(needed, i64(floor), i64(max(timing.max_delay, floor))))
}

Msg :: enum u8 {
	// c->r R: protocol u16, slot u8 (ANY_PLAYER: any), join tick u32 (0: at start), compat u64, token [16]u8, name len
	// u8 + bytes
	Hello = 1,
	// r->c R: slot u8, member u16, seed u64, tick_hz u16, ticks u32 (0: endless), first tick u32, flags u8
	// (Welcome_Flags)
	Welcome,
	Reject, // r->c R: reason u8
	// c->r U: player u8, client time i64 µs, finalized ack u32, first tick u32, count u8, inputs; then the
	// unacked commands: first seq u32, count u8, per command: wanted tick u32, kind u8, size u8, bytes
	Inputs,
	// r->c U: relay time i64, echo i64, hold i64, input ack u32, command ack u32, first u32, count u8, ticks
	// (window_write_tick: each tick's changes from the one before it in the packet, and its join records)
	Finalized,
	Checksum, // c->r R: player u8, tick u32, checksum u64 (a joiner's first: of its restored snapshot)
	// r->c R: target u8 (a joiner, or RELAY_TARGET), min tick u32: for a joiner, the snapshot of the first checksum
	// tick >= min the client verifies; for the relay, the kept snapshot of that checksum tick
	Snap_Request,
	Snap_Begin, // c->r(->c) R: target u8, tick u32, total bytes u32 (to the relay, 0: not kept)
	Snap_Chunk, // c->r(->c) R: target u8, offset u32, bytes
	Done, // c->r R: player u8, final tick u32 (fixed-length sessions)
	End, // r->c R: the session is over (or the host left)
	Leave, // c->r R: the client leaves its player
	// r->c R: one member's entry: member u16, slot u8 (NO_SLOT: none), connected u8, name, platform, account id (each
	// len u8 + bytes). Sent on every change to everyone connected, and every entry to a newcomer.
	Roster,
	Snap_Ok, // r->c R: tick u32: the joiner's restored snapshot matches the others' checksum of that tick
	Desync, // r->c R: tick u32, diverged u32 (sim.Slots), detail len u16 + bytes ("" unless typed reports are on)
}

Welcome_Flags :: bit_set[enum u8 {
	Keep_Images, // keep the snapshots of the last DESYNC_IMAGES checksum ticks: the relay may ask for one
};u8]

Reject_Reason :: enum u8 {
	Full = 1,
	Player_Taken,
	Incompatible,
	Not_Started, // a player not among the starting ones asked to join before the clock started
	No_Snapshot, // a joiner: no other player can send a snapshot (or the one who could left)
	Bad_Snapshot, // a joiner: its snapshot differs from the other players' checksum, and nobody else can send one
	Too_Far_Behind, // the client fell further behind than the relay keeps ticks (RELAY_RING)
}

// A player name as fixed bytes (plain data, no allocation).
Player_Name :: struct {
	len:   u8,
	bytes: [NAME_MAX]u8,
}

// Packs a display name into a fixed-size Player_Name, cutting it at NAME_MAX bytes, so a Hello stays plain data.
name_of :: proc(text: string) -> (name: Player_Name) {
	name.len = u8(copy(name.bytes[:], text)) // a cut may split a UTF-8 sequence; names are display-only
	return
}

// The name's text, a view into its bytes (valid while the Player_Name is).
name_string :: proc(name: ^Player_Name) -> string {
	return string(name.bytes[:name.len])
}

// Short text as fixed bytes: an account's platform and id in a roster entry.
Text :: struct($N: int) {
	len:   u8,
	bytes: [N]u8,
}

text_of :: proc($N: int, text: string) -> (out: Text(N)) {
	out.len = u8(copy(out.bytes[:], text))
	return
}

text_string :: proc(text: ^Text($N)) -> string {
	return string(text.bytes[:text.len])
}

// A member's entry in the relay's roster, as clients get it.
Roster_Entry :: struct {
	member:    u16,
	slot:      u8, // NO_SLOT: not seated
	connected: bool,
	name:      Player_Name,
	platform:  Text(PLATFORM_MAX), // the account its link vouched for ("": none, as on LAN)
	account:   Text(ACCOUNT_MAX),
}

@(private)
w_name :: proc(writer: ^wire.Writer, name: ^Player_Name) {
	wire.w_u8(writer, name.len)
	wire.w_bytes(writer, name.bytes[:name.len])
}

@(private)
r_name :: proc(reader: ^wire.Reader) -> (name: Player_Name) {
	size := min(int(wire.r_u8(reader)), NAME_MAX)
	copy(name.bytes[:], wire.r_bytes(reader, size))
	name.len = u8(size)
	return
}

@(private)
w_text :: proc(writer: ^wire.Writer, text: ^Text($N)) {
	wire.w_u8(writer, text.len)
	wire.w_bytes(writer, text.bytes[:text.len])
}

@(private)
r_text :: proc(reader: ^wire.Reader, $N: int) -> (text: Text(N)) {
	size := min(int(wire.r_u8(reader)), N)
	copy(text.bytes[:], wire.r_bytes(reader, size))
	text.len = u8(size)
	return
}

@(private)
w_roster_entry :: proc(writer: ^wire.Writer, entry: ^Roster_Entry) {
	wire.w_u16(writer, entry.member)
	wire.w_u8(writer, entry.slot)
	wire.w_u8(writer, u8(entry.connected))
	w_name(writer, &entry.name)
	w_text(writer, &entry.platform)
	w_text(writer, &entry.account)
}

@(private)
r_roster_entry :: proc(reader: ^wire.Reader) -> (entry: Roster_Entry) {
	entry.member = wire.r_u16(reader)
	entry.slot = wire.r_u8(reader)
	entry.connected = wire.r_u8(reader) != 0
	entry.name = r_name(reader)
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

// Plain data is its own serialization.
@(private)
w_raw :: proc(writer: ^wire.Writer, value: ^$Value) {
	wire.w_bytes(writer, ([^]u8)(value)[:size_of(Value)])
}

@(private)
r_raw :: proc(reader: ^wire.Reader, $Value: typeid) -> (value: Value) {
	if bytes := wire.r_bytes(reader, size_of(Value)); bytes != nil {
		copy(([^]u8)(&value)[:size_of(Value)], bytes)
	}
	return
}

FINALIZED_HEAD :: 38 // type u8, relay time, echo, hold i64, input ack u32, command ack u32, first u32, count u8
INPUTS_HEAD :: 19 // type u8, player u8, client time i64, finalized ack u32, first u32, count u8
COMMANDS_HEAD :: 5 // first seq u32, count u8
COMMAND_SEND_HEAD :: 6 // wanted tick u32, kind u8, size u8

// The bytes a finalized tick's commands may take (their count byte aside), so that the tick alone always fits one
// message however much it changed (window_tick_max_bytes). A packet holds up to WINDOW_MAX ticks, as many as fit.
@(private)
tick_command_budget :: proc($Input: typeid, $PLAYERS: int) -> int {
	budget := MAX_MESSAGE - FINALIZED_HEAD - window_tick_max_bytes(Input, PLAYERS, nil) - 1
	assert(budget >= sim.COMMAND_HEAD + sim.COMMAND_MAX, "a tick with one command does not fit a datagram")
	return budget
}

// Own inputs per client packet: what fits one message next to at least one command of the largest size.
@(private)
inputs_window :: proc($Input: typeid) -> u32 {
	room := MAX_MESSAGE - INPUTS_HEAD - COMMANDS_HEAD - COMMAND_SEND_HEAD - sim.COMMAND_MAX
	return u32(min(room / size_of(Input), INPUTS_MAX))
}

// Copies a byte slice into a new one from `allocator`: queued messages and delayed datagrams outlive the buffer
// they came in.
clone_bytes :: proc(bytes: []u8, allocator := context.allocator) -> []u8 {
	clone := make([]u8, len(bytes), allocator)
	copy(clone, bytes)
	return clone
}
