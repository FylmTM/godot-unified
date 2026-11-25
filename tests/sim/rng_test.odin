// Random numbers and time: the Rng stream, streams in the block (rng_keyed, shuffle), keyed rolls, ticks and seconds.
package test_sim

import "core:testing"

import "../toy"
import "unified:sim"

// The cross-platform pin of rng_keyed and shuffle: a stream's first draws, and a 10-item deck shuffled from it.
@(test)
rng_keyed_golden :: proc(t: ^testing.T) {
	stream := sim.rng_keyed(42, Purpose.Loot, 7, 3)
	testing.expect_value(t, sim.rng_next(&stream), 0x0115B8ABCE127EF4)
	testing.expect_value(t, sim.rng_next(&stream), 0x3E7229CA7585A5F9)
	testing.expect_value(t, sim.rng_next(&stream), 0x62D9047D19F94302)
	deck := [10]u8{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}
	dealer := sim.rng_keyed(42, Purpose.Spread)
	sim.shuffle(&dealer, deck[:])
	testing.expect_value(t, deck, [10]u8{9, 4, 2, 6, 5, 7, 1, 0, 8, 3})
	testing.expect_value(t, dealer.state, 0xA4C122A408041B83) // where the shuffle left the stream
}

// rng_keyed: the same names start the same stream; another seed, purpose, key or index another one (a key and an
// index swapped too), and a stream doesn't repeat the keyed rolls of the same names on tick 0.
@(test)
rng_keyed_streams :: proc(t: ^testing.T) {
	base := sim.rng_keyed(42, Purpose.Loot, 7, 2)
	testing.expect_value(t, sim.rng_keyed(42, Purpose.Loot, 7, 2), base)
	others := [?]sim.Rng {
		sim.rng_keyed(43, Purpose.Loot, 7, 2),
		sim.rng_keyed(42, Purpose.Crit, 7, 2),
		sim.rng_keyed(42, Purpose.Loot, 8, 2),
		sim.rng_keyed(42, Purpose.Loot, 7, 3),
		sim.rng_keyed(42, Purpose.Loot, 2, 7),
		sim.rng_keyed(42, Purpose.Loot),
	}
	for other, i in others do testing.expectf(t, other != base, "stream %d starts like the base", i)
	same := 0
	for index in 0 ..< 64 {
		stream := sim.rng_keyed(42, Purpose.Loot, 7, index)
		same += int(sim.rng_below(&stream, 1 << 30) == sim.roll_below_at(42, 0, 1 << 30, Purpose.Loot, 7, index))
	}
	testing.expect_value(t, same, 0)
	// neighbouring keys are independent: the low bit of the first draw agrees about half the time
	agree := 0
	for key in u64(0) ..< 10_000 {
		this, next := sim.rng_keyed(1, Purpose.Spread, key), sim.rng_keyed(1, Purpose.Spread, key + 1)
		agree += int(sim.rng_next(&this) & 1 == sim.rng_next(&next) & 1)
	}
	testing.expect(t, agree > 4_800 && agree < 5_200)
}

// shuffle: every order of 4 items comes up about as often (24 orders, 240,000 shuffles, each within 4% of 10,000),
// and a slice of 0 or 1 items draws nothing.
@(test)
shuffle_is_uniform :: proc(t: ^testing.T) {
	counts: [24]int
	rng := sim.rng_keyed(9, Purpose.Spread)
	for _ in 0 ..< 240_000 {
		items := [4]u8{0, 1, 2, 3}
		sim.shuffle(&rng, items[:])
		// the order's index in base (4, 3, 2): the position of each item among those left
		left := [4]u8{0, 1, 2, 3}
		count := 4
		index := 0
		for item in items {
			at := 0
			for left[at] != item do at += 1
			index = index * count + at
			for k in at ..< count - 1 do left[k] = left[k + 1]
			count -= 1
		}
		counts[index] += 1
	}
	for count, order in counts do testing.expectf(t, count > 9_600 && count < 10_400, "order %d: %d", order, count)
	before := rng
	one := [1]u8{5}
	sim.shuffle(&rng, one[:])
	sim.shuffle(&rng, one[:0])
	testing.expect_value(t, rng, before)
}

// A deck in the block, shuffled by a command from a stream the State keeps.
Command_Deal :: struct {}

Deal_Command :: union {
	Command_Deal,
}

Deal_State :: struct {
	deals:   sim.Rng,
	players: sim.Players(u32, sim.No_Profile, sim.No_Input, 2),
	deck:    sim.List(u8, 13),
	_pad:    [2]u8,
}

