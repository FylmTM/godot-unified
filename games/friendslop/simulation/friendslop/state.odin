package friendslop

import "unified:physics"
import "unified:sim"

// The whole simulation state: one pointer-free block (checked by sim.create). Items, platforms and triggers are
// indexed like the World's lists of them (the level's markers, in level order).
State :: struct {
	level:       sim.Active_Level(Level_Id), // the hub or the route (enter_level)
	players:     sim.Players(Character, sim.No_Profile, Input, PLAYERS),
	items:       [MAX_ITEMS]Item,
	platforms:   [MAX_PLATFORMS]Platform,
	triggers:    [MAX_TRIGGERS]Trigger,
	run_tick:    u32, // the tick the current run started
	finish_tick: u32, // the tick the trophy arrived (Finished)
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
	respawn:       sim.Timer, // fallen while it runs (RESPAWN_TICKS): parked far below, back when it fires
	pad_cooldown:  sim.Timer, // no pad launch while it runs (PAD_COOLDOWN_TICKS)
	held_kind:     Held_Kind,
	held_item:     u8, // the item index (held_kind .Item)
	grab_point:    u8, // which grab point of the held item
	thrown:        bool, // stunned by a throw or a drop: ends on landing
	break_presses: u8,
	_pad:          [3]u8,
}

Item :: struct {
	body:           physics.Body_Ref,
	holders:        [2]sim.Player, // the player holding each grab point ({}: free)
	thrown_by:      sim.Player, // the last thrower (while `thrown` runs), whether still here or not
	thrown:         sim.Timer, // "thrown by thrown_by" while it runs (THROWN_TAG_TICKS): hit attribution, catches
	pad_cooldown:   sim.Timer, // no pad launch while it runs (PAD_COOLDOWN_TICKS)
	// The thrower's body and this item's don't touch from the throw until the item is clear of them (release_throws).
	thrower_ignore: physics.Filter_Joint_Ref,
}

// A moving platform: its pose is a pure function of `phase` (physics.path_sample).
Platform :: struct {
	body:    physics.Body_Ref,
	phase:   u32, // ticks into the path
	running: bool,
	_pad:    [3]u8,
}

Trigger :: struct {
	body:     physics.Body_Ref, // its static body: a sensor box, a bell's sphere (create_trigger_body)
	sensor:   physics.Shape_Ref, // plates, switches, locks: the volume's sensor
	active:   bool, // plates: pressed now; bells, switches and locks: fired (latched)
	_pad:     [3]u8,
	cooldown: sim.Timer, // bells: no ring again while it runs (BELL_COOLDOWN_TICKS)
}
