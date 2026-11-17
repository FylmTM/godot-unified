// src/sim/SPEC.md, batch 7 (#243, #252, #237): what a Tick carries (dt, the decoded commands, init's tick 0), the
// time helpers, handle_of_key, events with padding, and the Extras' check.
package test_sim

import "core:testing"

import "../toy"
import "unified:sim"

// What the probe's tick saw.
Probe_World :: struct {
	init_number: u32,
	init_dt:     f32,
	tick_dt:     f32,
	seen:        [toy.PLAYERS]int, // commands per slot on the last tick
	nil_seen:    int, // nil entries ever yielded
	bump_sum:    i32,
}

Probe_Game :: sim.Game(toy.State, toy.Input, Probe_World, toy.Event, toy.Cmd, toy.PLAYERS)
Probe_Tick :: sim.Tick(toy.State, toy.Input, Probe_World, toy.Event, toy.Cmd, toy.PLAYERS)

PROBE := Probe_Game {
	name = "probe",
	version = "1",
	tick_hz = 32,
	world_create = proc(seed: u64, _: []u8) -> ^Probe_World {return new(Probe_World)},
	world_destroy = proc(world: ^Probe_World) {free(world)},
	init = proc(t: ^Probe_Tick) {
		t.world.init_number = t.number
		t.world.init_dt = t.dt
		sim.emit(t, toy.Event_Expired{}) // init may emit: tick 0's events
	},
	tick = proc(t: ^Probe_Tick) {
		t.world.tick_dt = t.dt
		t.world.seen = {}
		players := sim.iterate_present(&t.state.players)
		for _, player in sim.next(&players) {
			slot, _ := sim.player_slot(&t.state.players, player)
			for sent in sim.commands(t, player) {
				t.world.seen[slot] += 1
				switch command in sent {
				case toy.Cmd_Bump:
					t.world.bump_sum += command.amount
				case toy.Cmd_Mark:
				case:
					t.world.nil_seen += 1
				}
			}
		}
	},
}

@(test)
init_gets_a_tick_and_every_tick_its_dt :: proc(t: ^testing.T) {
	simulation := sim.create(&PROBE, 3)
	defer sim.destroy(simulation)
	testing.expect_value(t, simulation.world.init_number, 0)
	testing.expect_value(t, simulation.world.init_dt, 1.0 / 32)
	testing.expect_value(t, len(sim.events_at(simulation, 0)), 1)
	inputs: toy.Inputs
	sim.step(simulation, &inputs)
	testing.expect_value(t, simulation.world.tick_dt, 1.0 / 32)
}

