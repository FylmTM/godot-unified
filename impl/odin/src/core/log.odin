// Input log (the replay file, CORE.md §1): "UNIL", version u16, seed u64, player count u8,
// tick count u32, then per tick 4 × (move_x i8, move_z i8, buttons u8, choice u8) and a u8 mask of
// the players whose input the relay replaced.
package core

import "core:os"

import "../game"

LOG_MAGIC :: "UNIL"
LOG_VERSION :: 1

Log_Tick :: struct {
	inputs:   game.Inputs,
	replaced: u8,
}

Input_Log :: struct {
	seed:    u64,
	players: u8, // players active at tick 0
	ticks:   [dynamic]Log_Tick, // ticks[k] holds the inputs of tick k + 1
}

log_encode :: proc(lg: ^Input_Log) -> []u8 {
	w := writer_make(19 + len(lg.ticks) * 17)
	w_bytes(&w, transmute([]u8)string(LOG_MAGIC))
	w_u16(&w, LOG_VERSION)
	w_u64(&w, lg.seed)
	w_u8(&w, lg.players)
	w_u32(&w, u32(len(lg.ticks)))
	for &t in lg.ticks {
		write_inputs(&w, &t.inputs)
		w_u8(&w, t.replaced)
	}
	return w.buf[:]
}

write_inputs :: proc(w: ^Writer, inputs: ^game.Inputs) {
	for in_ in inputs {
		w_u8(w, u8(in_.move_x))
		w_u8(w, u8(in_.move_z))
		w_u8(w, in_.buttons)
		w_u8(w, in_.choice)
	}
}

read_inputs :: proc(r: ^Reader) -> (out: game.Inputs) {
	for &in_ in out {
		in_.move_x = i8(r_u8(r))
		in_.move_z = i8(r_u8(r))
		in_.buttons = r_u8(r)
		in_.choice = r_u8(r)
	}
	return
}

log_write :: proc(path: string, lg: ^Input_Log) -> bool {
	data := log_encode(lg)
	defer delete(data)
	return os.write_entire_file(path, data) == nil
}

log_read :: proc(path: string) -> (lg: Input_Log, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return
	}
	defer delete(data)
	r := reader_make(data)
	magic := r_bytes(&r, 4)
	version := r_u16(&r)
	lg.seed = r_u64(&r)
	lg.players = r_u8(&r)
	n := int(r_u32(&r))
	if !r.ok || string(magic) != LOG_MAGIC || version != LOG_VERSION || lg.players > game.MAX_PLAYERS ||
	   r_remaining(&r) != n * 17 {
		return
	}
	lg.ticks = make([dynamic]Log_Tick, n)
	for &t in lg.ticks {
		t.inputs = read_inputs(&r)
		t.replaced = r_u8(&r)
	}
	return lg, r.ok
}
