// Little-endian byte writer/reader for every binary format (input log, snapshots, wire messages).
package wire

import "base:intrinsics"

Writer :: struct {
	buf: [dynamic]u8,
}

// Starts an empty writer with `cap` bytes reserved; the caller owns buf (deleted, or handed on as the encoded bytes).
writer_make :: proc(cap := 256, allocator := context.allocator) -> Writer {
	return {buf = make([dynamic]u8, 0, cap, allocator)}
}

// Appends raw bytes as they are (a blob whose length the format stores elsewhere).
w_bytes :: proc(writer: ^Writer, bytes: []u8) {
	append(&writer.buf, ..bytes)
}

// Appends one byte.
w_u8 :: proc(writer: ^Writer, value: u8) {
	append(&writer.buf, value)
}

// Appends a u16, little-endian.
w_u16 :: proc(writer: ^Writer, value: u16) {
	bytes := transmute([2]u8)u16le(value)
	append(&writer.buf, ..bytes[:])
}

// Appends a u32, little-endian.
w_u32 :: proc(writer: ^Writer, value: u32) {
	bytes := transmute([4]u8)u32le(value)
	append(&writer.buf, ..bytes[:])
}

// Appends a u64, little-endian.
w_u64 :: proc(writer: ^Writer, value: u64) {
	bytes := transmute([8]u8)u64le(value)
	append(&writer.buf, ..bytes[:])
}

// Patches a u32 written earlier at byte offset `at`.
w_patch_u32 :: proc(writer: ^Writer, at: int, value: u32) {
	bytes := transmute([4]u8)u32le(value)
	copy(writer.buf[at:at + 4], bytes[:])
}

// Bounds-checked reader: a short read sets ok = false and yields zeros, so a decoder can read a
// whole message and check `ok` once at the end.
Reader :: struct {
	data: []u8,
	pos:  int,
	ok:   bool,
}

// Starts a reader at the front of `data`, which it views without copying.
reader_make :: proc(data: []u8) -> Reader {
	return {data = data, ok = true}
}

// Returns the next `count` bytes as a view into data (not a copy), or nil and ok = false when fewer are left.
r_bytes :: proc(reader: ^Reader, count: int) -> []u8 {
	if count < 0 || reader.pos + count > len(reader.data) {
		reader.ok = false
		reader.pos = len(reader.data)
		return nil
	}
	bytes := reader.data[reader.pos:reader.pos + count]
	reader.pos += count
	return bytes
}

@(private)
r_le :: proc(reader: ^Reader, $T: typeid) -> T where intrinsics.type_is_integer(T) {
	bytes := r_bytes(reader, size_of(T))
	if bytes == nil {
		return 0
	}
	value: T
	intrinsics.mem_copy_non_overlapping(&value, raw_data(bytes), size_of(T))
	when ODIN_ENDIAN != .Little {
		#panic("big-endian targets are not supported")
	}
	return value
}

// Reads one byte; 0 when short.
r_u8 :: proc(reader: ^Reader) -> u8 {return r_le(reader, u8)}
// Reads a little-endian u16; 0 when short.
r_u16 :: proc(reader: ^Reader) -> u16 {return r_le(reader, u16)}
// Reads a little-endian u32; 0 when short.
r_u32 :: proc(reader: ^Reader) -> u32 {return r_le(reader, u32)}
// Reads a little-endian u64; 0 when short.
r_u64 :: proc(reader: ^Reader) -> u64 {return r_le(reader, u64)}
// The bytes left after pos: a decoder reads records until none are left, or rejects trailing bytes.
r_remaining :: proc(reader: ^Reader) -> int {return len(reader.data) - reader.pos}
