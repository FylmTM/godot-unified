// Inline collections (List, Queue, Bits), the grid, due and the keyed-roll peek.
package test_sim

import "core:math/rand"
import "core:strings"
import "core:testing"

import "../toy"
import "unified:sim"

// A game whose State holds each collection and whose tick steers dots by their neighbours through a grid rebuilt from
// the block in its World: the desync report reads the collections, and a rollback re-simulates through the grid.
SWARM_DOTS :: 48
SWARM_CELLS :: 8

Dot :: struct {
	pos, vel: [2]f32,
}

Swarm_State :: struct {
	players: sim.Players(toy.Player_Data, sim.No_Profile, toy.Input, toy.PLAYERS),
	dots:    [SWARM_DOTS]Dot,
	bag:     sim.List(toy.Thing, 5),
	queue:   sim.Queue(u8, 3),
	_pad:    [7]u8,
	seen:    sim.Bits(70),
}

Swarm_World :: struct {
	grid: sim.Grid(SWARM_CELLS * SWARM_CELLS, SWARM_DOTS),
}

Swarm_Game :: sim.Game(
	Swarm_State,
	toy.Input,
	Swarm_World,
	toy.Event,
	toy.Command,
	sim.No_Setup,
	sim.No_Profile,
	toy.PLAYERS,
)

SWARM := Swarm_Game {
	name = "swarm",
	version = "1",
	tick_hz = 64,
	init = proc(t: ^sim.Tick(Swarm_Game)) {
		for &dot, i in t.state.dots {
			dot.pos = {
				sim.roll_f32(t, Swarm_Roll.Place, 0, i) * 16 - 8,
				sim.roll_f32(t, Swarm_Roll.Place, 1, i) * 16 - 8,
			}
		}
	},
	tick = proc(t: ^sim.Tick(Swarm_Game)) {
		grid := &t.world.grid
		sim.grid_begin(grid, {-8, -8}, 2, SWARM_CELLS, SWARM_CELLS)
		for dot, i in t.state.dots do sim.grid_add(grid, i32(i), dot.pos)
		sim.grid_end(grid)
		for &dot, i in t.state.dots {
			push: [2]f32
			for row in sim.grid_near(grid, dot.pos) {
				for other in row {
					if other == i32(i) do continue
					away := dot.pos - t.state.dots[other].pos
					if away.x * away.x + away.y * away.y < 4 do push += away
				}
			}
			if sim.due(t, i, 4) do dot.vel += {sim.roll_f32(t, Swarm_Roll.Kick, 0, i) - 0.5, sim.roll_f32(t, Swarm_Roll.Kick, 1, i) - 0.5}
			dot.vel = dot.vel * 0.9 + push * 0.05
			dot.pos += dot.vel * t.dt
		}
		if t.number % 7 == 0 {
			if !sim.append(&t.state.bag, toy.Thing{life = i32(t.number)}) do sim.ordered_remove(&t.state.bag, 0)
			if !sim.append(&t.state.queue, u8(t.number)) do sim.pop_front(&t.state.queue)
			sim.incl(&t.state.seen, int(t.number / 7 % 70))
		}
	},
}

Swarm_Roll :: enum u8 {
	Place,
	Kick,
}

// Every remove zeroes what it vacates: after any sequence of appends, pops and removes a List's bytes are those of a
// List built fresh from the same items.
@(test)
list_equal_contents_hash_equal :: proc(t: ^testing.T) {
	List :: sim.List(u16, 9)
	list: List
	model: [dynamic]u16
	defer delete(model)
	random := rand.create(7)
	for step in 0 ..< 4000 {
		switch rand.int_max(5, rand.default_random_generator(&random)) {
		case 0, 1:
			value := u16(step + 1)
			if sim.append(&list, value) do append(&model, value)
			else do testing.expect_value(t, len(model), 9)
		case 2:
			value, ok := sim.pop(&list)
			testing.expect_value(t, ok, len(model) > 0)
			if ok do testing.expect_value(t, value, pop(&model))
		case 3:
			if len(model) > 0 {
				index := step % len(model)
				sim.ordered_remove(&list, index)
				ordered_remove(&model, index)
			}
		case 4:
			if len(model) > 0 {
				index := step % len(model)
				sim.unordered_remove(&list, index)
				unordered_remove(&model, index)
			}
		}
		fresh: List
		for value in model do sim.append(&fresh, value)
		if fresh != list {
			testing.expectf(t, false, "step %d: the list's bytes differ from a fresh one with the same items", step)
			return
		}
	}
	testing.expect_value(t, len(sim.slice(&list)), len(model))
	sim.clear(&list)
	testing.expect(t, list == {})
}

