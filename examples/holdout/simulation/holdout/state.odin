package holdout

import "unified:dmath"
import "unified:nav"
import "unified:physics"
import "unified:sim"

MAX_ENEMIES :: 64 // the table; at most ENEMY_CAP alive
MAX_BOLTS :: 32
MAX_GRENADES :: 8

// Where the run is (run.odin).
Phase :: enum u8 {
	Lobby, // players walk the yard; a Ready press starts the countdown
	Countdown, // START_DELAY_S to the first wave
	Wave, // a wave's bursts spawn; cleared when they all did and none is left
	Break, // WAVE_BREAK_S to the next wave
	Over, // won or lost: OVER_HOLD_S, then back to the lobby
}

// The whole simulation state: one pointer-free block (checked by sim.create). The physics world (every body's pose
// and velocity) rolls back beside it (physics.extra).
State :: struct {
	players:      sim.Players(Player_Data, sim.No_Profile, Input, PLAYERS),
	enemies:      sim.Table(Enemy, MAX_ENEMIES),
	bolts:        sim.Table(Bolt, MAX_BOLTS),
	grenades:     sim.Table(Grenade, MAX_GRENADES),
	level:        sim.Active_Level(Level_Id),
	core_hp:      i32,
	kills:        u32, // this run's
	phase:        Phase,
	wave:         u8, // the current or last wave, 1..WAVES (0: none yet)
	won:          bool, // Over: the last wave was cleared (else the core fell)
	_pad:         u8,
	phase_timer:  sim.Timer, // Countdown, Break, Over: until the next phase
	wave_started: sim.Game_Time,
	spawned:      [MAX_BURSTS]u8, // this wave's enemies spawned so far, by burst
	_pad2:        [2]u8,
}

// A player's data (the State's sim.Players): zeroed for someone new, kept while they are away.
Player_Data :: struct {
	controller:   physics.Character,
	aim:          dmath.Aim, // the last input's, for the views
	hp:           i16,
	revive_ticks: u16, // a teammate's progress getting them up (downed)
	downed:       bool,
	_pad:         [3]u8,
	fire_ready:   sim.Timer, // no shot until it runs out (FIRE_INTERVAL_TICKS)
	grenade:      sim.Timer, // no grenade until it runs out (GRENADE_COOLDOWN_S)
	respawn:      sim.Timer, // downed: up at the core when it runs out (RESPAWN_S)
	kills:        u16,
	warp:         u8, // bumped by every new body: the view snaps to it
	_pad2:        u8,
}

// An enemy: its kinematic body (a capsule and a head), its feet on the navigation mesh, and what it is doing.
Enemy :: struct {
	body:   physics.Body_Ref,
	pos:    [3]f32, // its feet, on the mesh
	facing: [2]f32, // unit, x and z
	poly:   nav.Poly, // the mesh polygon under its feet
	hp:     i16,
	kind:   Enemy_Kind,
	sees:   bool, // it saw its target player at its last look (SIGHT_EVERY_TICKS)
	target: sim.Player, // the player it goes for ({}: the core)
	attack: sim.Timer, // no attack until it runs out
}

// A spitter's bolt: a point flying straight, swept against the level, the core and the players each tick.
Bolt :: struct {
	pos:    [3]f32,
	vel:    [3]f32,
	life:   sim.Timer, // gone when it runs out
	damage: i16, // to what it strikes
	_pad:   [2]u8,
}

// A grenade in flight: a dynamic sphere that bounces until its fuse burns down or it touches an enemy.
Grenade :: struct {
	body:    physics.Body_Ref,
	fuse:    sim.Timer,
	thrower: sim.Player,
}
