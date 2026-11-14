// Relay <-> client messages and the timing constants. Each message starts with a u8 type; fields
// are little-endian with explicit sizes; inputs travel as the game's plain-data bytes.
package netcode

import "unified:sim"
import "unified:wire"

// 4: datagram epochs (channel.odin); 5: compat derived by default, snapshot restart, reliable window; 6: commands;
// 7: snapshots v4, checksums cover Box3D's whole state; 8: a relay time below 0 (the start lead) before tick 0;
// 9: the #8 sitting: adaptive input delay, snapshots of checksum ticks checked against the majority (Snap_Ok),
// desync reports (Desync, Welcome's flags), no replay from tick 0 (new reject reasons).
PROTOCOL_VERSION :: 9
NAME_MAX :: 31 // bytes of a player name (UTF-8, truncated)

// Real-time constants are in milliseconds and converted with the game's tick length.
TOLERANCE_MS :: 100 // relay hard tolerance: a tick is finalized at the latest this long after it is due
MAX_DELAY_MS :: 100 // input delay ceiling
DELAY_MARGIN_US :: 8_000 // how early an input should reach the relay (want_delay, stamp_ahead)
INPUTS_MAX :: 32 // own inputs resent per client packet
COMMAND_QUEUE :: 64 // own commands a client holds until they are verified (more: the send fails)
WINDOW_MAX :: 32 // finalized ticks resent per relay packet
CHECKSUM_EVERY :: sim.DEEP_CHECKSUM_EVERY // the ticks whose checksums cover every extra's whole state
CATCHUP_TICKS :: 384 // unacked finalized ticks a relay streams ahead of a client (< FIN_RING - 64)
SNAP_CHUNK :: 1000
RELAY_TARGET :: u8(0xFE) // a Snap_Request's or Snap_Begin's target: the relay itself (a desync report's snapshot)
DESYNC_IMAGES :: 8 // checksum-tick snapshots a client keeps for desync reports (Welcome's Keep_Images)
DEFAULT_POLL_US :: 1000 // how often a step wants to run between deadlines, to receive packets
ANY_PLAYER :: u8(0xFF)

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
// above max_delay. clamp(ceil((rtt + 8 ms) / tick) + 1 − cap, min_delay, max_delay).
want_delay :: proc(rtt_us: f64, timing: Timing, min_delay: u32 = 1) -> u32 {
	needed := i64(ceil_ticks(rtt_us + DELAY_MARGIN_US, timing.tick_us)) + 1 - i64(timing.prediction_cap)
	floor := max(min_delay, 1)
	return u32(clamp(needed, i64(floor), i64(max(timing.max_delay, floor))))
}

Msg :: enum u8 {
	Hello = 1, // c->r R: protocol u16, player u8 (ANY_PLAYER: any), join tick u32 (0: at start), compat u64, name len u8 + bytes
	Welcome, // r->c R: player u8, seed u64, tick_hz u16, ticks u32 (0: endless), first tick u32, flags u8 (Welcome_Flags)
	Reject, // r->c R: reason u8
	// c->r U: player u8, client time i64 µs, finalized ack u32, first tick u32, count u8, inputs; then the
	// unacked commands: first seq u32, count u8, per command: wanted tick u32, kind u8, size u8, bytes
	Inputs,
	// r->c U: relay time i64, echo i64, hold i64, input ack u32, command ack u32, first u32, count u8, ticks
	// (sim.write_tick: present, replaced, inputs, commands)
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
	Roster, // r->c R: players u8, then per player: connected u8, name len u8 + bytes
	Snap_Ok, // r->c R: tick u32: the joiner's restored snapshot matches the others' checksum of that tick
	Desync, // r->c R: tick u32, diverged u32 (sim.Players), detail len u16 + bytes ("" unless typed reports are on)
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

name_of :: proc(text: string) -> (name: Player_Name) {
	name.len = u8(copy(name.bytes[:], text)) // a cut may split a UTF-8 sequence; names are display-only
	return
}

name_string :: proc(name: ^Player_Name) -> string {
	return string(name.bytes[:name.len])
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

// Finalized ticks per relay packet: as many empty ticks (no commands) as fit one message, at most
// WINDOW_MAX. A packet carries fewer when the ticks hold commands.
@(private)
finalized_window :: proc($Input: typeid, $PLAYERS: int) -> u32 {
	ticks := (MAX_MESSAGE - FINALIZED_HEAD) / sim.tick_bytes(Input, PLAYERS, nil)
	assert(ticks >= 1, "one tick of inputs does not fit a datagram")
	return u32(min(ticks, WINDOW_MAX))
}

// The bytes a finalized tick's commands may take, so that the tick alone always fits one message.
@(private)
tick_command_budget :: proc($Input: typeid, $PLAYERS: int) -> int {
	budget := MAX_MESSAGE - FINALIZED_HEAD - sim.tick_bytes(Input, PLAYERS, nil)
	assert(budget >= sim.COMMAND_HEAD + sim.COMMAND_MAX, "a tick with one command does not fit a datagram")
	return budget
}

// Own inputs per client packet: what fits one message next to at least one command of the largest size.
@(private)
inputs_window :: proc($Input: typeid) -> u32 {
	room := MAX_MESSAGE - INPUTS_HEAD - COMMANDS_HEAD - COMMAND_SEND_HEAD - sim.COMMAND_MAX
	return u32(min(room / size_of(Input), INPUTS_MAX))
}

clone_bytes :: proc(bytes: []u8, allocator := context.allocator) -> []u8 {
	clone := make([]u8, len(bytes), allocator)
	copy(clone, bytes)
	return clone
}
