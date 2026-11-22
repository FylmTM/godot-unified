// horde's GDExtension (game/horde.gdextension -> .out/bin/libhorde.*): the horde sim run by unified:godot, plus the
// game's glue (examples/horde/README.md, View contract): 2D scene views for the few and MultiMesh views for the crowds
// (frame.odin), the HUD's session data (hud.odin, Unified.data.hud), the constants (this file, Unified.constants)
// and how the InputMap becomes an Input (input.odin). Built by `uni build horde`.
package horde_extension

import "base:runtime"
import "core:fmt"
import "unified:eos"
import "unified:godot"

import g "../horde"

@(export, link_name = "horde_init")
horde_init :: proc "c" (
	get_proc_address: godot.Get_Proc_Address,
	library: godot.Class_Library,
	initialization: ^godot.Initialization,
) -> godot.Init_Result {
	// online play: EOS lobbies and P2P
	return godot.init(&g.GAME, GLUE, get_proc_address, library, initialization, eos.lobby({}), constants = constants)
}

// The glue: positions on the arena's plane in Godot's 2D axes, drawn at UNIT_PX pixels per sim unit (the host maps
// view positions and event positions alike). Events reach views by the host's default routing: a hero's events its
// hero view; enemies and gems are MultiMesh instances, so their events reach the session's `sim_event` only.
GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame   = fill_frame,
	data         = Data,
	is_2d        = true,
	view_scale   = UNIT_PX,
}

// ---- the constants for the scripts (Unified.constants), from the sim's own definitions

// Sizes in sim units (the views draw them at Unified.view_scale) and the level-up cards.
Data_Constants :: struct {
	arena_half:       f32, // the arena's walls are this far from the centre each way
	hero_radius:      f32,
	enemy_radii:      [len(g.Enemy_Kind)]f32, // by Enemy_Kind
	enemy_quad_radii: f32, // ENEMY_QUAD_RADII: an enemy's quad reaches this many of its radii each way
	upgrades:         [len(g.Upgrade)]Upgrade_Card, // in g.Upgrade order: the HUD shows the three a level-up offers
}

// A level-up card: its Pick's `upgrade` (an EnumUpgrade value), name and detail.
Upgrade_Card :: struct {
	upgrade: g.Upgrade,
	name:    string,
	detail:  string,
}

// godot.init calls it once: the sizes and the cards, their details with the sim's numbers. The strings live as long
// as the process.
constants :: proc() -> Data_Constants {
	heap := runtime.heap_allocator()
	return {
		arena_half       = g.ARENA_HALF,
		hero_radius      = g.HERO_RADIUS,
		enemy_radii      = {g.ENEMY_STATS[.Grunt].radius, g.ENEMY_STATS[.Runner].radius, g.ENEMY_STATS[.Brute].radius},
		enemy_quad_radii = ENEMY_QUAD_RADII,
		upgrades         = {
			{upgrade = .Bolt_Count, name = "Bolts", detail = "One more bolt per volley"},
			{upgrade = .Bolt_Pierce, name = "Pierce", detail = "Bolts pierce one more enemy"},
			{
				upgrade = .Fire_Rate,
				name    = "Fire rate",
				detail  = fmt.aprintf(
					"Volleys %.2f s sooner",
					f32(g.BOLT_INTERVAL_LEVELUP_TICKS) / f32(g.TICK_HZ),
					allocator = heap,
				),
			},
			{upgrade = .Chains, name = "Chain", detail = "Lightning reaches one more enemy"},
			{
				upgrade = .Bomb_Radius,
				name    = "Blast",
				detail  = fmt.aprintf("Bomb blasts %.1f wider", g.BLAST_RADIUS_LEVELUP, allocator = heap),
			},
			{
				upgrade = .Move_Speed,
				name    = "Speed",
				detail  = fmt.aprintf("+%.1f move speed", g.HERO_SPEED_LEVELUP, allocator = heap),
			},
			{
				upgrade = .Max_Hp,
				name    = "Vigour",
				detail  = fmt.aprintf("+%d max HP, healed as much", g.HERO_HP_LEVELUP, allocator = heap),
			},
		},
	}
}
