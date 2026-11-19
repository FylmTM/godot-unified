// The toy without an Input (sim.No_Input): its players act through commands only, the shape of a turn-based game. A
// bump spawns a thing at the sender's dot (its life a keyed roll), a mark moves the dot to where it points, and the
// toy's travel and pause work as there, so a session of it crosses level changes and pauses with nothing on the
// input wire.
package toy

import "unified:sim"

Still_Player :: struct {
	pos:   [2]f32,
	score: i32,
	bumps: u32, // bump commands applied
	color: u32, // their Profile's, from the tick they arrived
}

Still_State :: struct {
	spawned: u32,
	level:   sim.Active_Level(Area),
	_pad:    u32,
	clock:   sim.Clock,
	players: sim.Players(Still_Player, Profile, sim.No_Input, PLAYERS),
	things:  sim.Table(Thing, 32),
}

Still_Game :: sim.Game(Still_State, sim.No_Input, World, Event, Cmd, Setup, Profile, PLAYERS)
Still_Tick :: sim.Tick(Still_Game)

STILL := Still_Game {
	name = "toy_still",
	version = "1",
	tick_hz = HZ,
	levels = {
		{"meadow", #load("../godot_views/levels/meadow.level")},
		{"cave", #load("../godot_views/levels/cave.level")},
	},
	init = proc(t: ^Still_Tick) {sim.level_enter(t, Area.Meadow)},
	tick = still_tick,
	scripted_commands = proc(seed: u64, slot: int, tick: u32, state: ^Still_State, out: ^sim.Command_Out(Cmd)) {
		commands_of(seed, slot, tick, out, 3)
	},
	scripted_profile = scripted_profile,
}

still_tick :: proc(t: ^Still_Tick) {
	t.world.ticks_run += 1
	for player in t.player_changes.arrived {
		sim.player_data(t, player).color = u32(sim.player_profile(t, player).color)
	}
	players := sim.iterate_present(t)
	for data, player in sim.next(&players) {
		for sent in sim.commands(t, player) {
			switch command in sent {
			case Cmd_Bump:
				data.bumps += 1
				if t.state.things.count < 32 {
					thing, handle, _ := sim.spawn(&t.state.things)
					thing.pos = data.pos
					thing.life = i32(4 + sim.roll_below(t, 60, Roll.Thing_Life, sim.handle_key(handle)))
					thing.owner = player
					t.state.spawned += 1
					sim.emit(t, Event_Spawned{thing = handle, position = sim.position_2d(thing.pos), player = player})
				}
			case Cmd_Mark:
				data.pos = command.at
			case Cmd_Clear_Bumps:
				data.bumps = 0
			case Cmd_Travel:
				if command.to != t.state.level.id do sim.level_enter(t, command.to)
			case Cmd_Pause:
				sim.set_paused(t, command.paused)
			case:
				panic("sim.commands yielded a nil entry")
			}
		}
	}
	if t.paused do return
	things := sim.iterate(&t.state.things)
	for thing, handle in sim.next(&things) {
		thing.life -= 1
		if thing.life <= 0 {
			if owner := sim.player_data(t, thing.owner); owner != nil do owner.score += 1
			sim.emit(t, Event_Expired{thing = handle})
			sim.despawn(&t.state.things, handle)
		}
	}
}
