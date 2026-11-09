// Relay <-> client messages and the timing constants. Each message starts with a u8 type; fields
// are little-endian with explicit sizes; inputs travel as the game's plain-data bytes.
package netcode

import "unified:sim"
import "unified:wire"

PROTOCOL_VERSION :: 5 // 4: datagram epochs (channel.odin); 5: compat derived by default, snapshot restart, reliable window
NAME_MAX :: 31 // bytes of a player name (UTF-8, truncated)

// Real-time constants are in milliseconds and converted with the game's tick length.
TOLERANCE_MS :: 100 // relay hard tolerance: a tick is finalized at the latest this long after it is due
MAX_DELAY_MS :: 100 // input delay ceiling
DELAY_MARGIN_US :: 8_000 // input delay = ceil((rtt / 2 + margin) / tick)
// How far a client may predict past its verified tick. A client runs about one round trip plus
// its input delay ahead of what it has verified, so this bounds the round trip it plays smoothly
// at: ~300 ms with 218 ms (14 ticks at 64 Hz, the most a sim.RING of 16 allows); past it the
// client stalls every tick. 166 ms stalled most ticks from ~250 ms.
PREDICTION_MS :: 218
INPUTS_MAX :: 32 // own inputs resent per client packet
WINDOW_MAX :: 32 // finalized ticks resent per relay packet
CHECKSUM_EVERY :: 16
CATCHUP_TICKS :: 384 // unacked finalized ticks a relay streams ahead of a client (< FIN_RING - 64)
SNAP_CHUNK :: 1000
DEFAULT_POLL_US :: 1000 // how often a step wants to run between deadlines, to receive packets
ANY_SLOT :: u8(0xFF)

// Tick timing derived from the game's tick rate.
Timing :: struct {
	tick_hz:        int,
	tick_us:        f64,
	tolerance:      u32, // ticks
	max_delay:      u32, // ticks
	prediction_cap: u32, // ticks, < sim.RING - 1 so a rollback target is always in the ring
}

ceil_ticks :: proc(us: f64, tick_us: f64) -> u32 {
	x := us / tick_us
	if x <= 0 {
		return 0
	}
	d := u32(x) // truncation is floor for x > 0; netcode stays off core:math (see tests/lint)
	if f64(d) < x {
		d += 1
	}
	return d
}

timing_of :: proc(tick_hz: int) -> Timing {
	t := Timing {
		tick_hz = tick_hz,
		tick_us = 1_000_000 / f64(tick_hz),
	}
	t.tolerance = max(ceil_ticks(TOLERANCE_MS * 1000, t.tick_us), 2)
	t.max_delay = max(ceil_ticks(MAX_DELAY_MS * 1000, t.tick_us), 1)
	t.prediction_cap = clamp(ceil_ticks(PREDICTION_MS * 1000, t.tick_us), 2, sim.RING - 2)
	return t
}

// Input delay in ticks for a round-trip time: clamp(ceil((rtt/2 + 8 ms) / tick), 1, max_delay).
want_delay :: proc(rtt_us: f64, tm: Timing) -> u32 {
	return clamp(ceil_ticks(rtt_us / 2 + DELAY_MARGIN_US, tm.tick_us), 1, tm.max_delay)
}

Msg :: enum u8 {
	Hello = 1, // c->r R: protocol u16, slot u8 (ANY_SLOT: any), join tick u32 (0: at start), compat u64, name len u8 + bytes
	Welcome, // r->c R: slot u8, seed u64, tick_hz u16, ticks u32 (0: endless), first tick u32
	Reject, // r->c R: reason u8
	Inputs, // c->r U: slot u8, client time i64 µs, finalized ack u32, first tick u32, count u8, inputs
	Finalized, // r->c U: relay time i64, echo i64, hold i64, input ack u32, first u32, count u8, ticks
	Checksum, // c->r R: slot u8, tick u32, checksum u64
	Snap_Request, // r->c R: joiner u8, min tick u32
	Snap_Begin, // c->r->c R: joiner u8, tick u32, total bytes u32 (r->c tick 0, total 0: start from tick 0)
	Snap_Chunk, // c->r->c R: joiner u8, offset u32, bytes
	Done, // c->r R: slot u8, final tick u32 (fixed-length sessions)
	End, // r->c R: the session is over (or the host left)
	Leave, // c->r R: the client leaves its slot
	Roster, // r->c R: slots u8, then per slot: connected u8, name len u8 + bytes
}

