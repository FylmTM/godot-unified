// Portable snapshot: "UNIS", version u16, extra count u16, seed u64, content hash u64 (the level,
// 0: none), tick u32, block size u32, layout hash u64 (layout_hash of S), payload XXH3 u64, then the block bytes, then per Extra its
// size u32 and image bytes. All of it is fixed-width little-endian data without pointers, so a
// snapshot restores on another OS or CPU (late join, `resume`).
package sim

import "base:intrinsics"

import "unified:wire"

SNAP_MAGIC :: "UNIS"
SNAP_VERSION :: 3
SNAP_HEADER :: 48

// Why a snapshot doesn't restore (nil: it does). The library never prints; callers log the value.
Snap_Error :: enum u8 {
	None,
	Bad_Header, // not a snapshot, another format version, or another block size
	Layout_Differs, // the state layout differs from this build
	Content_Differs, // the snapshot was taken with other content (another level)
	Checksum_Mismatch, // the payload is damaged
	Extra_Count, // the number of extra states differs from this build
	Extra_Rejected, // an extra state (physics) rejected its image
}

Snap_Header :: struct {
	extras:  int,
	seed:    u64,
	content: u64,
	tick:    u32,
	block:   int, // block size
	layout:  u64,
}

// Encodes the ring snapshot of `tick` into a new byte slice.
snapshot_encode :: proc(s: ^Sim($S, $I, $W, $P), tick: u32, allocator := context.allocator) -> []u8 {
	idx := int(tick % RING)
	slot := &s.ring[idx]
	assert(slot.valid && slot.tick == tick, "snapshot of a tick that is not in the ring")
	h := Snap_Header{len(s.extras), s.seed, s.content_hash, tick, size_of(S), layout_hash(S)}
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
	wire.w_u64(&w, h.content)
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
	err: Snap_Error,
) {
	r = wire.reader_make(data)
	magic := wire.r_bytes(&r, 4)
	version := wire.r_u16(&r)
	h.extras = int(wire.r_u16(&r))
	h.seed = wire.r_u64(&r)
	h.content = wire.r_u64(&r)
	h.tick = wire.r_u32(&r)
	h.block = int(wire.r_u32(&r))
	h.layout = wire.r_u64(&r)
	digest := wire.r_u64(&r)
	header := r.pos
	block = wire.r_bytes(&r, h.block)
	switch {
	case !r.ok || string(magic) != SNAP_MAGIC || version != SNAP_VERSION || h.block != block_size:
		err = .Bad_Header
	case h.layout != layout:
		err = .Layout_Differs
	case hash_bytes(data[header:]) != digest:
		err = .Checksum_Mismatch
	}
	return
}

snap_extra :: proc(r: ^wire.Reader) -> (img: []u8, ok: bool) {
	img = wire.r_bytes(r, int(wire.r_u32(r)))
	return img, r.ok
}

// Builds a new Sim from a portable snapshot, or says why the bytes are not a valid snapshot for
// this game build and content (the Sim is nil then). `content` is borrowed like create's.
from_snapshot :: proc(game: ^Game($S, $I, $W, $P), data: []u8, content: []u8 = nil) -> (^Sim(S, I, W, P), Snap_Error) {
	h, block, r, err := snap_read(data, size_of(S), layout_hash(S))
	if err != .None {
		return nil, err
	}
	if h.content != content_hash(content) {
		return nil, .Content_Differs
	}
	s := create(game, h.seed, content)
	if h.extras != len(s.extras) {
		destroy(s)
		return nil, .Extra_Count
	}
	intrinsics.mem_copy_non_overlapping(&s.state, raw_data(block), size_of(S))
	s.tick = h.tick
	for &e in s.extras {
		img, iok := snap_extra(&r)
		if !iok || !e.load(e.data, img) {
			destroy(s)
			return nil, .Extra_Rejected
		}
	}
	for &slot in s.ring {
		slot.valid = false
	}
	save(s)
	return s, .None
}
