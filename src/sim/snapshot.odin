// Portable snapshot: "UNIS", version u16, extra count u16, seed u64, content hash u64 (the level,
// 0: none), tick u32, block size u32, layout hash u64 (layout_hash of the State), compat u64 (compat_of of the
// build that took it), payload XXH3 u64, then
// the block bytes, then per Extra its size u32 and image bytes. All of it is fixed-width little-endian
// data without pointers, so a snapshot restores on another OS or CPU (late join, `resume`).
package sim

import "base:intrinsics"

import "unified:wire"

SNAP_MAGIC :: "UNIS"
// 4: physics images are Box3D's canonical images with their geometry (box3d_port phase 2); 5: the #6
// sitting's sim (the bytes are laid out as in 4); 6: the build's compat in the header (#233); 7: the physics
// extra's image carries its body table after Box3D's image (#237).
SNAP_VERSION :: 7
SNAP_HEADER :: 56

// Why a snapshot doesn't restore (nil: it does). The library never prints; callers log the value.
Snap_Error :: enum u8 {
	None,
	Bad_Header, // not a snapshot, or another format version
	Layout_Differs, // another build's state: another layout or block size
	Content_Differs, // the snapshot was taken with other content (another level)
	Build_Differs, // another build's: the same state layout, another compat (game version, library, Box3D, ...)
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
	compat:  u64,
}

// Encodes the ring snapshot of `tick` into a new byte slice.
snapshot_encode :: proc(simulation: ^Sim($G), tick: u32, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	return snapshot_encode_into(simulation, tick, &out)
}

// Encodes the ring snapshot of `tick` into `out`, replacing what it held and keeping its capacity: a snapshot taken
// again and again (a client's kept desync images) allocates only when it outgrows the last one. Returns out's bytes.
snapshot_encode_into :: proc(simulation: ^Sim($G), tick: u32, out: ^[dynamic]u8) -> []u8 {
	State :: part(G, GAME_STATE)
	index := ring_slot(simulation, tick)
	slot := &simulation.ring[index]
	assert(slot.saved && slot.tick == tick, "snapshot of a tick that is not in the ring")
	header := Snap_Header {
		extras  = len(simulation.extras),
		seed    = simulation.seed,
		content = simulation.content_hash,
		tick    = tick,
		block   = size_of(State),
		layout  = layout_hash(State),
		compat  = simulation.compat,
	}
	images := make([][]u8, len(simulation.extras), context.temp_allocator)
	size := size_of(State)
	for &extra, k in simulation.extras {
		images[k] = extra.image(extra.data, index)
		size += 4 + len(images[k])
	}
	writer := wire.Writer {
		buf = out^,
	}
	clear(&writer.buf)
	reserve(&writer.buf, SNAP_HEADER + size + 16)
	snap_begin(&writer, header, ([^]u8)(&slot.state)[:size_of(State)])
	for image in images {
		snap_add(&writer, image)
	}
	bytes := snap_end(&writer)
	out^ = writer.buf
	return bytes
}

// Starts a snapshot's bytes in an empty writer: the header with a zero digest, then the state block; snap_add appends
// each Extra's image and snap_end patches the digest. snapshot_encode_into builds every snapshot this way.
@(private)
snap_begin :: proc(writer: ^wire.Writer, header: Snap_Header, block: []u8) {
	wire.w_bytes(writer, transmute([]u8)string(SNAP_MAGIC))
	wire.w_u16(writer, SNAP_VERSION)
	wire.w_u16(writer, u16(header.extras))
	wire.w_u64(writer, header.seed)
	wire.w_u64(writer, header.content)
	wire.w_u32(writer, header.tick)
	wire.w_u32(writer, u32(header.block))
	wire.w_u64(writer, header.layout)
	wire.w_u64(writer, header.compat)
	wire.w_u64(writer, 0) // payload digest, patched by snap_end
	wire.w_bytes(writer, block)
}