Reject_Reason :: enum u8 {
	Full = 1,
	Slot_Taken,
	Incompatible,
	Not_Started, // a non-starting slot asked to join before the clock started
}

// A player name as fixed bytes (plain data, no allocation).
Player_Name :: struct {
	len:   u8,
	bytes: [NAME_MAX]u8,
}

name_of :: proc(s: string) -> (n: Player_Name) {
	n.len = u8(copy(n.bytes[:], s)) // a cut may split a UTF-8 sequence; names are display-only
	return
}

name_string :: proc(n: ^Player_Name) -> string {
	return string(n.bytes[:n.len])
}

@(private)
w_name :: proc(w: ^wire.Writer, n: ^Player_Name) {
	wire.w_u8(w, n.len)
	wire.w_bytes(w, n.bytes[:n.len])
}

@(private)
r_name :: proc(r: ^wire.Reader) -> (n: Player_Name) {
	l := min(int(wire.r_u8(r)), NAME_MAX)
	copy(n.bytes[:], wire.r_bytes(r, l))
	n.len = u8(l)
	return
}

@(private)
msg_begin :: proc(w: ^wire.Writer, m: Msg) -> ^wire.Writer {
	clear(&w.buf)
	wire.w_u8(w, u8(m))
	return w
}

@(private)
w_i64 :: proc(w: ^wire.Writer, v: i64) {
	wire.w_u64(w, u64(v))
}

@(private)
r_i64 :: proc(r: ^wire.Reader) -> i64 {
	return i64(wire.r_u64(r))
}

// Plain data is its own serialization.
@(private)
w_raw :: proc(w: ^wire.Writer, v: ^$T) {
	wire.w_bytes(w, ([^]u8)(v)[:size_of(T)])
}

@(private)
r_raw :: proc(r: ^wire.Reader, $T: typeid) -> (v: T) {
	if b := wire.r_bytes(r, size_of(T)); b != nil {
		copy(([^]u8)(&v)[:size_of(T)], b)
	}
	return
}

UNRELIABLE_CHUNK_OVERHEAD :: 3 // kind u8, len u16
FINALIZED_HEAD :: 34 // type u8, relay time, echo, hold i64, input ack u32, first u32, count u8
INPUTS_HEAD :: 19 // type u8, slot u8, client time i64, finalized ack u32, first u32, count u8

// Finalized ticks per relay packet: as many as fit one datagram, at most WINDOW_MAX.
@(private)
finalized_window :: proc($I: typeid, $P: int) -> u32 {
	per_tick := size_of(sim.Inputs(I, P))
	room := MAX_DATAGRAM - HEADER_BYTES - UNRELIABLE_CHUNK_OVERHEAD - FINALIZED_HEAD
	n := room / per_tick
	assert(n >= 1, "one tick of inputs does not fit a datagram")
	return u32(min(n, WINDOW_MAX))
}

@(private)
inputs_window :: proc($I: typeid) -> u32 {
	room := MAX_DATAGRAM - HEADER_BYTES - UNRELIABLE_CHUNK_OVERHEAD - INPUTS_HEAD
	return u32(min(room / size_of(I), INPUTS_MAX))
}

clone_bytes :: proc(b: []u8, allocator := context.allocator) -> []u8 {
	c := make([]u8, len(b), allocator)
	copy(c, b)
	return c
}
