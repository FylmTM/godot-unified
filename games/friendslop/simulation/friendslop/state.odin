package friendslop

import "unified:physics"
import "unified:sim"

// The whole simulation state: one pointer-free block (checked by sim.create). Items, platforms and triggers are
// indexed like the World's lists of them (the level's markers, in level order).
State :: struct {
	players:     sim.Players(Character, Input, PLAYERS),
	items:       [MAX_ITEMS]Item,
	platforms:   [MAX_PLATFORMS]Platform,
	bells:       [MAX_TRIGGERS]physics.Body_Ref, // a bell's static body, by trigger index (other triggers: none)
	triggers:    [MAX_TRIGGERS]Trigger,
	run_tick:    u32, // the tick the current run started
	finish_tick: u32, // the tick the trophy arrived (Finished)
	runs:        u32,
	best_ticks:  u32, // the best run (0: none)
	checkpoint:  i32, // the team's last checkpoint index (-1: the hub)
	phase:       Phase,
	_pad:        [3]u8,
}

Phase :: enum u8 {
	Hub, // free play; walking through the start gate starts a run
	Run, // the route, timed
	Finished, // the trophy is on the pedestal: show the time, then back to the hub
}

// What a player holds.
Held_Kind :: enum u8 {
	None,
	Item,
	Player,
}

// A player's data (sim.Players, by member): zeroed when someone new joins; a leave releases and destroys what it
// owns outside the block (the body, the hold) and zeroes it, so a returning player starts fresh too.
Character :: struct {
	controller:    physics.Character,
	hold:          physics.Motor_Joint_Ref, // the joint to what this player holds
	facing:        [2]f32, // unit (x, z)
	aim:           [3]f32, // unit look direction from the last input
	held_player:   sim.Player, // the player this one holds (held_kind .Player)
	held_by:       sim.Player, // the player holding this one ({}: free)
	stun:          u16, // ticks left limp (hit, thrown)
	charge:        u16, // ticks the throw button has been held while holding something
	held_ticks:    u16, // ticks this player has been held
	break_window:  u16, // ticks left to finish a break-free
	respawn:       u16, // ticks until a fallen player respawns (0: not fallen)
	pad_cooldown:  u16,
	held_kind:     Held_Kind,
	held_item:     u8, // the item index (held_kind .Item)
	grab_point:    u8, // which grab point of the held item
	thrown:        bool, // stunned by a throw or a drop: ends on landing
	break_presses: u8,
	_pad:          [3]u8,
}

Item :: struct {
	body:         physics.Body_Ref,
	holders:      [2]sim.Player, // the player holding each grab point ({}: free)
	thrown_by:    sim.Player, // the last thrower (while thrown_ticks > 0), whether still here or not
	thrown_ticks: u16,
	pad_cooldown: u16,
	alive:        bool,
	_pad:         [3]u8,
}

// A moving platform: its pose is a pure function of `phase` (physics.path_sample).
Platform :: struct {
	body:    physics.Body_Ref,
	phase:   u32, // ticks into the path
	running: bool,
	_pad:    [3]u8,
}

Trigger :: struct {
	active:   bool, // plates: pressed now; bells, switches and locks: fired (latched)
	_pad:     u8,
	cooldown: u16, // bells: no ring again before this runs out
}
