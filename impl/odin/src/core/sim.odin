// The simulation harness (CORE.md §1): the state block plus the Box3D world, a ring of 16
// snapshots (block memcpy + b3World_SaveState), the canonical checksum, and portable snapshots.
package core

import "base:intrinsics"
import "core:fmt"
import "core:hash/xxhash"

import b3 "../box3d"
import "../game"

RING :: 16

#assert(ODIN_ENDIAN == .Little) // the block's in-memory bytes are its canonical LE serialization

Snapshot :: struct {
	tick:  u32,
	valid: bool,
	block: game.State,
	phys:  ^b3.WorldState,
}

Sim :: struct {
	state:    game.State,
	phys:     game.Physics,
	scratch:  game.Scratch,
	ring:     [RING]Snapshot,
	seed:     u32,
	players:  int, // active at tick 0
	// Checksum input: the block's bytes followed by the bodies. Hashed one-shot, because
	// core:hash/xxhash's streaming XXH3 (dev-2026-11) returns wrong digests for some lengths
	// (e.g. 100097 bytes; checked against the C reference), while XXH3_64_default is correct.
	hash_buf: [size_of(game.State) + (game.ITEM_COUNT + game.MAX_PLAYERS) * 13 * 4]u8,
}

// Creates the world for (seed, players) at tick 0 and saves tick 0 into the ring. That first save
// also fills the world's geometry registry in a fixed order, which is what lets an image saved by
// another process (late join, `resume`) restore here.
sim_create :: proc(seed: u32, players: int) -> ^Sim {
	check_pod(game.State)
	sim := new(Sim)
	sim.seed = seed
	sim.players = players
	game.world_create(&sim.state, &sim.phys, seed, players)
	for &slot in sim.ring {
		slot.phys = b3.CreateWorldState()
	}
	sim_save(sim)
	return sim
}

sim_destroy :: proc(sim: ^Sim) {
	for &slot in sim.ring {
		b3.DestroyWorldState(slot.phys)
	}
	game.world_destroy(&sim.phys)
	free(sim)
}

sim_tick :: proc(sim: ^Sim) -> u32 {
	return sim.state.tick
}

// Advances one tick with the given inputs and saves the new state into the ring.
sim_step :: proc(sim: ^Sim, inputs: game.Inputs) {
	inputs := inputs
	game.tick(&sim.state, &sim.phys, &sim.scratch, &inputs)
	sim_save(sim)
}

// Saves the current state into ring slot tick % RING.
sim_save :: proc(sim: ^Sim) {
	slot := &sim.ring[sim.state.tick % RING]
	slot.block = sim.state
	b3.World_SaveState(sim.phys.world, sim.phys.cache, slot.phys)
	slot.tick = sim.state.tick
	slot.valid = true
}

// Restores the saved state of `tick` (it must still be in the ring).
sim_restore :: proc(sim: ^Sim, tick: u32) -> bool {
	slot := &sim.ring[tick % RING]
	if !slot.valid || slot.tick != tick {
		return false
	}
	sim.state = slot.block
	return b3.World_RestoreState(sim.phys.world, sim.phys.cache, slot.phys)
}

// Size of the physics image of the current tick's ring slot.
sim_physics_bytes :: proc(sim: ^Sim) -> int {
	return int(b3.WorldState_GetSize(sim.ring[sim.state.tick % RING].phys))
}

sim_has_snapshot :: proc(sim: ^Sim, tick: u32) -> bool {
	slot := &sim.ring[tick % RING]
	return slot.valid && slot.tick == tick
}

@(private)
put_f32 :: #force_inline proc(buf: []u8, at: ^int, v: f32) {
	bits := transmute(u32)v
	if bits == 0x8000_0000 {
		bits = 0 // -0.0 -> +0.0
	}
	intrinsics.unaligned_store((^u32le)(&buf[at^]), u32le(bits))
	at^ += 4
}

@(private)
put_body :: proc(sim: ^Sim, n: ^int, r: game.Body_Ref) {
	id := game.body_id(&sim.phys, r)
	p := b3.Body_GetPosition(id)
	q := b3.Body_GetRotation(id)
	v := b3.Body_GetLinearVelocity(id)
	w := b3.Body_GetAngularVelocity(id)
	for f in ([13]f32{p.x, p.y, p.z, q.v.x, q.v.y, q.v.z, q.s, v.x, v.y, v.z, w.x, w.y, w.z}) {
		put_f32(sim.hash_buf[:], n, f)
	}
}