@(test)
queue_is_first_in_first_out :: proc(t: ^testing.T) {
	queue: sim.Queue(i32, 3)
	_, empty := sim.pop_front(&queue)
	testing.expect(t, !empty)
	for round in 0 ..< 5 { 	// wraps around the storage
		testing.expect(t, sim.append(&queue, i32(round * 10 + 1)))
		testing.expect(t, sim.append(&queue, i32(round * 10 + 2)))
		testing.expect_value(t, sim.queue_at(&queue, 0)^, i32(round * 10 + 1))
		first, _ := sim.pop_front(&queue)
		testing.expect_value(t, first, i32(round * 10 + 1))
		testing.expect(t, sim.append(&queue, i32(round * 10 + 3)))
		testing.expect(t, sim.append(&queue, i32(round * 10 + 4)))
		testing.expect(t, !sim.append(&queue, 99), "full")
		testing.expect(t, sim.queue_at(&queue, 3) == nil)
		for k in 2 ..= 4 {
			value, ok := sim.pop_front(&queue)
			testing.expect(t, ok)
			testing.expect_value(t, value, i32(round * 10 + k))
		}
		testing.expect(t, queue == {}, "an emptied queue is the zero value")
		sim.append(&queue, 7) // leave the head somewhere else for the next round
		sim.append(&queue, 8)
		sim.pop_front(&queue)
		testing.expect_value(t, queue.items[0], 0) // a vacated slot is zero
		sim.pop_front(&queue)
	}
}

@(test)
bits_at_word_edges :: proc(t: ^testing.T) {
	bits: sim.Bits(130)
	for index in ([]int{0, 63, 64, 127, 128, 129}) do sim.incl(&bits, index)
	testing.expect_value(t, sim.card(&bits), 6)
	testing.expect(t, sim.has(&bits, 64) && !sim.has(&bits, 65) && !sim.has(&bits, 130) && !sim.has(&bits, -1))
	sim.excl(&bits, 64)
	got: [dynamic]int
	defer delete(got)
	walk := sim.iterate(&bits)
	for index in sim.next(&walk) do append(&got, index)
	testing.expect_value(t, len(got), 5)
	want := []int{0, 63, 127, 128, 129}
	for index, i in want do testing.expect_value(t, got[i], index)
	sim.clear(&bits)
	testing.expect_value(t, sim.card(&bits), 0)
}

@(test)
collections_are_plain_for_any_element :: proc(t: ^testing.T) {
	Wide :: struct {
		a: u64,
		b: u8,
		_: [7]u8,
	}
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.List(u8, 5))), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.List(u16, 3))), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.List(f32, 7))), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.List(Wide, 3))), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.List([3]u16, 3))), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.Queue(u8, 3))), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.Queue(u64, 2))), "")
	testing.expect_value(t, sim.plain_violation(type_info_of(sim.Bits(100))), "")
	#assert(size_of(sim.List(u8, 5)) == 6)
	#assert(size_of(sim.List(Wide, 3)) == 56)
	testing.expect_value(t, sim.plain_violation(type_info_of(Swarm_State)), "")
}

// The desync report reads a List by its live items, a Queue oldest first and a Bits as its indices.
@(test)
snapshot_diff_reads_collections :: proc(t: ^testing.T) {
	simulation := sim.create(&SWARM, 3)
	defer sim.destroy(simulation)
	sim.append(&simulation.state.bag, toy.Thing{life = 1})
	sim.append(&simulation.state.bag, toy.Thing{life = 2})
	sim.save(simulation)
	before := sim.snapshot_encode(simulation, 0)
	defer delete(before)
	simulation.state.bag.items[1].life = 5
	sim.append(&simulation.state.bag, toy.Thing{life = 3})
	sim.append(&simulation.state.queue, 9)
	sim.incl(&simulation.state.seen, 12)
	sim.save(simulation)
	after := sim.snapshot_encode(simulation, 0)
	defer delete(after)
	diff := sim.snapshot_diff(Swarm_State, before, after)
	testing.expect(t, strings.contains(diff, "bag: 2 vs 3 items"), diff)
	testing.expect(t, strings.contains(diff, "bag[1].life 2 vs 5"), diff)
	testing.expect(t, strings.contains(diff, "bag[2].life 0 vs 3"), diff)
	testing.expect(t, strings.contains(diff, "queue: 0 vs 1 items"), diff)
	testing.expect(t, strings.contains(diff, "queue[0] 0 vs 9"), diff)
	testing.expect(t, strings.contains(diff, "seen: {} vs {12}"), diff)
	testing.expect(t, !strings.contains(diff, "count"), diff)
}

