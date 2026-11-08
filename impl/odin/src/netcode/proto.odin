// Relay <-> client messages. Each starts with a u8 type; fields are little-endian with explicit
// sizes; an input is 4 bytes (move_x i8, move_z i8, buttons u8, choice u8).
package netcode

import "core:time"

import "../core"
import "../game"

TICK_US :: 16_667 // 60 Hz
TICK_NS :: 16_666_667
TOLERANCE :: 6 // relay hard tolerance, ticks
PREDICTION_CAP :: 10 // ticks a client may run ahead of its verified tick
WINDOW_MAX :: 32 // finalized ticks resent per relay packet
INPUTS_MAX :: 32 // own inputs resent per client packet
CHECKSUM_EVERY :: 16
SNAP_CHUNK :: 1000

Msg :: enum u8 {
	Hello = 1, // c->r R: player u8, join tick u32 (0 = at start)
	Welcome, // r->c R: player u8, seed u32, players u8, ticks u32, first tick u32
	Inputs, // c->r U: player u8, client time i64 µs, finalized ack u32, first tick u32, count u8, inputs
	Finalized, // r->c U: relay time i64 µs, echo i64, hold i64, input ack u32, first u32, count u8, (inputs[4], mask u8)*
	Checksum, // c->r R: player u8, tick u32, checksum u64
	Snap_Request, // r->c R: joiner u8, min tick u32
	Snap_Begin, // c->r->c R: joiner u8, tick u32, total bytes u32
	Snap_Chunk, // c->r->c R: joiner u8, offset u32, bytes
	Done, // c->r R: player u8, final tick u32
	End, // r->c R
}

msg_begin :: proc(m: Msg) -> core.Writer {
	w := core.writer_make(64, context.temp_allocator)
	core.w_u8(&w, u8(m))
	return w
}

w_i64 :: proc(w: ^core.Writer, v: i64) {
	core.w_u64(w, u64(v))
}

r_i64 :: proc(r: ^core.Reader) -> i64 {
	return i64(core.r_u64(r))
}

w_input :: proc(w: ^core.Writer, in_: game.Input) {
	core.w_u8(w, u8(in_.move_x))
	core.w_u8(w, u8(in_.move_z))
	core.w_u8(w, in_.buttons)
	core.w_u8(w, in_.choice)
}

r_input :: proc(r: ^core.Reader) -> (in_: game.Input) {
	in_.move_x = i8(core.r_u8(r))
	in_.move_z = i8(core.r_u8(r))
	in_.buttons = core.r_u8(r)
	in_.choice = core.r_u8(r)
	return
}

// Wall-clock deadline helper.
Stopwatch :: struct {
	start: time.Tick,
}

elapsed_s :: proc(sw: Stopwatch) -> f64 {
	return time.duration_seconds(time.tick_since(sw.start))
}
