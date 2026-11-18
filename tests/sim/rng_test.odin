// Random numbers and time: the Rng stream, keyed rolls, ticks and seconds.
package test_sim

import "core:testing"

import "../toy"
import "unified:sim"

// SplitMix64's reference outputs for seed 0 (Vigna's splitmix64.c), so a change to the mixer is caught.
@(test)
rng_is_splitmix64 :: proc(t: ^testing.T) {
	rng := sim.rng_seed(0)
	testing.expect_value(t, size_of(sim.Rng), 8)
	testing.expect_value(t, sim.rng_next(&rng), 0xE220A8397B1DCDAF)
	testing.expect_value(t, sim.rng_next(&rng), 0x6E789E6AA1B965F4)
	testing.expect_value(t, sim.rng_next(&rng), 0x06C45D188009454F)
	again := sim.rng_seed(0)
	sim.rng_next(&again)
	testing.expect_value(t, sim.rng_next(&again), 0x6E789E6AA1B965F4) // the same seed, the same stream
}

@(test)
rng_below_is_in_range_and_unbiased :: proc(t: ^testing.T) {
	rng := sim.rng_seed(7)
	counts: [3]int
	for _ in 0 ..< 30_000 {
		value := sim.rng_below(&rng, 3)
		testing.expect(t, value < 3)
		counts[value] += 1
	}
	for count in counts {
		testing.expect(t, count > 9_500 && count < 10_500)
	}
	unit := sim.rng_f32(&rng)
	testing.expect(t, unit >= 0 && unit < 1)
	big := sim.rng_below(&rng, 0xFFFF_FFFF)
	testing.expect(t, big < 0xFFFF_FFFF)
}

Purpose :: enum u8 {
	Loot,
	Spread,
	Crit,
}

roll_tick :: proc(seed: u64, number: u32) -> toy.Tick {
	return toy.Tick{seed = seed, number = number}
}

// Keyed rolls: deterministic, uniform, and each depends only on what it names (D7).
@(test)
keyed_rolls :: proc(t: ^testing.T) {
	tick := roll_tick(42, 100)
	// determinism: the same names give the same roll, whatever was rolled in between
	first := sim.roll_below(&tick, 1000, Purpose.Loot, key = 7, index = 3)
	sim.roll_below(&tick, 1000, Purpose.Spread)
	testing.expect_value(t, sim.roll_below(&tick, 1000, Purpose.Loot, key = 7, index = 3), first)
	// each name moves the roll: another seed, tick, purpose, key or index
	other_seed, other_tick := roll_tick(43, 100), roll_tick(42, 101)
	differs := 0
	for i in 0 ..< 64 {
		base := sim.roll_below(&tick, 1 << 30, Purpose.Loot, key = 5, index = i)
		differs += int(sim.roll_below(&other_seed, 1 << 30, Purpose.Loot, key = 5, index = i) != base)
		differs += int(sim.roll_below(&other_tick, 1 << 30, Purpose.Loot, key = 5, index = i) != base)
		differs += int(sim.roll_below(&tick, 1 << 30, Purpose.Crit, key = 5, index = i) != base)
		differs += int(sim.roll_below(&tick, 1 << 30, Purpose.Loot, key = 6, index = i) != base)
		differs += int(sim.roll_below(&tick, 1 << 30, Purpose.Loot, key = 5, index = i + 64) != base)
	}
	testing.expect_value(t, differs, 5 * 64)
	// distribution: 6 buckets over 60,000 rolls (keys and ticks varying), each within 4% of 10,000
	counts: [6]int
	for number in u32(0) ..< 600 {
		later := roll_tick(9, number)
		for key in u64(0) ..< 100 {
			counts[sim.roll_below(&later, 6, Purpose.Spread, key)] += 1
		}
	}
	for count in counts do testing.expect(t, count > 9_600 && count < 10_400)
	// neighbouring keys are independent: the low bit of key k and key k + 1 agree about half the time
	agree := 0
	for key in u64(0) ..< 10_000 {
		agree += int(sim.roll_below(&tick, 2, Purpose.Loot, key) == sim.roll_below(&tick, 2, Purpose.Loot, key + 1))
	}
	testing.expect(t, agree > 4_800 && agree < 5_200)
	// f32 rolls: [0, 1), mean about 1/2
	sum: f64
	for i in 0 ..< 10_000 {
		value := sim.roll_f32(&tick, Purpose.Spread, index = i)
		testing.expect(t, value >= 0 && value < 1)
		sum += f64(value)
	}
	testing.expect(t, sum / 10_000 > 0.49 && sum / 10_000 < 0.51)
}

@(test)
seconds_and_ticks :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.ticks(0.25, 64), 16)
	testing.expect_value(t, sim.ticks(0.3, 64), 19) // 19.2: the nearest
	testing.expect_value(t, sim.ticks(0.2578125, 64), 17) // 16.5: half rounds up
	testing.expect_value(t, sim.ticks(-1, 64), 0)
	testing.expect_value(t, sim.ticks(1e12, 64), 2147483647)
	nan: f32 = 0
	nan = nan / nan
	testing.expect_value(t, sim.ticks(nan, 64), 0)
	testing.expect_value(t, sim.seconds(u32(96), 64), 1.5)
	testing.expect_value(t, sim.seconds(u16(32), 128), 0.25)
	testing.expect_value(t, sim.seconds(i32(-64), 64), -1)
}
