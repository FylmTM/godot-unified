// The deterministic RNG of a state block: xorshift32, 4 bytes, plain data.
package sim

Rng :: struct {
	state: u32, // never 0
}

// Folds a 64-bit seed into the generator (0 -> 1).
rng_seed :: proc(seed: u64) -> Rng {
	x := u32(seed) ~ u32(seed >> 32)
	return {x if x != 0 else 1}
}

rng_next :: proc(r: ^Rng) -> u32 {
	v := r.state
	v ~= v << 13
	v ~= v >> 17
	v ~= v << 5
	r.state = v
	return v
}

// Uniform in [0, n) without the bias of `% n` (Lemire's multiply-shift with rejection). n > 0.
rng_below :: proc(r: ^Rng, n: u32) -> u32 {
	assert(n > 0)
	m := u64(rng_next(r)) * u64(n)
	if u32(m) < n {
		threshold := (0 - n) % n
		for u32(m) < threshold {
			m = u64(rng_next(r)) * u64(n)
		}
	}
	return u32(m >> 32)
}

// Uniform in [0, 1) with 24 bits of precision (exact in f32).
rng_f32 :: proc(r: ^Rng) -> f32 {
	return f32(rng_next(r) >> 8) * (1.0 / 16777216.0)
}
