package test_wire

import "core:testing"

import "unified:wire"

@(test)
round_trip :: proc(t: ^testing.T) {
	w := wire.writer_make(0, context.temp_allocator)
	wire.w_u8(&w, 0xAB)
	wire.w_u16(&w, 0xBEEF)
	wire.w_u32(&w, 0xDEADBEEF)
	wire.w_u64(&w, 0x0123_4567_89AB_CDEF)
	wire.w_bytes(&w, {1, 2, 3})
	wire.w_patch_u32(&w, 3, 0x0102_0304)
	testing.expect_value(t, len(w.buf), 1 + 2 + 4 + 8 + 3)
	testing.expect_value(t, w.buf[1], 0xEF) // little-endian

	r := wire.reader_make(w.buf[:])
	testing.expect_value(t, wire.r_u8(&r), 0xAB)
	testing.expect_value(t, wire.r_u16(&r), 0xBEEF)
	testing.expect_value(t, wire.r_u32(&r), 0x0102_0304)
	testing.expect_value(t, wire.r_u64(&r), 0x0123_4567_89AB_CDEF)
	testing.expect_value(t, wire.r_remaining(&r), 3)
	b := wire.r_bytes(&r, 3)
	testing.expect(t, len(b) == 3 && b[0] == 1 && b[2] == 3)
	testing.expect(t, r.ok)
}

@(test)
short_read_fails_softly :: proc(t: ^testing.T) {
	data := [3]u8{1, 2, 3}
	r := wire.reader_make(data[:])
	testing.expect_value(t, wire.r_u32(&r), 0)
	testing.expect(t, !r.ok)
	testing.expect_value(t, wire.r_u8(&r), 0) // stays failed, yields zeros
	testing.expect(t, wire.r_bytes(&r, -1) == nil)
}
