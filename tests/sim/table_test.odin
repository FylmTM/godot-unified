// Tables and handles: null and stale handles, the walk, an item by index, despawn_all.
package test_sim

import "core:testing"

import "../toy"
import "unified:sim"

Small :: sim.Table(toy.Thing, 4)

@(test)
zero_handle_is_null :: proc(t: ^testing.T) {
	table: Small
	_, handle, ok := sim.spawn(&table)
	testing.expect(t, ok)
	testing.expect_value(t, handle.index, 0)
	testing.expect(t, sim.get(&table, sim.Handle(toy.Thing){}) == nil)
	testing.expect(t, sim.get(&table, handle) == &table.items[0])
	testing.expect(t, sim.get(&table, sim.Handle(toy.Thing){index = 9, generation = 1}) == nil) // out of range
	testing.expect_value(t, size_of(sim.Handle(toy.Thing)), 8)
}

@(test)
stale_handles_are_rejected :: proc(t: ^testing.T) {
	table: Small
	_, first, _ := sim.spawn(&table)
	_, second, _ := sim.spawn(&table)
	testing.expect(t, sim.despawn(&table, first))
	testing.expect(t, sim.get(&table, first) == nil)
	testing.expect(t, !sim.despawn(&table, first))
	testing.expect(t, sim.get(&table, second) != nil)
	_, reused, _ := sim.spawn(&table) // LIFO reuse of the first slot, next generation
	testing.expect_value(t, reused.index, first.index)
	testing.expect(t, sim.get(&table, first) == nil)
	testing.expect(t, sim.get(&table, reused) != nil)
	testing.expect(t, sim.handle_key(reused) != sim.handle_key(first))
	testing.expect_value(t, sim.handle_of_key(toy.Thing, sim.handle_key(reused)), reused)
	testing.expect(t, sim.get(&table, sim.handle_of_key(toy.Thing, sim.handle_key(first))) == nil) // stale
	testing.expect(t, sim.get(&table, sim.handle_of_key(toy.Thing, 0)) == nil)
	testing.expect_value(t, table.count, 2)
	for _ in 0 ..< 2 {
		_, _, ok := sim.spawn(&table)
		testing.expect(t, ok)
	}
	_, _, full := sim.spawn(&table)
	testing.expect(t, !full)
}

@(test)
an_item_by_index_is_the_live_one_with_its_handle :: proc(t: ^testing.T) {
	table: Small
	_, first, _ := sim.spawn(&table)
	_, second, _ := sim.spawn(&table)
	sim.despawn(&table, first)
	_, _, free := sim.item_at(&table, 0)
	testing.expect(t, !free)
	item, handle, ok := sim.item_at(&table, 1)
	testing.expect(t, ok)
	testing.expect_value(t, handle, second)
	testing.expect(t, item == sim.get(&table, second))
	_, _, unused := sim.item_at(&table, 2) // never spawned
	testing.expect(t, !unused)
	_, _, below := sim.item_at(&table, -1)
	_, _, above := sim.item_at(&table, 4)
	testing.expect(t, !below && !above)
	_, reused, _ := sim.spawn(&table) // slot 0 again, its next generation
	_, again, _ := sim.item_at(&table, 0)
	testing.expect_value(t, again, reused)
	testing.expect(t, again != first)
}

@(test)
iterator_walks_live_items_in_index_order :: proc(t: ^testing.T) {
	Ten :: sim.Table(toy.Thing, 10)
	table: Ten
	handles: [10]sim.Handle(toy.Thing)
	for i in 0 ..< 10 {
		thing, handle, _ := sim.spawn(&table)
		thing.life = i32(i)
		handles[i] = handle
	}
	for i in ([]int{1, 4, 5, 9}) {
		sim.despawn(&table, handles[i])
	}
	seen: [dynamic]i32
	defer delete(seen)
	items := sim.iterate(&table)
	for thing, handle in sim.next(&items) {
		append(&seen, thing.life)
		testing.expect(t, sim.get(&table, handle) == thing) // the handle comes with the item
		if thing.life % 2 == 0 do sim.despawn(&table, handle) // despawning the current item is safe
	}
	testing.expect(t, len(seen) == 6 && seen[0] == 0 && seen[1] == 2 && seen[2] == 3 && seen[5] == 8)
	testing.expect_value(t, table.count, 2) // 3 and 7 are left
	left: [dynamic]i32
	defer delete(left)
	items = sim.iterate(&table)
	for thing, _ in sim.next(&items) do append(&left, thing.life)
	testing.expect(t, len(left) == 2 && left[0] == 3 && left[1] == 7)
	empty: Small
	none := sim.iterate(&empty)
	for _, _ in sim.next(&none) do testing.fail(t)
	// A walk covers the slots in use when it started: a spawn into a free slot ahead is visited, one into a fresh
	// slot is not.
	spawning: Small
	_, gap, _ := sim.spawn(&spawning)
	sim.spawn(&spawning)
	sim.despawn(&spawning, gap)
	visited := 0
	walk := sim.iterate(&spawning)
	for thing in sim.next(&walk) {
		visited += 1
		if thing.life == 0 {
			thing.life = 1
			sim.spawn(&spawning) // slot 0, behind the walk
			sim.spawn(&spawning) // slot 2, fresh
		}
	}
	testing.expect_value(t, visited, 1)
	testing.expect_value(t, spawning.count, 3)
}

// despawn_all despawns everything and keeps the generations: spawns start again from slot 0, and no old handle or key
// names a new item.
@(test)
despawn_all_keeps_the_generations :: proc(t: ^testing.T) {
	table: Small
	_, first, _ := sim.spawn(&table)
	_, second, _ := sim.spawn(&table)
	sim.despawn_all(&table)
	testing.expect_value(t, table.count, 0)
	testing.expect(t, sim.get(&table, first) == nil && sim.get(&table, second) == nil)
	items := sim.iterate(&table)
	for _ in sim.next(&items) do testing.fail(t)
	_, again, _ := sim.spawn(&table)
	testing.expect_value(t, again.index, first.index)
	testing.expect(t, sim.handle_key(again) != sim.handle_key(first))
	testing.expect(t, sim.get(&table, first) == nil && sim.get(&table, again) != nil)
}
