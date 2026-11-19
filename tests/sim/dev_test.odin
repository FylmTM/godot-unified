// Debug draws and zones (sim/dev.odin): kept per tick beside the events, drawn again identically when a tick is
// re-simulated, nothing for a hidden group or without a Dev, self times that add up to the step, and never state.
package test_sim

import "core:testing"

import "../toy"
import "unified:sim"

Test_Zone :: enum u8 {
	Outer,
	Inner,
}

// The toy's tick inside two nested zones, drawing in each and outside any.
drawn_tick :: proc(t: ^toy.Tick) {
	{
		sim.zone(t, Test_Zone.Outer)
		sim.debug_line(t, sim.Position{f32(t.number), 0, 0}, [3]f32{0, 1, 0}, .Red)
		{
			sim.zone(t, Test_Zone.Inner)
			toy.tick(t)
			sim.debug_text(t, sim.Position{}, "tick %d spawned %d", t.number, t.state.spawned)
		}
	}
	sim.debug_sphere(t, [3]f32{1, 2, 3}, 0.5)
}

drawn_game :: proc() -> toy.Game {
	game := toy.GAME
	game.tick = drawn_tick
	return game
}

// A clock that moves 100 ns a reading.
@(thread_local)
fake_now: i64
fake_clock :: proc "contextless" () -> i64 {
	fake_now += 100
	return fake_now
}

@(test)
draws_are_kept_per_tick_and_drawn_again :: proc(t: ^testing.T) {
	game := drawn_game()
	simulation := sim.create(&game, 3)
	defer sim.destroy(simulation)
	dev := sim.dev_attach(simulation)
	testing.expect(t, dev != nil && sim.dev_attach(simulation) == dev, "attached once")
	sim.dev_enable(simulation, max(u64))
	run(simulation, 12)
	draws := sim.debug_draws(simulation, 10)
	if !testing.expect(t, draws != nil && len(draws.shapes) == 3, "three draws a tick") do return
	testing.expect_value(t, draws.shapes[0].kind, sim.Debug_Kind.Line)
	testing.expect_value(t, draws.shapes[0].group, u8(Test_Zone.Outer))
	testing.expect_value(t, draws.shapes[0].color, u32(sim.Debug_Color.Red))
	testing.expect_value(t, draws.shapes[0].a, [3]f32{10, 0, 0})
	testing.expect_value(t, draws.shapes[1].group, u8(Test_Zone.Inner))
	text := draws.shapes[1].text
	testing.expect_value(t, string(draws.text[text[1]:][:text[0]]), "tick 10 spawned 1")
	testing.expect_value(t, draws.shapes[2].group, u8(sim.DEBUG_GROUP_OTHER))
	testing.expect_value(t, dev.groups[0], "outer")
	testing.expect_value(t, dev.groups[sim.DEBUG_GROUP_OTHER], "other")
	// re-simulated from tick 9: the same draws again, replacing the old ones
	before := make([]sim.Debug_Shape, len(draws.shapes), context.temp_allocator)
	copy(before, draws.shapes[:])
	before_text := string(draws.text[:])
	testing.expect(t, sim.restore(simulation, 9))
	testing.expect(t, sim.debug_draws(simulation, 10) == nil, "the later ticks left the ring")
	run(simulation, 3)
	again := sim.debug_draws(simulation, 10)
	testing.expect_value(t, len(again.shapes), len(before))
	for shape, i in before do testing.expect_value(t, again.shapes[i], shape)
	testing.expect_value(t, string(again.text[:]), before_text)
	// a hidden group keeps nothing; no group shown keeps nothing at all
	sim.dev_enable(simulation, 1 << uint(Test_Zone.Inner))
	run(simulation, 1)
	shown := sim.debug_draws(simulation, simulation.tick)
	testing.expect(t, len(shown.shapes) == 1 && shown.shapes[0].kind == .Text, "only the inner zone's")
	sim.dev_enable(simulation, 0)
	run(simulation, 1)
	testing.expect_value(t, len(sim.debug_draws(simulation, simulation.tick).shapes), 0)
}

// No Dev: no draws and no zones, and the same trace as a Dev with everything on (never state).
@(test)
draws_and_zones_are_never_state :: proc(t: ^testing.T) {
	game := drawn_game()
	plain := sim.create(&game, 9)
	defer sim.destroy(plain)
	drawn := sim.create(&game, 9)
	defer sim.destroy(drawn)
	sim.dev_attach(drawn, fake_clock)
	sim.dev_enable(drawn, max(u64))
	for _ in 0 ..< 40 {
		run(plain, 1)
		run(drawn, 1)
		testing.expect_value(t, sim.checksum(drawn), sim.checksum(plain))
	}
	testing.expect_value(t, len(sim.debug_draws(plain, 40).shapes), 0)
	testing.expect(t, sim.zone_totals(plain).names == nil, "no zones without a Dev")
	testing.expect_value(t, len(sim.debug_draws(drawn, 40).shapes), 3)
}

// Self times: an inner zone's time is not its outer zone's, and the zones and "other" add up to the step.
@(test)
zones_report_self_times :: proc(t: ^testing.T) {
	game := drawn_game()
	simulation := sim.create(&game, 1)
	defer sim.destroy(simulation)
	sim.dev_attach(simulation, fake_clock)
	run(simulation, 5)
	totals := sim.zone_totals(simulation)
	if !testing.expect_value(t, len(totals.names), 3) do return
	testing.expect_value(t, totals.names[0], "outer")
	testing.expect_value(t, totals.names[1], "inner")
	testing.expect_value(t, totals.names[2], "other")
	// per step, 100 ns a reading: step start, outer opens, inner opens, inner ends, outer ends, step end
	testing.expect_value(t, totals.ns[1], 5 * 100) // inner: one reading apart
	testing.expect_value(t, totals.ns[0], 5 * 200) // outer: three apart, less inner's
	testing.expect_value(t, totals.ns[2], 5 * 200) // other: five apart, less the outer zone's three
	testing.expect_value(t, totals.calls[0], 5)
	testing.expect_value(t, totals.calls[2], 5)
}