// A sim restored from a snapshot has no events at the snapshot's tick, even when that tick shares ring slot 0 with
// tick 0, whose events init emitted.
@(test)
snapshot_restore_drops_init_events :: proc(t: ^testing.T) {
	simulation := sim.create(&PROBE, 3)
	defer sim.destroy(simulation)
	inputs: toy.Inputs
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

@(test)
commands_yield_only_real_ones_by_player :: proc(t: ^testing.T) {
	simulation := sim.create(&PROBE, 3)
	defer sim.destroy(simulation)
	inputs: toy.Inputs
	sim.join(&inputs, 0, 1)
	sim.join(&inputs, 2, 3)
	add :: proc(inputs: ^toy.Inputs, slot: int, raw: sim.Raw_Command) {
		raw := raw
		raw.slot = u8(slot)
		assert(sim.add_command(inputs, raw))
	}
	add(&inputs, 0, sim.command_make(toy.Cmd, toy.Cmd_Bump{5}))
	unknown := sim.command_make(toy.Cmd, toy.Cmd_Bump{100})
	unknown.kind = 9 // no such variant: left out
	add(&inputs, 0, unknown)
	short := sim.command_make(toy.Cmd, toy.Cmd_Bump{100})
	short.size = 3 // the wrong size: left out
	add(&inputs, 2, short)
	add(&inputs, 2, sim.command_make(toy.Cmd, toy.Cmd_Mark{count = 1}))
	add(&inputs, 2, sim.command_make(toy.Cmd, toy.Cmd_Bump{-2}))
	add(&inputs, 3, sim.command_make(toy.Cmd, toy.Cmd_Bump{1000})) // slot 3 is nobody's
	sim.step(simulation, &inputs)
	testing.expect_value(t, simulation.world.seen, [toy.PLAYERS]int{1, 0, 2, 0})
	testing.expect_value(t, simulation.world.nil_seen, 0)
	testing.expect_value(t, simulation.world.bump_sum, 3)
	// The next tick has none: the buffer is the tick's.
	next: toy.Inputs
	next.present = {0, 2}
	sim.step(simulation, &next)
	testing.expect_value(t, simulation.world.seen, [toy.PLAYERS]int{})
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

@(test)
handle_keys_round_trip :: proc(t: ^testing.T) {
	things: sim.Table(toy.Thing, 8)
	_, first, _ := sim.spawn(&things)
	sim.despawn(&things, first)
	_, second, _ := sim.spawn(&things) // the same slot, the next generation
	key := sim.handle_key(second)
	testing.expect_value(t, sim.handle_of_key(toy.Thing, key), second)
	testing.expect(t, sim.get(&things, sim.handle_of_key(toy.Thing, key)) != nil)
	testing.expect(t, sim.get(&things, sim.handle_of_key(toy.Thing, sim.handle_key(first))) == nil) // stale
	testing.expect(t, sim.get(&things, sim.handle_of_key(toy.Thing, 0)) == nil)
}

// Events need no _pad fields (never hashed or compared as bytes); commands still do (the wire, inputs_same).
@(test)
events_may_have_padding :: proc(t: ^testing.T) {
	Event_Padded :: struct {
		player: sim.Player,
		speed:  u8, // one byte of padding after it
	}
	Padded_Events :: union {
		sim.Event_Player_Joined,
		sim.Event_Player_Left,
		Event_Padded,
	}
	Padded_Commands :: union {
		Event_Padded,
	}
	testing.expect_value(t, sim.game_violation("toy", 64, toy.Cmd, Padded_Events), "")
	testing.expect(t, sim.game_violation("toy", 64, Padded_Commands, toy.Event) != "")
	Event_Pointer :: struct {
		at: ^int,
	}
	Pointer_Events :: union {
		sim.Event_Player_Joined,
		sim.Event_Player_Left,
		Event_Pointer,
	}
	testing.expect(t, sim.game_violation("toy", 64, toy.Cmd, Pointer_Events) != "") // the other rules stand
}

// An extra whose check fails while `broken` is set.
Checked :: struct {
	broken: bool,
}

g_checked: ^Checked

@(test)
check_runs_every_extras_check :: proc(t: ^testing.T) {
	checked: Checked
	g_checked = &checked
	defer g_checked = nil
	game := toy.GAME
	game.extras = proc(world: ^toy.World) -> []sim.Extra {
		@(static) extras: [2]sim.Extra
		quiet := sim.Extra {
			save = proc(data: rawptr, slot: int) {},
			restore = proc(data: rawptr, slot: int) -> bool {return true},
			hash = proc(data: rawptr, state: rawptr, tick: u32, out: ^[dynamic]u8) {},
			image = proc(data: rawptr, slot: int) -> []u8 {return nil},
			load = proc(data: rawptr, bytes: []u8) -> bool {return true},
		}
		extras[0] = quiet // no check: always agrees
		extras[1] = quiet
		extras[1].data = g_checked
		extras[1].check = proc(data: rawptr, state: rawptr) -> string {
			return "a broken ref" if (^Checked)(data).broken else ""
		}
		return extras[:]
	}
	simulation := sim.create(&game, 7)
	defer sim.destroy(simulation)
	testing.expect_value(t, sim.check(simulation), "")
	checked.broken = true
	testing.expect_value(t, sim.check(simulation), "a broken ref")
}