// An add after grid_end leaves the grid unsorted (a query asserts) until the next grid_end, which sorts everything
// added since grid_begin.
@(test)
grid_add_after_end_needs_another_end :: proc(t: ^testing.T) {
	grid: sim.Grid(4, 8)
	sim.grid_begin(&grid, {0, 0}, 2, 2, 2)
	sim.grid_add(&grid, 1, {1, 1})
	sim.grid_end(&grid)
	testing.expect(t, grid.sorted)
	sim.grid_add(&grid, 2, {1, 1})
	testing.expect(t, !grid.sorted, "an add after grid_end leaves it sorted")
	sim.grid_end(&grid)
	near := sim.grid_near(&grid, {1, 1})
	ids: [dynamic]i32
	defer delete(ids)
	for row in near do for id in row do append(&ids, id)
	testing.expect(t, len(ids) == 2 && ids[0] == 1 && ids[1] == 2, "both adds sorted")
}

// Each cell holds exactly its ids in the order added; grid_near is the 3 × 3 cells by row, then column, then the
// order added; grid_box the same over a rectangle; positions outside count in the edge cells.
@(test)
grid_order :: proc(t: ^testing.T) {
	COLUMNS, ROWS :: 6, 5
	grid: sim.Grid(40, 200)
	points: [200][2]f32
	random := rand.create(11)
	generator := rand.default_random_generator(&random)
	for &point in points do point = {rand.float32_range(-3, 15, generator), rand.float32_range(-3, 12, generator)}
	sim.grid_begin(&grid, {0, 0}, 2, COLUMNS, ROWS)
	for point, i in points do testing.expect(t, sim.grid_add(&grid, i32(i), point))
	sim.grid_end(&grid)
	cell_of :: proc(point: [2]f32) -> (column, row: int) {
		column = clamp(int(point.x / 2) if point.x > 0 else 0, 0, COLUMNS - 1)
		row = clamp(int(point.y / 2) if point.y > 0 else 0, 0, ROWS - 1)
		return
	}
	expect_cells :: proc(t: ^testing.T, got: []i32, points: []([2]f32), columns, rows: [2]int) {
		want: [dynamic]i32
		defer delete(want)
		for row in rows[0] ..= rows[1] {
			for column in columns[0] ..= columns[1] {
				for point, i in points {
					c, r := cell_of(point)
					if c == column && r == row do append(&want, i32(i))
				}
			}
		}
		testing.expect_value(t, len(got), len(want))
		for id, i in want do if i < len(got) do testing.expect_value(t, got[i], id)
	}
	for probe in ([][2]f32{{5, 5}, {0.1, 0.1}, {-10, 20}, {11.9, 3}, {7, 9.99}}) {
		near: [dynamic]i32
		defer delete(near)
		for run in sim.grid_near(&grid, probe) do append(&near, ..run)
		column, row := cell_of(probe)
		expect_cells(
			t,
			near[:],
			points[:],
			{max(column - 1, 0), min(column + 1, COLUMNS - 1)},
			{max(row - 1, 0), min(row + 1, ROWS - 1)},
		)
		boxed: [dynamic]i32
		defer delete(boxed)
		box := sim.grid_box(&grid, probe - 3, probe + 3)
		for run in sim.next(&box) do append(&boxed, ..run)
		low_column, low_row := cell_of(probe - 3)
		high_column, high_row := cell_of(probe + 3)
		expect_cells(t, boxed[:], points[:], {low_column, high_column}, {low_row, high_row})
		// the corners the other way round: the same box
		clear(&boxed)
		swapped := sim.grid_box(&grid, {probe.x + 3, probe.y - 3}, {probe.x - 3, probe.y + 3})
		for run in sim.next(&swapped) do append(&boxed, ..run)
		expect_cells(t, boxed[:], points[:], {low_column, high_column}, {low_row, high_row})
	}
	sim.grid_begin(&grid, {0, 0}, 1, 1, 1)
	for i in 0 ..< 200 do sim.grid_add(&grid, i32(i), {})
	testing.expect(t, !sim.grid_add(&grid, 200, {}), "CAP reached")
}

