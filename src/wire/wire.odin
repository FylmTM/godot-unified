// Little-endian byte writer/reader for every binary format (input log, snapshots, wire messages).
package wire

import "base:intrinsics"

Writer :: struct {
	buf: [dynamic]u8,
}

writer_make :: proc(cap := 256, allocator := context.allocator) -> Writer {
	return {buf = make([dynamic]u8, 0, cap, allocator)}
}

w_bytes :: proc(writer: ^Writer, bytes: []u8) {
	append(&writer.buf, ..bytes)
}

w_u8 :: proc(writer: ^Writer, value: u8) {
	append(&writer.buf, value)
}

w_u16 :: proc(writer: ^Writer, value: u16) {
	bytes := transmute([2]u8)u16le(value)
	append(&writer.buf, ..bytes[:])
}

w_u32 :: proc(writer: ^Writer, value: u32) {
	bytes := transmute([4]u8)u32le(value)
	append(&writer.buf, ..bytes[:])
}

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

reader_make :: proc(data: []u8) -> Reader {
	return {data = data, ok = true}
}

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

r_u8 :: proc(reader: ^Reader) -> u8 {return r_le(reader, u8)}
r_u16 :: proc(reader: ^Reader) -> u16 {return r_le(reader, u16)}
r_u32 :: proc(reader: ^Reader) -> u32 {return r_le(reader, u32)}
r_u64 :: proc(reader: ^Reader) -> u64 {return r_le(reader, u64)}
r_remaining :: proc(reader: ^Reader) -> int {return len(reader.data) - reader.pos}
