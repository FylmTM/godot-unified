// Random numbers (src/sim/README.md, Random numbers), integer-only, built on SplitMix64's mixing function:
//
// - Keyed rolls (roll_below, roll_f32): nothing in the block; a roll is a hash of (seed, tick, purpose,
//   key, index), so it depends only on what it names: adding, removing or reordering one system's rolls
//   never moves another's.
// - Rng: one stream, 8 bytes of plain state. In the block, started by rng_keyed from what it is for (never the
//   tick), it is a sequence a command draws from (a deck's shuffles, a hero's rewards): its n-th draw is the same
//   whatever tick it lands on, and a rollback restores it with the block. A draw added anywhere shifts every later
//   draw from the same stream.
package sim

@(require) import "base:intrinsics" // only in generic procs

// One stream of random numbers (rng_keyed or rng_seed, then rng_next, rng_below, rng_f32, shuffle): its state is the
// whole of it, plain data for the block.
Rng :: struct {
	state: u64,
}

@(private)
GAMMA :: 0x9E3779B97F4A7C15 // SplitMix64's increment (2^64 / golden ratio, odd)

@(private)
STREAM_DOMAIN :: 0xD1B54A32D192ED03 // rng_keyed's first step, so no stream starts where a keyed roll's hash does

// SplitMix64's output function (Stafford's variant 13): a bijection on u64 with full avalanche.
@(private)
mix64 :: proc "contextless" (value: u64) -> u64 {
	z := value
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

// A stream that starts from `seed`.
rng_seed :: proc(seed: u64) -> Rng {
	return {seed}
}

// A stream for the block named by what it is for, never by the tick, as a keyed roll is: the session's seed
// (Tick.seed, or a seed the state keeps), `purpose` (a value of the game's own enum), `key` (a hero, an entity's
// handle_key) and `index` (a fight, a floor): `rng_keyed(t.seed, Roll.Draw, u64(hero), fight)`. Kept in the State, it
// rolls back with it, and its draws are the same whatever tick each is made on, so a draw a command causes doesn't
// change when the command lands a tick later than predicted. Two streams that should differ must differ in something.
rng_keyed :: proc(
	seed: u64,
	purpose: $Purpose,
	key: u64 = 0,
	index: int = 0,
) -> Rng where intrinsics.type_is_enum(Purpose) {
	bits := mix64(seed + STREAM_DOMAIN)
	bits = mix64((bits ~ u64(purpose)) + GAMMA)
	bits = mix64((bits ~ key) + GAMMA)
	return {mix64((bits ~ u64(index)) + GAMMA)}
}

// Puts `items` in a uniformly random order drawn from `rng` (Fisher-Yates from the last item, rng_below each step:
// len(items) - 1 draws), the same order on every platform. Allocates nothing.
shuffle :: proc(rng: ^Rng, items: []$T) {
	for i := len(items) - 1; i > 0; i -= 1 {
		j := int(rng_below(rng, u32(i + 1)))
		items[i], items[j] = items[j], items[i]
	}
}

// The next 64 bits of the stream (period 2^64).
rng_next :: proc(rng: ^Rng) -> u64 {
	rng.state += GAMMA
	return mix64(rng.state)
}

// Uniform in [0, n) without the bias of `% n`. n > 0.
rng_below :: proc(rng: ^Rng, n: u32) -> u32 {
	return lemire_below(rng_next(rng), n, &rng.state, proc(state: ^u64) -> u64 {
		state^ += GAMMA
		return mix64(state^)
	})
}

// Lemire's multiply-shift with rejection: uniform in [0, n) (n > 0) from 64-bit draws, `draw` first, then `next(state)`
// while a draw is rejected.
@(private)
lemire_below :: #force_inline proc(draw: u64, n: u32, state: ^u64, next: proc(state: ^u64) -> u64) -> u32 {
	assert(n > 0)
	product := (draw >> 32) * u64(n)
	if u32(product) < n {
		threshold := (0 - n) % n
		for u32(product) < threshold {
			product = (next(state) >> 32) * u64(n)
		}
	}
	return u32(product >> 32)
}