Deal_Game :: sim.Game(Deal_State, sim.No_Input, sim.No_World, toy.Event, Deal_Command, sim.No_Setup, sim.No_Profile, 2)

DEAL_GAME := Deal_Game {
	name = "deal",
	version = "1",
	tick_hz = 64,
	init = proc(t: ^sim.Tick(Deal_Game)) {
		t.state.deals = sim.rng_keyed(t.seed, Purpose.Loot)
		for card in u8(0) ..< 13 do sim.append(&t.state.deck, card)
	},
	tick = proc(t: ^sim.Tick(Deal_Game)) {
		players := sim.iterate_present(t)
		for _, player in sim.next(&players) {
			for _ in sim.commands(t, player) do sim.shuffle(&t.state.deals, sim.slice(&t.state.deck))
		}
	},
}

// Steps `simulation` to tick `to`, member 1 seated in slot 0, with a deal on each tick of `deals`.
deal_until :: proc(simulation: ^sim.Sim(Deal_Game), to: u32, deals: []u32) {
	for simulation.tick < to {
		inputs: sim.Inputs(Deal_Game)
		sim.seat(&inputs, simulation, 0, 1)
		for tick in deals {
			if tick == simulation.tick + 1 do sim.add_command(&inputs, sim.command_make(Deal_Command, Command_Deal{}))
		}
		sim.step(simulation, &inputs)
	}
}

// A stream in the block deals the same cards whatever tick its commands land on, and a rollback across a shuffle
// re-deals the same order: a command placed later than predicted changes nothing that was drawn.
@(test)
a_stream_deals_the_same_whatever_the_tick :: proc(t: ^testing.T) {
	simulation := sim.create(&DEAL_GAME, 5)
	defer sim.destroy(simulation)
	deal_until(simulation, 10, {3, 5})
	dealt := simulation.state.deck
	testing.expect(t, dealt != sim.state_at(simulation, 0).deck, "two deals moved the deck")
	testing.expect(t, sim.restore(simulation, 2))
	deal_until(simulation, 10, {4, 8}) // the same deals, later: a rollback re-simulates them
	testing.expect_value(t, simulation.state.deck, dealt)
	testing.expect(t, sim.restore(simulation, 3))
	deal_until(simulation, 10, {6}) // one deal less: another deck
	testing.expect(t, simulation.state.deck != dealt, "one deal less deals another deck")
}

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

// K distinct of n by a keyed roll: always distinct and in range, the same for the same names, moved by each name, and
// uniform over the ordered choices (each of the 6 orders of 3 values, 3 of 3, about a sixth of the time; each value
// first about a seventh of the time, 3 of 7).
@(test)
distinct_rolls :: proc(t: ^testing.T) {
	first_counts: [7]int
	orders: [6]int
	for key in 0 ..< u64(7000) {
		picks := sim.roll_distinct_at(42, 7, 3, Purpose.Loot, key, 2)
		testing.expect_value(t, sim.roll_distinct_at(42, 7, 3, Purpose.Loot, key, 2), picks)
		for pick, j in picks {
			testing.expect(t, pick >= 0 && pick < 7)
			for other in picks[:j] do testing.expect(t, other != pick, "two picks alike")
		}
		first_counts[picks[0]] += 1
		all := sim.roll_distinct_at(42, 3, 3, Purpose.Spread, key)
		orders[all[0] * 2 + (1 if all[1] > all[2] else 0)] += 1
	}
	for count in first_counts do testing.expectf(t, count > 850 && count < 1150, "a value first %d of 7000 times", count)
	for count in orders do testing.expectf(t, count > 1000 && count < 1340, "an order %d of 7000 times", count)
	base := sim.roll_distinct_at(1, 1000, 2, Purpose.Loot, 5, 3)
	testing.expect(t, sim.roll_distinct_at(2, 1000, 2, Purpose.Loot, 5, 3) != base, "the seed moves it")
	testing.expect(t, sim.roll_distinct_at(1, 1000, 2, Purpose.Crit, 5, 3) != base, "the purpose moves it")
	testing.expect(t, sim.roll_distinct_at(1, 1000, 2, Purpose.Loot, 6, 3) != base, "the key moves it")
	testing.expect(t, sim.roll_distinct_at(1, 1000, 2, Purpose.Loot, 5, 4) != base, "the index moves it")
	one := sim.roll_distinct_at(9, 1, 1, Purpose.Loot)
	testing.expect_value(t, one[0], 0)
}
