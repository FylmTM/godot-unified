// Portable snapshot: "UNIS", version u16, extra count u16, seed u64, tick u32, block size u32,
// layout hash u64 (layout_hash of S), payload XXH3 u64, then the block bytes, then per Extra its
// size u32 and image bytes. All of it is fixed-width little-endian data without pointers, so a
// snapshot restores on another OS or CPU (late join, `resume`).
package sim

import "base:intrinsics"
import "core:fmt"

import "../wire"

SNAP_MAGIC :: "UNIS"
SNAP_VERSION :: 2
SNAP_HEADER :: 40

Snap_Header :: struct {
	extras: int,
	seed:   u64,
	tick:   u32,
	block:  int, // block size
	layout: u64,
}

// Encodes the ring snapshot of `tick` into a new byte slice.
snapshot_encode :: proc(s: ^Sim($S, $I, $W, $P), tick: u32, allocator := context.allocator) -> []u8 {
	idx := int(tick % RING)
	slot := &s.ring[idx]
	assert(slot.valid && slot.tick == tick, "snapshot of a tick that is not in the ring")
	h := Snap_Header{len(s.extras), s.seed, tick, size_of(S), layout_hash(S)}
	w := snap_begin(h, ([^]u8)(&slot.state)[:size_of(S)], snapshot_size(s), allocator)
	for &e in s.extras {
		snap_add(&w, e.image(e.data, idx))
	}
	return snap_end(&w)
}

snap_begin :: proc(h: Snap_Header, block: []u8, size_hint: int, allocator := context.allocator) -> wire.Writer {
	w := wire.writer_make(SNAP_HEADER + size_hint + 16, allocator)
	wire.w_bytes(&w, transmute([]u8)string(SNAP_MAGIC))
	wire.w_u16(&w, SNAP_VERSION)
	wire.w_u16(&w, u16(h.extras))
	wire.w_u64(&w, h.seed)
	wire.w_u32(&w, h.tick)
	wire.w_u32(&w, u32(h.block))
	wire.w_u64(&w, h.layout)
	wire.w_u64(&w, 0) // payload digest, patched by snap_end
	wire.w_bytes(&w, block)
	return w
}

snap_add :: proc(w: ^wire.Writer, img: []u8) {
	wire.w_u32(w, u32(len(img)))
	wire.w_bytes(w, img)
}

snap_end :: proc(w: ^wire.Writer) -> []u8 {
	d := transmute([8]u8)u64le(hash_bytes(w.buf[SNAP_HEADER:]))
	copy(w.buf[SNAP_HEADER - 8:], d[:])
	return w.buf[:]
}

// Parses and verifies the header and payload digest; `r` is left at the extras.
snap_read :: proc(
	data: []u8,
	block_size: int,
	layout: u64,
) -> (
	h: Snap_Header,
	block: []u8,
	r: wire.Reader,
	ok: bool,
) {
	r = wire.reader_make(data)
	magic := wire.r_bytes(&r, 4)
	version := wire.r_u16(&r)
	h.extras = int(wire.r_u16(&r))
	h.seed = wire.r_u64(&r)
	h.tick = wire.r_u32(&r)
	h.block = int(wire.r_u32(&r))
	h.layout = wire.r_u64(&r)
	digest := wire.r_u64(&r)
	block = wire.r_bytes(&r, h.block)
	switch {
	case !r.ok || string(magic) != SNAP_MAGIC || version != SNAP_VERSION || h.block != block_size:
		fmt.eprintln("snapshot: bad header or block size")
	case h.layout != layout:
		fmt.eprintln("snapshot: state layout differs from this build")
	case hash_bytes(data[SNAP_HEADER:]) != digest:
		fmt.eprintln("snapshot: payload checksum mismatch")
	case:
		ok = true
	}
	return
}

snap_extra :: proc(r: ^wire.Reader) -> (img: []u8, ok: bool) {
	img = wire.r_bytes(r, int(wire.r_u32(r)))
	return img, r.ok
}

snap_fail :: proc(msg: string) {
	fmt.eprintln("snapshot:", msg)
}

// Builds a new Sim from a portable snapshot. Returns nil (and logs why) if the bytes are not a
// valid snapshot for this game build.
from_snapshot :: proc(game: ^Game($S, $I, $W, $P), data: []u8) -> ^Sim(S, I, W, P) {
	h, block, r, ok := snap_read(data, size_of(S), layout_hash(S))
	if !ok {
		return nil
	}
	s := create(game, h.seed)
	if h.extras != len(s.extras) {
		snap_fail("extra state count differs from this build")
		destroy(s)
		return nil
	}
	intrinsics.mem_copy_non_overlapping(&s.state, raw_data(block), size_of(S))
	s.tick = h.tick
	for &e in s.extras {
		img, iok := snap_extra(&r)
		if !iok || !e.load(e.data, img) {
			snap_fail("an extra state rejected its image")
			destroy(s)
			return nil
		}
	}
	for &slot in s.ring {
		slot.valid = false
	}
	save(s)
	return s
}