// Uniform in [0, 1) with 24 bits of precision (exact in f32).
rng_f32 :: proc(rng: ^Rng) -> f32 {
	return f32(rng_next(rng) >> 40) * (1.0 / 16777216.0)
}

// The 64 bits of a keyed roll: (seed, tick, purpose, key, index) hashed through mix64 in turn.
@(private)
roll_bits :: proc(seed: u64, tick: u32, purpose, key, index: u64) -> u64 {
	bits := mix64(seed + GAMMA)
	bits = mix64((bits ~ u64(tick)) + GAMMA)
	bits = mix64((bits ~ purpose) + GAMMA)
	bits = mix64((bits ~ key) + GAMMA)
	return mix64((bits ~ index) + GAMMA)
}

// A roll uniform in [0, n) (n > 0) for this tick, named by `purpose` (a value of the game's own enum),
// `key` (an entity's handle_key, a player...) and `index` (in a loop, the loop index: two rolls that
// should differ must differ in something). Unbiased: a rejected draw re-mixes.
roll_below :: proc(
	tick: ^Tick($G),
	n: u32,
	purpose: $Purpose,
	key: u64 = 0,
	index: int = 0,
) -> u32 where intrinsics.type_is_enum(Purpose) {
	return roll_below_at(tick.seed, tick.number, n, purpose, key, index)
}

// The roll `roll_below` makes on tick `tick` of a session with this seed, computed anywhere: a keyed roll reads no
// state, so a view (from Frame.seed) or a tick can compute one early ("the next upgrade" on a HUD). Put the roll in
// one proc both call, so they cannot drift apart. A roll that must not depend on when it is made names tick 0 and
// something stable in key and index.
roll_below_at :: proc(
	seed: u64,
	tick: u32,
	n: u32,
	purpose: $Purpose,
	key: u64 = 0,
	index: int = 0,
) -> u32 where intrinsics.type_is_enum(Purpose) {
	bits := roll_bits(seed, tick, u64(purpose), key, u64(index))
	return lemire_below(bits, n, &bits, proc(state: ^u64) -> u64 {
		state^ = mix64(state^ + GAMMA)
		return state^
	})
}

// 32 bits for a scripted player (Game.scripted_input): a hash of (seed, slot, block), where the block is the
// `period`-tick stretch `tick` (>= 1) falls in, so a script that maps them to an input holds it for a block and
// answers any tick in any order.
script_bits :: proc(seed: u64, slot: int, tick: u32, period: u32) -> u32 {
	block := u64((tick - 1) / period)
	x := seed * GAMMA ~ u64(slot + 1) * 0xBF58476D1CE4E5B9 ~ (block + 1) * 0x94D049BB133111EB
	x ~= x >> 31
	x *= 0xD6E8FEB86659FD93
	x ~= x >> 32
	return u32(x)
}

// A roll uniform in [0, 1) with 24 bits of precision, named like roll_below's.
roll_f32 :: proc(
	tick: ^Tick($G),
	purpose: $Purpose,
	key: u64 = 0,
	index: int = 0,
) -> f32 where intrinsics.type_is_enum(Purpose) {
	return roll_f32_at(tick.seed, tick.number, purpose, key, index)
}

// The roll `roll_f32` makes on tick `tick` of a session with this seed, computed anywhere (roll_below_at).
roll_f32_at :: proc(
	seed: u64,
	tick: u32,
	purpose: $Purpose,
	key: u64 = 0,
	index: int = 0,
) -> f32 where intrinsics.type_is_enum(Purpose) {
	bits := roll_bits(seed, tick, u64(purpose), key, u64(index))
	return f32(bits >> 40) * (1.0 / 16777216.0)
}
