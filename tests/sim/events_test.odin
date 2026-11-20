// Events: names, emission per tick (init's included), re-emission on re-simulation, the probe game.
package test_sim

import "core:testing"

import "../toy"
import "unified:sim"

// The names the host binds commands and events by (sim.variant_name), by kind.
@(test)
names_derive_from_the_types :: proc(t: ^testing.T) {
	names :: proc(type: typeid, prefix: string) -> []string {
		variants := sim.union_variants(type)
		out := make([]string, len(variants), context.temp_allocator)
		for variant, i in variants do out[i] = sim.variant_name(variant, prefix)
		return out
	}
	commands := names(toy.Cmd, sim.COMMAND_PREFIX)
	testing.expect(
		t,
		len(commands) == 6 &&
		commands[0] == "bump" &&
		commands[1] == "mark" &&
		commands[2] == "clear_bumps" &&
		commands[3] == "travel" &&
		commands[4] == "pause" &&
		commands[5] == "trail",
	)
	events := names(toy.Event, sim.EVENT_PREFIX)
	testing.expect(
		t,
		len(events) == 4 && events[0] == "player_joined" && events[1] == "player_left" && events[3] == "expired",
	)
	// an event type may carry an Event_ prefix: the name leaves it out, like a command's Cmd_
	prefixed := names(Prefixed_Events, sim.EVENT_PREFIX)
	testing.expect(t, len(prefixed) == 2 && prefixed[0] == "rock_hit" && prefixed[1] == "plain")
}

Event_Rock_Hit :: struct {
	rock: u8,
}

Plain :: struct {
	value: u8,
}

Prefixed_Events :: union {
	Event_Rock_Hit,
	Plain,
}

// A [2]f32 point as an event's position names its plane: a 2D game's XY plane (the toy's spawn uses it), or a 3D
// game's floor kept as (x, z).
@(test)
a_position_from_a_point_names_its_plane :: proc(t: ^testing.T) {
	testing.expect_value(t, sim.position_2d({1.5, -2}), sim.Position{1.5, -2, 0})
	testing.expect_value(t, sim.position_2d({}), sim.Position{})
	testing.expect_value(t, sim.position_floor({1.5, -2}), sim.Position{1.5, 0, -2})
	testing.expect_value(t, sim.position_floor({1.5, -2}, 0.25), sim.Position{1.5, 0.25, -2})
}

@(test)
events_follow_the_inputs :: proc(t: ^testing.T) {
	simulation := sim.create(&toy.GAME, 1)
	defer sim.destroy(simulation)
	inputs: toy.Inputs
	join_record(&inputs, 0, 1)
	join_record(&inputs, 2, 7)
	inputs.input[0].buttons = {.Spawn}
	sim.step(simulation, &inputs)
	events := sim.events_at(simulation, 1)
	testing.expect_value(t, len(events), 3) // joined 0, joined 2 (the library's, first), spawned by 0
	if len(events) != 3 do return
	joined, is_joined := sim.event_value(&events[0], toy.Event).(sim.Event_Player_Joined)
	testing.expect(t, is_joined && joined.slot == 0 && joined.player.id == 1 && !joined.returning)
	second := sim.event_value(&events[1], toy.Event).(sim.Event_Player_Joined)
	testing.expect(t, second.slot == 2 && second.player.id == 7)
	spawned, is_spawned := sim.event_value(&events[2], toy.Event).(toy.Event_Spawned)
	testing.expect(t, is_spawned && spawned.player == joined.player)
	thing := sim.get(&simulation.state.things, spawned.thing)
	testing.expect(t, thing != nil && spawned.position == {thing.pos.x, thing.pos.y, 0})
	inputs = {}
	inputs.present = {0}
	inputs.input[0].buttons = {.Spawn}
	sim.step(simulation, &inputs)
	events = sim.events_at(simulation, 2)
	testing.expect_value(t, len(events), 1) // left 2 (the button still down: no press, no spawn)
	left, is_left := sim.event_value(&events[0], toy.Event).(sim.Event_Player_Left)
	testing.expect(t, is_left && left.player == second.player && left.slot == 2)
	// Re-simulating tick 2 with other inputs replaces its events: 2 stays, the button is released.
	testing.expect(t, sim.restore(simulation, 1))
	inputs.present = {0, 2}
	inputs.input[0].buttons = {}
	sim.step(simulation, &inputs)
	testing.expect_value(t, len(sim.events_at(simulation, 2)), 0)
	// pressed again (down now, up the tick before: sim.input_before): spawned
	inputs.input[0].buttons = {.Spawn}
	sim.step(simulation, &inputs)
	testing.expect_value(t, len(sim.events_at(simulation, 3)), 1)
	// A kind out of range or a wrong size reads as nil.
	broken := sim.Raw_Event {
		kind = 9,
		size = 1,
	}
	testing.expect(t, sim.event_value(&broken, toy.Event) == nil)
	broken = {
		kind = 0,
		size = 2,
	}
	testing.expect(t, sim.event_value(&broken, toy.Event) == nil)
}

// What the probe's tick saw.
Probe_World :: struct {
	init_number: u32,
	init_dt:     f32,
	tick_dt:     f32,
}

Probe_Game :: sim.Game(toy.State, toy.Input, Probe_World, toy.Event, toy.Cmd, sim.No_Setup, toy.Profile, toy.PLAYERS)
Probe_Tick :: sim.Tick(Probe_Game)
Probe_Inputs :: sim.Inputs(Probe_Game)

PROBE := Probe_Game {
	name = "probe",
	version = "1",
	tick_hz = 32,
	init = proc(t: ^Probe_Tick) {
		t.world.init_number = t.number
		t.world.init_dt = t.dt
		sim.emit(t, toy.Event_Expired{}) // init may emit: tick 0's events
	},
	tick = proc(t: ^Probe_Tick) {t.world.tick_dt = t.dt},
}

@(test)
init_gets_a_tick_and_every_tick_its_dt :: proc(t: ^testing.T) {
	simulation := sim.create(&PROBE, 3)
	defer sim.destroy(simulation)
	testing.expect_value(t, simulation.world.init_number, 0)
	testing.expect_value(t, simulation.world.init_dt, 1.0 / 32)
	testing.expect_value(t, len(sim.events_at(simulation, 0)), 1)
	inputs: Probe_Inputs
	sim.step(simulation, &inputs)
	testing.expect_value(t, simulation.world.tick_dt, 1.0 / 32)
}

// A sim restored from a snapshot has no events at the snapshot's tick, even when that tick shares ring slot 0 with
// tick 0, whose events init emitted.
@(test)
snapshot_restore_drops_init_events :: proc(t: ^testing.T) {
	simulation := sim.create(&PROBE, 3)
	defer sim.destroy(simulation)
	inputs: Probe_Inputs
	tick := u32(len(simulation.ring)) // ring slot 0
	for _ in 0 ..< tick do sim.step(simulation, &inputs)
	data := sim.snapshot_encode(simulation, tick)
	defer delete(data)
	restored, err := sim.from_snapshot(&PROBE, data)
	testing.expect_value(t, err, sim.Snap_Error.None)
	if restored == nil do return
	defer sim.destroy(restored)
	testing.expect_value(t, restored.tick, tick)
	testing.expect_value(t, len(sim.events_at(restored, tick)), 0)
}
