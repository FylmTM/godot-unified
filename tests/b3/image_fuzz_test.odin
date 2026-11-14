// A late joiner's Box3D image can come from anyone (#8 D11 a): `world_load_image` on damaged and made-up bytes
// either refuses them, leaving the world as it was, or loads a world that hashes, saves, snapshots, restores and is
// destroyed safely. Flips, 32-bit edge values, cuts and random bytes of real images of the golden scene. Stepping such
// worlds is unified-box3d's own fuzz suite (asserts off, bounds checks on); here it would trip the debug library's
// numeric asserts (`uni test --box3d-debug`) on worlds that are safe but simulate badly.
package test_b3

import "core:log"
import "core:testing"

import b3 "unified:b3"
import "unified:physics"

@(private = "file")
Fuzz :: struct {
	state: u64,
}

@(private = "file")
fuzz_below :: proc(fuzz: ^Fuzz, n: int) -> int {
	fuzz.state += 0x9E3779B97F4A7C15
	z := fuzz.state
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return int((z ~ (z >> 31)) % u64(n))
}

@(private = "file")
Counts :: struct {
	tried, loaded: int,
}

// Loads `bytes` into a fresh world; what loads is hashed, saved, snapshotted and restored, and a refusal leaves the
// world as it was (its hash unchanged).
@(private = "file")
fuzz_try :: proc(t: ^testing.T, bytes: []u8, counts: ^Counts, state: ^b3.World_State) {
	counts.tried += 1
	world := world_make()
	defer physics.destroy(world)
	before := b3.world_hash_state(world.id)
	if !b3.world_load_image(world.id, bytes) {
		testing.expect_value(t, b3.world_hash_state(world.id), before)
		return
	}
	counts.loaded += 1
	_ = b3.world_hash_state(world.id)
	_ = b3.world_hash_awake_bodies(world.id)
	snap: b3.World_Snapshot
	b3.world_save_snapshot(world.id, &snap)
	testing.expect(t, b3.world_restore_snapshot(world.id, &snap))
	b3.destroy_world_snapshot(&snap)
	testing.expect(t, b3.world_save_image(world.id, state, true) > 0)
}

@(test)
image_load_is_safe_on_any_bytes :: proc(t: ^testing.T) {
	scene: Scene
	scene_make(&scene)
	defer scene_destroy(&scene)
	state := b3.create_world_state()
	defer b3.destroy_world_state(state)
	seeds: [2][]u8
	for &seed, k in seeds {
		step(scene.world, 60 + 200 * k) // moving, then asleep
		testing.expect(t, b3.world_save_image(scene.world, state, true) > 0)
		data := b3.world_state_get_data(state)
		seed = make([]u8, len(data))
		copy(seed, data)
	}
	defer for seed in seeds {
		delete(seed)
	}
	work := make([]u8, max(len(seeds[0]), len(seeds[1])))
	defer delete(work)
	fuzz := Fuzz{0xD11A}
	for seed in seeds {
		counts: Counts
		fuzz_try(t, seed, &counts, state)
		testing.expect_value(t, counts.loaded, 1)
	}
	EDGES := [?]u32{0, 1, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0x7FC00000, 1 << 20, 1 << 30}
	flips, edges, cuts, random: Counts
	for seed in seeds {
		for offset := 0; offset < len(seed); offset += 5 {
			bytes := work[:len(seed)]
			copy(bytes, seed)
			bytes[offset] ~= u8(1 + fuzz_below(&fuzz, 255))
			fuzz_try(t, bytes, &flips, state)
		}
		for offset := 0; offset + 4 <= len(seed); offset += 12 {
			bytes := work[:len(seed)]
			copy(bytes, seed)
			(^u32le)(&bytes[offset])^ = u32le(EDGES[fuzz_below(&fuzz, len(EDGES))])
			fuzz_try(t, bytes, &edges, state)
		}
		for length := 0; length < len(seed); length += 37 {
			fuzz_try(t, seed[:length], &cuts, state)
		}
		for i in 0 ..< 200 {
			length := 1 + fuzz_below(&fuzz, len(seed))
			bytes := work[:length]
			keep := i % 2 == 0 ? 0 : fuzz_below(&fuzz, length)
			copy(bytes[:keep], seed[:keep])
			for &b in bytes[keep:] {
				b = u8(fuzz_below(&fuzz, 256))
			}
			fuzz_try(t, bytes, &random, state)
		}
	}
	testing.expect_value(t, cuts.loaded, 0)
	testing.expect_value(t, random.loaded, 0)
	log.infof(
		"images of %d and %d bytes: flips %d of %d loaded, edge words %d of %d, cuts %d of %d, random %d of %d",
		len(seeds[0]),
		len(seeds[1]),
		flips.loaded,
		flips.tried,
		edges.loaded,
		edges.tried,
		cuts.loaded,
		cuts.tried,
		random.loaded,
		random.tried,
	)
}
