// Input log (the replay file): "UNIL", version u16, seed u64, slots u8, input size u16, tick count
// u32, then per tick: present u32, replaced u32, slots × the input's bytes (plain data, so its
// memory is its little-endian serialization).
package sim

import "core:os"

import "../wire"

LOG_MAGIC :: "UNIL"
LOG_VERSION :: 2
LOG_HEADER :: 21

Input_Log :: struct($I: typeid, $P: int) {
	seed:  u64,
	ticks: [dynamic]Inputs(I, P), // ticks[k] holds the inputs of tick k + 1
}

log_destroy :: proc(lg: ^Input_Log($I, $P)) {
	delete(lg.ticks)
	lg.ticks = nil
}

Log_Header :: struct {
	seed:       u64,
	slots:      int,
	input_size: int,
	ticks:      int,
}

// The log's bytes: the header, then the ticks' memory (plain data).
log_encode :: proc(lg: ^Input_Log($I, $P), allocator := context.allocator) -> []u8 {
	body := ([^]u8)(raw_data(lg.ticks))[:len(lg.ticks) * size_of(Inputs(I, P))]
	return encode_log(Log_Header{lg.seed, P, size_of(I), len(lg.ticks)}, body, allocator)
}

log_decode :: proc(data: []u8, $I: typeid, $P: int) -> (lg: Input_Log(I, P), ok: bool) {
	h, body := decode_log(data) or_return
	if h.slots != P || h.input_size != size_of(I) || len(body) != h.ticks * size_of(Inputs(I, P)) {
		return
	}
	lg.seed = h.seed
	lg.ticks = make([dynamic]Inputs(I, P), h.ticks)
	copy(([^]u8)(raw_data(lg.ticks))[:len(body)], body)
	return lg, true
}

log_write :: proc(path: string, lg: ^Input_Log($I, $P)) -> bool {
	data := log_encode(lg)
	defer delete(data)
	return write_file(path, data)
}

log_read :: proc(path: string, $I: typeid, $P: int) -> (lg: Input_Log(I, P), ok: bool) {
	data := read_file(path) or_return
	defer delete(data)
	return log_decode(data, I, P)
}

encode_log :: proc(h: Log_Header, body: []u8, allocator := context.allocator) -> []u8 {
	w := wire.writer_make(LOG_HEADER + len(body), allocator)
	wire.w_bytes(&w, transmute([]u8)string(LOG_MAGIC))
	wire.w_u16(&w, LOG_VERSION)
	wire.w_u64(&w, h.seed)
	wire.w_u8(&w, u8(h.slots))
	wire.w_u16(&w, u16(h.input_size))
	wire.w_u32(&w, u32(h.ticks))
	wire.w_bytes(&w, body)
	return w.buf[:]
}

// The header and the tick bytes (a view into data).
decode_log :: proc(data: []u8) -> (h: Log_Header, body: []u8, ok: bool) {
	r := wire.reader_make(data)
	magic := wire.r_bytes(&r, 4)
	version := wire.r_u16(&r)
	h.seed = wire.r_u64(&r)
	h.slots = int(wire.r_u8(&r))
	h.input_size = int(wire.r_u16(&r))
	h.ticks = int(wire.r_u32(&r))
	if !r.ok || string(magic) != LOG_MAGIC || version != LOG_VERSION {
		return
	}
	return h, data[LOG_HEADER:], true
}

write_file :: proc(path: string, data: []u8) -> bool {
	return os.write_entire_file(path, data) == nil
}

read_file :: proc(path: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	d, err := os.read_entire_file(path, allocator)
	return d, err == nil
}
