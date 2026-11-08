// Little-endian byte writer/reader for every binary format (input log, snapshots, wire messages).
package wire

import "base:intrinsics"

Writer :: struct {
	buf: [dynamic]u8,
}

writer_make :: proc(cap := 256, allocator := context.allocator) -> Writer {
	return {buf = make([dynamic]u8, 0, cap, allocator)}
}

w_bytes :: proc(w: ^Writer, b: []u8) {
	append(&w.buf, ..b)
}

w_u8 :: proc(w: ^Writer, v: u8) {
	append(&w.buf, v)
}

w_u16 :: proc(w: ^Writer, v: u16) {
	b := transmute([2]u8)u16le(v)
	append(&w.buf, ..b[:])
}

w_u32 :: proc(w: ^Writer, v: u32) {
	b := transmute([4]u8)u32le(v)
	append(&w.buf, ..b[:])
}

w_u64 :: proc(w: ^Writer, v: u64) {
	b := transmute([8]u8)u64le(v)
	append(&w.buf, ..b[:])
}

// Patches a u32 written earlier at byte offset `at`.
w_patch_u32 :: proc(w: ^Writer, at: int, v: u32) {
	b := transmute([4]u8)u32le(v)
	copy(w.buf[at:at + 4], b[:])
}

// Bounds-checked reader: a short read sets ok = false and yields zeros, so a decoder can read a
// whole message and check `ok` once at the end.
Reader :: struct {
	data: []u8,
	pos:  int,
	ok:   bool,
}

reader_make :: proc(data: []u8) -> Reader {
	return {data = data, ok = true}
}

r_bytes :: proc(r: ^Reader, n: int) -> []u8 {
	if n < 0 || r.pos + n > len(r.data) {
		r.ok = false
		r.pos = len(r.data)
		return nil
	}
	b := r.data[r.pos:r.pos + n]
	r.pos += n
	return b
}

@(private)
r_le :: proc(r: ^Reader, $T: typeid) -> T where intrinsics.type_is_integer(T) {
	b := r_bytes(r, size_of(T))
	if b == nil {
		return 0
	}
	v: T
	intrinsics.mem_copy_non_overlapping(&v, raw_data(b), size_of(T))
	when ODIN_ENDIAN != .Little {
		#panic("big-endian targets are not supported")
	}
	return v
}

r_u8 :: proc(r: ^Reader) -> u8 {return r_le(r, u8)}
r_u16 :: proc(r: ^Reader) -> u16 {return r_le(r, u16)}
r_u32 :: proc(r: ^Reader) -> u32 {return r_le(r, u32)}
r_u64 :: proc(r: ^Reader) -> u64 {return r_le(r, u64)}
r_remaining :: proc(r: ^Reader) -> int {return len(r.data) - r.pos}
