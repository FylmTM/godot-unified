package test_wire

import "core:testing"

import "unified:wire"

@(test)
round_trip :: proc(t: ^testing.T) {
	writer := wire.writer_make(0, context.temp_allocator)
	wire.w_u8(&writer, 0xAB)
	wire.w_u16(&writer, 0xBEEF)
	wire.w_u32(&writer, 0xDEADBEEF)
	wire.w_u64(&writer, 0x0123_4567_89AB_CDEF)
	wire.w_bytes(&writer, {1, 2, 3})
	testing.expect_value(t, len(writer.buf), 1 + 2 + 4 + 8 + 3)
	testing.expect_value(t, writer.buf[1], 0xEF) // little-endian

	reader := wire.reader_make(writer.buf[:])
	testing.expect_value(t, wire.r_u8(&reader), 0xAB)
	testing.expect_value(t, wire.r_u16(&reader), 0xBEEF)
	testing.expect_value(t, wire.r_u32(&reader), 0xDEADBEEF)
	testing.expect_value(t, wire.r_u64(&reader), 0x0123_4567_89AB_CDEF)
	bytes := wire.r_bytes(&reader, 3)
	testing.expect(t, len(bytes) == 3 && bytes[0] == 1 && bytes[2] == 3)
	testing.expect(t, reader.ok)
}

@(test)
short_read_fails_softly :: proc(t: ^testing.T) {
	data := [3]u8{1, 2, 3}
	reader := wire.reader_make(data[:])
	testing.expect_value(t, wire.r_u32(&reader), 0)
	testing.expect(t, !reader.ok)
	testing.expect_value(t, wire.r_u8(&reader), 0) // stays failed, yields zeros
	testing.expect(t, wire.r_bytes(&reader, -1) == nil)
}