// Appends one Extra's image (physics) to a snapshot snap_begin started, size-prefixed, in Extra order.
@(private)
snap_add :: proc(writer: ^wire.Writer, image: []u8) {
	wire.w_u32(writer, u32(len(image)))
	wire.w_bytes(writer, image)
}

// Patches the payload digest into the header and returns the snapshot's bytes (the writer's buffer).
@(private)
snap_end :: proc(writer: ^wire.Writer) -> []u8 {
	digest := transmute([8]u8)u64le(hash_bytes(writer.buf[SNAP_HEADER:]))
	copy(writer.buf[SNAP_HEADER - 8:], digest[:])
	return writer.buf[:]
}

// Parses and verifies the header and payload digest; `reader` is left at the extras. The magic and
// version come first (Bad_Header), then this build's block size and layout (Layout_Differs), then the
// payload digest (Checksum_Mismatch).
snap_read :: proc(
	data: []u8,
	block_size: int,
	layout: u64,
) -> (
	header: Snap_Header,
	block: []u8,
	reader: wire.Reader,
	err: Snap_Error,
) {
	reader = wire.reader_make(data)
	magic := wire.r_bytes(&reader, 4)
	version := wire.r_u16(&reader)
	if !reader.ok || string(magic) != SNAP_MAGIC || version != SNAP_VERSION {
		err = .Bad_Header
		return
	}
	header.extras = int(wire.r_u16(&reader))
	header.seed = wire.r_u64(&reader)
	header.content = wire.r_u64(&reader)
	header.tick = wire.r_u32(&reader)
	header.block = int(wire.r_u32(&reader))
	header.layout = wire.r_u64(&reader)
	header.compat = wire.r_u64(&reader)
	digest := wire.r_u64(&reader)
	payload := reader.pos
	switch {
	case !reader.ok:
		err = .Bad_Header
	case header.block != block_size || header.layout != layout:
		err = .Layout_Differs
	case hash_bytes(data[payload:]) != digest:
		err = .Checksum_Mismatch
	}
	if err == .None {
		block = wire.r_bytes(&reader, header.block)
		if !reader.ok do err = .Bad_Header // shorter than its block
	}
	return
}

// Reads the next Extra's image (a view into the snapshot bytes) after snap_read; false when it is cut short.
snap_extra :: proc(reader: ^wire.Reader) -> (image: []u8, ok: bool) {
	image = wire.r_bytes(reader, int(wire.r_u32(reader)))
	return image, reader.ok
}

// Builds a new Sim from a portable snapshot, or says why the bytes are not a valid snapshot for
// this game build and content (the Sim is nil then): snap_read's errors, then Content_Differs, then
// Build_Differs. `content` is borrowed like create's.
from_snapshot :: proc(
	game: ^$G,
	data: []u8,
	content: []u8 = nil,
) -> (
	^Sim(G),
	Snap_Error,
) where intrinsics.type_is_specialization_of(G, Game) {
	State :: part(G, GAME_STATE)
	header, block, reader, err := snap_read(data, size_of(State), layout_hash(State))
	if err != .None {
		return nil, err
	}
	if header.content != content_hash(content) {
		return nil, .Content_Differs
	}
	if header.compat != compat_of(game, content) {
		return nil, .Build_Differs
	}
	simulation := create(game, header.seed, content)
	if header.extras != len(simulation.extras) {
		destroy(simulation)
		return nil, .Extra_Count
	}
	intrinsics.mem_copy_non_overlapping(&simulation.state, raw_data(block), size_of(State))
	simulation.tick = header.tick
	for &extra in simulation.extras {
		image, image_ok := snap_extra(&reader)
		if !image_ok || !extra.load(extra.data, image) {
			destroy(simulation)
			return nil, .Extra_Rejected
		}
	}
	for &slot in simulation.ring {
		slot.valid = false
		slot.saved = false
		clear(&slot.events.list) // init's (tick 0's), which save would make the snapshot tick's when they share a slot
	}
	save(simulation)
	return simulation, .None
}