// The op log: what a tick changed, a line per leaf (a table item by index), nothing for equal states, at most `limit`
// lines with the total counted.
@(test)
state_changes_lists_what_a_tick_changed :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 3)
	defer sim.destroy(simulation)
	run(simulation, 30)
	before := simulation.state
	run(simulation, 1)
	lines, total := sim.state_changes(type_info_of(toy.State), &before, &simulation.state)
	testing.expectf(t, total > 0 && len(lines) == total, "%d changes: %v", total, lines)
	for line in lines do testing.expectf(t, len(line) > 0 && line[0] != ' ', "a path first: %q", line)
	none, none_total := sim.state_changes(type_info_of(toy.State), &before, &before)
	testing.expect(t, len(none) == 0 && none_total == 0, "equal states change nothing")
	limited, limited_total := sim.state_changes(type_info_of(toy.State), &before, &simulation.state, limit = 1)
	testing.expect(t, len(limited) == 1 && limited_total == total, "limited, counted")
}

// Without a clock, zones are not timed but still name the draws' groups.
@(test)
zones_without_a_clock_still_group :: proc(t: ^testing.T) {
	game := drawn_game()
	simulation := sim.create(&game, 1)
	defer sim.destroy(simulation)
	sim.dev_attach(simulation)
	sim.dev_enable(simulation, max(u64))
	run(simulation, 2)
	totals := sim.zone_totals(simulation)
	testing.expect(t, len(totals.ns) == 3 && totals.ns[0] == 0 && totals.calls[0] == 2, "counted, not timed")
	testing.expect_value(t, sim.debug_draws(simulation, 2).shapes[1].group, u8(Test_Zone.Inner))
}

// Each of the six draws, from tick code and into a library's sink: one shape of its kind with its colour and
// measures, the tick's in the "other" group, the sink's in the library group it named.
every_draw_tick :: proc(t: ^toy.Tick) {
	sim.debug_line(t, sim.Position{1, 0, 0}, [3]f32{2, 0, 0}, .Red)
	sim.debug_point(t, [3]f32{3, 0, 0}, .Green, 0.5)
	sim.debug_sphere(t, sim.Position{4, 0, 0}, 1.5, .Blue)
	sim.debug_capsule(t, [3]f32{5, 0, 0}, [3]f32{5, 1, 0}, 0.25, .Cyan)
	sim.debug_box(t, sim.Position{6, 0, 0}, {1, 2, 3}, {0, 0, 0, 1}, .Magenta)
	sim.debug_text(t, sim.Position{7, 0, 0}, "hp %d", 9, color = .Orange)
	sink, shown := sim.debug_sink(t, "test_sink")
	if !shown do return
	sim.debug_line(sink, {1, 0, 0}, {2, 0, 0}, .Red)
	sim.debug_point(sink, {3, 0, 0}, .Green, 0.5)
	sim.debug_sphere(sink, {4, 0, 0}, 1.5, .Blue)
	sim.debug_capsule(sink, {5, 0, 0}, {5, 1, 0}, 0.25, .Cyan)
	sim.debug_box(sink, {6, 0, 0}, {1, 2, 3}, {0, 0, 0, 1}, .Magenta)
	sim.debug_text(sink, {7, 0, 0}, "hp 9", .Orange)
}

@(test)
every_draw_from_tick_code_and_into_a_sink :: proc(t: ^testing.T) {
	game := toy.GAME
	game.tick = every_draw_tick
	simulation := sim.create(&game, 3)
	defer sim.destroy(simulation)
	if sim.dev_attach(simulation) == nil do return // a build without the dev UI draws nothing
	sim.dev_enable(simulation, max(u64))
	run(simulation, 2)
	draws := sim.debug_draws(simulation, 2)
	if !testing.expect(t, draws != nil && len(draws.shapes) == 12, "six draws from each target") do return
	kinds := [6]sim.Debug_Kind{.Line, .Point, .Sphere, .Capsule, .Box, .Text}
	colors := [6]sim.Debug_Color{.Red, .Green, .Blue, .Cyan, .Magenta, .Orange}
	sizes := [6]f32{0, 0.5, 1.5, 0.25, 0, 0}
	xs := [6]f32{1, 3, 4, 5, 6, 7}
	for shape, i in draws.shapes {
		k := i % 6
		testing.expectf(t, shape.kind == kinds[k], "draw %d: %v", i, shape.kind)
		testing.expectf(t, shape.color == u32(colors[k]), "draw %d: colour %x", i, shape.color)
		testing.expectf(t, shape.a.x == xs[k], "draw %d: at %v", i, shape.a)
		testing.expectf(t, shape.size == sizes[k], "draw %d: size %v", i, shape.size)
		testing.expectf(t, (shape.group == sim.DEBUG_GROUP_OTHER) == (i < 6), "draw %d: group %d", i, shape.group)
		if shape.kind == .Text do testing.expect_value(t, string(draws.text[shape.text[1]:][:shape.text[0]]), "hp 9")
	}
	testing.expect_value(t, draws.shapes[3].b, [3]f32{5, 1, 0})
	testing.expect_value(t, draws.shapes[4].b, [3]f32{1, 2, 3})
	testing.expect_value(t, draws.shapes[4].rot, [4]f32{0, 0, 0, 1})
}
