// playground (examples/playground/README.md): a co-op physics playground of Box3D's sample scenes under rollback. Up
// to four players fly free cameras through the scenes and grab, shoot, spawn, blow up and drive what is in them.
//
// The files, by feature: game (this: the descriptor and the tick), tuning (every rule number), input, state, events,
// world (the physics world, the scenes' shared geometry, entering a scene), scenes (each scene's bodies and joints),
// props (the bodies the block owns), players (the cameras), tools (grab, shoot, spawn, explode), cars, rules (what
// each scene does every tick) and the scripted inputs (script).
package playground

import "unified:physics"
import "unified:sim"

PLAYERS :: 4 // input slots: the most players in the game at once
TICK_HZ :: 64

// The game's version (sim.Game.version, part of the netcode's compat): bump it when a rule or constant changes what a
// tick computes without changing the State or Input layout.
VERSION :: "1"

// The scenes, one level each, in GAME.levels' order (the State's `level` says which is active).
Scene :: enum u8 {
	Pyramid,
	Dominoes,
	Bridge,
	Driving,
	Ragdolls,
	Bounce_House,
	Bullets,
	Conveyor,
	Wind,
	Sensors,
	Breakable,
	Rain,
}

// The session's Setup: the scene it starts in (`--setup scene=rain`; every scene a benchmark row this way).
Setup :: struct {
	scene: Scene,
	_pad:  [3]u8,
}

Game :: sim.Game(State, Input, World, Event, Command, Setup, sim.No_Profile, PLAYERS)
Tick :: sim.Tick(Game)

@(rodata)
GAME := Game {
	name              = "playground",
	version           = VERSION,
	tick_hz           = TICK_HZ,
	// game/levels/<scene>.tscn's (uni bake)
	levels            = {
		{"pyramid", #load("../../game/levels/pyramid.level")},
		{"dominoes", #load("../../game/levels/dominoes.level")},
		{"bridge", #load("../../game/levels/bridge.level")},
		{"driving", #load("../../game/levels/driving.level")},
		{"ragdolls", #load("../../game/levels/ragdolls.level")},
		{"bounce_house", #load("../../game/levels/bounce_house.level")},
		{"bullets", #load("../../game/levels/bullets.level")},
		{"conveyor", #load("../../game/levels/conveyor.level")},
		{"wind", #load("../../game/levels/wind.level")},
		{"sensors", #load("../../game/levels/sensors.level")},
		{"breakable", #load("../../game/levels/breakable.level")},
		{"rain", #load("../../game/levels/rain.level")},
	},
	world_create      = world_create,
	world_destroy     = world_destroy,
	extra             = extra,
	init              = init,
	tick              = tick,
	scripted_input    = scripted_input,
	scripted_commands = scripted_commands,
	// A row per scene: the scripted players play it for 600 ticks (they change scenes every SCRIPT_SCENE_TICKS, later).
	benches           = {
		{name = "pyramid", what = "Pyramid: a box pyramid at the body budget", setup = "scene=pyramid", ticks = 600},
		{name = "dominoes", what = "Dominoes: a spiral of falling dominoes", setup = "scene=dominoes", ticks = 600},
		{
			name  = "bridge",
			what  = "Bridge: a revolute plank bridge, a ball and chain",
			setup = "scene=bridge",
			ticks = 600,
		},
		{
			name  = "driving",
			what  = "Driving: four cars on wheel joints on a height field",
			setup = "scene=driving",
			ticks = 600,
		},
		{
			name  = "ragdolls",
			what  = "Ragdolls: a pile of ragdolls on an incline",
			setup = "scene=ragdolls",
			ticks = 600,
		},
		{
			name  = "bounce_house",
			what  = "Bounce House: fast bodies in a closed room (CCD)",
			setup = "scene=bounce_house",
			ticks = 600,
		},
		{
			name  = "bullets",
			what  = "Bullets: a stack shot at by bullet bodies (CCD)",
			setup = "scene=bullets",
			ticks = 600,
		},
		{
			name  = "conveyor",
			what  = "Conveyor: crates on belts, rolling resistance",
			setup = "scene=conveyor",
			ticks = 600,
		},
		{name = "wind", what = "Wind: chains and bodies in a turning wind", setup = "scene=wind", ticks = 600},
		{name = "sensors", what = "Sensors: sensor volumes and hit events", setup = "scene=sensors", ticks = 600},
		{
			name  = "breakable",
			what  = "Breakable: welded walls and chains breaking on joint events",
			setup = "scene=breakable",
			ticks = 600,
		},
		{name = "rain", what = "Rain: bodies of every shape raining in, capped", setup = "scene=rain", ticks = 600},
	},
}

// One tick: the systems in their order (examples/playground/README.md, Systems).
tick :: proc(t: ^Tick) {
	update_presence(t)
	change_scene(t) // first: a scene change makes everything else this tick act on the new scene
	fly_cameras(t)
	use_tools(t)
	drive_cars(t)
	run_scene_rules(t)
	physics.step(t.world.phys)
	after_step(t)
	remove_fallen(t)
}

extra :: proc(world: ^World) -> sim.Extra {
	return physics.extra(world.phys, State)
}
