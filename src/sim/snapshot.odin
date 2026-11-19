// Portable snapshot: "UNIS", version u16, seed u64, content hash u64 (the level, 0: none), tick u32, block size u32,
// layout hash u64 (layout_hash of the State), compat u64 (compat_of of the build that took it), payload XXH3 u64,
// then the block bytes, then the Extra's image: its size u32 (0: the game has no Extra) and bytes. All of it is fixed-width little-endian
// data without pointers, so a snapshot restores on another OS or CPU (late join, `resume`).
package sim

import "base:builtin"
import "base:intrinsics"

import "unified:wire"

@(private)
SNAP_MAGIC :: "UNIS"
// Bump on any change to the format or to what an image holds.
SNAP_VERSION :: 8
SNAP_HEADER :: 54

// Why a snapshot doesn't restore (nil: it does). The library never prints; callers log the value.
Snap_Error :: enum u8 {
	None,
	Bad_Header, // not a snapshot, or another format version
	Layout_Differs, // another build's state: another layout or block size
	Content_Differs, // the snapshot was taken with other levels (Game.levels)
	Build_Differs, // another build's: the same state layout, another compat (game version, library, Box3D, ...)
	Checksum_Mismatch, // the payload is damaged
	Extra_Rejected, // the extra state (physics) rejected its image, or the snapshot has one and the game none
}

@(private)
Snap_Header :: struct {
	seed:    u64,
	content: u64,
	tick:    u32,
	block:   int, // block size
	layout:  u64,
	compat:  u64,
}

// Encodes the ring snapshot of `tick` into a new byte slice. The ring must hold `tick` saved (asserted): state_at
// answers whether it does.
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
		seed    = simulation.seed,
		content = simulation.content_hash,
		tick    = tick,
		block   = size_of(State),
		layout  = simulation.layout,
		compat  = simulation.compat,
	}
	image: []u8
	if extra := &simulation.extra; extra.image != nil {
		image = extra.image(extra.data, index, tick == simulation.tick)
	}
	return snap_write(header, ([^]u8)(&slot.state)[:size_of(State)], image, out)
}

// Keeps `tick`'s ring snapshot aside in keep slot `index` (0 ..< KEEP_SLOTS), replacing what the slot held: the block
// and the Extra's save, copied (Extra.keep), so the portable snapshot is encoded only if it is wanted
// (snapshot_encode_kept), after the ring moved on. An Extra without keep images at once. False when `tick` is not in
// the ring (or `index` is out of range). The first call allocates the slots.
snapshot_keep :: proc(simulation: ^Sim($G), tick: u32, index: int) -> bool {
	State :: part(G, GAME_STATE)
	ring_index := ring_slot(simulation, tick)
	slot := &simulation.ring[ring_index]
	if index < 0 || index >= KEEP_SLOTS || !slot.saved || slot.tick != tick {
		return false
	}
	if simulation.kept == nil {
		simulation.kept = make([]Kept_Tick(State), KEEP_SLOTS)
	}
	kept := &simulation.kept[index]
	kept.tick = tick
	kept.kept = true
	kept.state = slot.state
	builtin.clear(&kept.image)
	if extra := &simulation.extra; extra.image != nil {
		if extra.keep != nil && extra.image_kept != nil {
			extra.keep(extra.data, ring_index, index)
		} else {
			builtin.append(&kept.image, ..extra.image(extra.data, ring_index, tick == simulation.tick))
		}
	}
	return true
}

// The portable snapshot of keep slot `index` into `out` (as snapshot_encode_into): the same bytes snapshot_encode_into
// gave for its tick while the ring held it. ok = false when the slot holds nothing.
snapshot_encode_kept :: proc(
	simulation: ^Sim($G),
	index: int,
	out: ^[dynamic]u8,
) -> (
	bytes: []u8,
	tick: u32,
	ok: bool,
) {
	State :: part(G, GAME_STATE)
	if index < 0 || index >= len(simulation.kept) || !simulation.kept[index].kept {
		return
	}
	kept := &simulation.kept[index]
	header := Snap_Header {
		seed    = simulation.seed,
		content = simulation.content_hash,
		tick    = kept.tick,
		block   = size_of(State),
		layout  = simulation.layout,
		compat  = simulation.compat,
	}
	image := kept.image[:]
	if extra := &simulation.extra; extra.image != nil && extra.keep != nil && extra.image_kept != nil {
		image = extra.image_kept(extra.data, index)
	}
	return snap_write(header, ([^]u8)(&kept.state)[:size_of(State)], image, out), kept.tick, true
}