// A grid in the World, rebuilt from the block every tick, survives a rollback: re-simulated ticks hash as they did.
@(test)
grid_survives_a_rollback :: proc(t: ^testing.T) {
	simulation := sim.create(&SWARM, 5)
	defer sim.destroy(simulation)
	inputs: sim.Inputs(Swarm_Game)
	sums: [200]u64
	for tick in 1 ..< 200 {
		sim.step(simulation, &inputs)
		sums[tick] = sim.checksum(simulation)
	}
	testing.expect(t, sim.card(&simulation.state.seen) > 20)
	testing.expect(t, sim.restore(simulation, 190))
	for tick in 191 ..< 200 {
		sim.step(simulation, &inputs)
		testing.expectf(t, sim.checksum(simulation) == sums[tick], "tick %d re-simulated differently", tick)
	}
}

// Over `period` consecutive ticks each key is due exactly once, and dense keys spread evenly.
@(test)
due_spreads_evenly :: proc(t: ^testing.T) {
	for period in u32(1) ..= 13 {
		times_due: [100]int
		for number in u32(40) ..< 40 + period {
			tick := toy.Tick {
				number = number,
				time   = sim.Game_Time(number),
			}
			per_tick := 0
			for key in 0 ..< 100 {
				if sim.due(&tick, key, period) {
					times_due[key] += 1
					per_tick += 1
				}
			}
			testing.expectf(
				t,
				per_tick >= 100 / int(period) && per_tick <= (100 + int(period) - 1) / int(period),
				"period %d: %d due on one tick",
				period,
				per_tick,
			)
		}
		for count, key in times_due do testing.expectf(t, count == 1, "period %d: key %d due %d times", period, key, count)
	}
}

// A keyed roll is a function of what it names: computed outside a tick (a HUD, from Frame.seed) it equals the roll
// the tick makes, and peeking touches no state.
@(test)
roll_peek_matches_the_tick :: proc(t: ^testing.T) {
	SEED :: 77
	simulation := sim.create(&SWARM, SEED)
	defer sim.destroy(simulation)
	inputs: sim.Inputs(Swarm_Game)
	for _ in 0 ..< 10 do sim.step(simulation, &inputs)
	peeked := sim.roll_f32_at(SEED, 11, Swarm_Roll.Kick, 0, 3)
	peeked_below := sim.roll_below_at(SEED, 11, 1000, Swarm_Roll.Kick, 9, 2)
	before := sim.checksum(simulation)
	_ = sim.roll_f32_at(SEED, 11, Swarm_Roll.Kick, 0, 3)
	testing.expect_value(t, sim.checksum(simulation), before)
	tick := sim.Tick(Swarm_Game) {
		seed   = SEED,
		number = 11,
	}
	testing.expect_value(t, sim.roll_f32(&tick, Swarm_Roll.Kick, 0, 3), peeked)
	testing.expect_value(t, sim.roll_below(&tick, 1000, Swarm_Roll.Kick, 9, 2), peeked_below)
}

// Clearing a queue whose live run wraps past the array's end leaves the zero value, as a fresh queue (clear zeroes
// the live items only: the rest is zero already).
@(test)
clearing_a_wrapped_queue_leaves_the_zero_value :: proc(t: ^testing.T) {
	queue: sim.Queue(i32, 4)
	for value in 1 ..= 4 do sim.append(&queue, i32(value))
	sim.pop_front(&queue)
	sim.pop_front(&queue)
	sim.pop_front(&queue)
	sim.append(&queue, 5)
	sim.append(&queue, 6) // head 3: items 4, 5, 6 across the end
	sim.clear(&queue)
	testing.expect(t, queue == {})
}