// XXH3-64 (seed 0) over the block's bytes (pointer-free, no padding, little-endian: its canonical
// serialization in field order), then every alive physics body in entity order (items 0..39,
// players 0..3): position, rotation, linear and angular velocity.
sim_checksum :: proc(sim: ^Sim) -> u64 {
	intrinsics.mem_copy_non_overlapping(&sim.hash_buf[0], &sim.state, size_of(game.State))
	n := size_of(game.State)
	for &it in sim.state.items {
		if it.alive {
			put_body(sim, &n, it.body)
		}
	}
	for &pl in sim.state.players {
		if pl.alive {
			put_body(sim, &n, pl.body)
		}
	}
	return xxhash.XXH3_64_default(sim.hash_buf[:n])
}

// --- portable snapshot ----------------------------------------------------------------------------
// "UNIS", version u16, 0 u16, seed u32, players u32, tick u32, block size u32, physics size u32,
// payload XXH3 u64, then the block bytes and the b3World_SaveState image. Both parts are fixed-width
// little-endian data without pointers (Box3D nulls pointer fields and refers to shape geometry by
// registry index), so the file restores on another OS or CPU.

SNAP_MAGIC :: "UNIS"
SNAP_VERSION :: 1

// Encodes the ring snapshot of `tick` into a new byte slice.
snapshot_encode :: proc(sim: ^Sim, tick: u32, allocator := context.allocator) -> []u8 {
	slot := &sim.ring[tick % RING]
	assert(slot.valid && slot.tick == tick)
	block := ([^]u8)(&slot.block)[:size_of(game.State)]
	phys := b3.WorldState_GetData(slot.phys)[:b3.WorldState_GetSize(slot.phys)]
	w := writer_make(36 + len(block) + len(phys), allocator)
	w_bytes(&w, transmute([]u8)string(SNAP_MAGIC))
	w_u16(&w, SNAP_VERSION)
	w_u16(&w, 0)
	w_u32(&w, sim.seed)
	w_u32(&w, u32(sim.players))
	w_u32(&w, tick)
	w_u32(&w, u32(len(block)))
	w_u32(&w, u32(len(phys)))
	digest_at := len(w.buf)
	w_u64(&w, 0)
	w_bytes(&w, block)
	w_bytes(&w, phys)
	d := transmute([8]u8)u64le(xxhash.XXH3_64_default(w.buf[36:]))
	copy(w.buf[digest_at:], d[:])
	return w.buf[:]
}

// Builds a new Sim from a portable snapshot. Returns nil if the bytes are not a valid snapshot.
sim_from_snapshot :: proc(data: []u8) -> ^Sim {
	r := reader_make(data)
	magic := r_bytes(&r, 4)
	version := r_u16(&r)
	_ = r_u16(&r)
	seed := r_u32(&r)
	players := int(r_u32(&r))
	tick := r_u32(&r)
	block_size := int(r_u32(&r))
	phys_size := int(r_u32(&r))
	digest := r_u64(&r)
	block := r_bytes(&r, block_size)
	phys := r_bytes(&r, phys_size)
	if !r.ok || string(magic) != SNAP_MAGIC || version != SNAP_VERSION || block_size != size_of(game.State) ||
	   players > game.MAX_PLAYERS {
		fmt.eprintln("snapshot: bad header or size")
		return nil
	}
	if xxhash.XXH3_64_default(data[36:]) != digest {
		fmt.eprintln("snapshot: payload checksum mismatch")
		return nil
	}
	sim := sim_create(seed, players)
	intrinsics.mem_copy_non_overlapping(&sim.state, raw_data(block), size_of(game.State))
	if sim.state.tick != tick {
		fmt.eprintln("snapshot: block tick does not match the header")
		sim_destroy(sim)
		return nil
	}
	if !b3.World_RestoreStateFromBytes(sim.phys.world, sim.phys.cache, phys) {
		fmt.eprintln("snapshot: Box3D rejected the physics image (layout hash or geometry registry mismatch)")
		sim_destroy(sim)
		return nil
	}
	sim_save(sim)
	return sim
}