// A snapshot's bytes into `out` (replacing what it held, keeping its capacity): the header, the block, the image.
@(private)
snap_write :: proc(header: Snap_Header, block: []u8, image: []u8, out: ^[dynamic]u8) -> []u8 {
	writer := wire.Writer {
		buf = out^,
	}
	builtin.clear(&writer.buf)
	reserve(&writer.buf, SNAP_HEADER + len(block) + 4 + len(image))
	snap_begin(&writer, header, block)
	wire.w_u32(&writer, u32(len(image)))
	wire.w_bytes(&writer, image)
	bytes := snap_end(&writer)
	out^ = writer.buf
	return bytes
}

// Starts a snapshot's bytes in an empty writer: the header with a zero digest, then the state block; the caller
// appends the Extra's image and snap_end patches the digest.
@(private)
snap_begin :: proc(writer: ^wire.Writer, header: Snap_Header, block: []u8) {
	wire.w_bytes(writer, transmute([]u8)string(SNAP_MAGIC))
	wire.w_u16(writer, SNAP_VERSION)
	wire.w_u64(writer, header.seed)
	wire.w_u64(writer, header.content)
	wire.w_u32(writer, header.tick)
	wire.w_u32(writer, u32(header.block))
	wire.w_u64(writer, header.layout)
	wire.w_u64(writer, header.compat)
	wire.w_u64(writer, 0) // payload digest, patched by snap_end
	wire.w_bytes(writer, block)
}


// Patches the payload digest into the header and returns the snapshot's bytes (the writer's buffer).
@(private)
snap_end :: proc(writer: ^wire.Writer) -> []u8 {
	digest := transmute([8]u8)u64le(hash_bytes(writer.buf[SNAP_HEADER:]))
	copy(writer.buf[SNAP_HEADER - 8:], digest[:])
	return writer.buf[:]
}

// Parses and verifies the header and payload digest; `reader` is left at the Extra's image. The magic and
// version come first (Bad_Header), then this build's block size and layout (Layout_Differs), then the
// payload digest (Checksum_Mismatch).
@(private)
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

// Reads the Extra's image (a view into the snapshot bytes; empty: none) after snap_read; false when it is cut short.
@(private)
snap_extra :: proc(reader: ^wire.Reader) -> (image: []u8, ok: bool) {
	image = wire.r_bytes(reader, int(wire.r_u32(reader)))
	return image, reader.ok
}

// Builds a new Sim from a portable snapshot, or says why the bytes are not a valid snapshot for
// this game build and its levels (the Sim is nil then): snap_read's errors, then Content_Differs, then
// Build_Differs.
from_snapshot :: proc(
	game: ^$G,
	data: []u8,
) -> (
	^Sim(G),
	Snap_Error,
) where intrinsics.type_is_specialization_of(G, Game) {
	State :: part(G, GAME_STATE)
	layout := layout_hash(State)
	header, block, reader, err := snap_read(data, size_of(State), layout)
	if err != .None {
		return nil, err
	}
	if header.content != content_hash(game.levels) {
		return nil, .Content_Differs
	}
	if header.compat != compat_with(game, layout, {}) {
		return nil, .Build_Differs
	}
	simulation := create(game, header.seed)
	intrinsics.mem_copy_non_overlapping(&simulation.state, raw_data(block), size_of(State))
	simulation.tick = header.tick
	image, image_ok := snap_extra(&reader)
	extra := &simulation.extra
	if !image_ok || (extra.load != nil ? !extra.load(extra.data, image) : len(image) != 0) {
		destroy(simulation)
		return nil, .Extra_Rejected
	}
	for &slot in simulation.ring {
		slot.valid = false
		slot.saved = false
		builtin.clear(&slot.events.list) // init's (tick 0's), which save would make the snapshot tick's when they share a slot
	}
	save(simulation)
	return simulation, .None
}
