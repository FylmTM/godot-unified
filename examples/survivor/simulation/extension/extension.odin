// The survivor's GDExtension (game/survivor.gdextension -> .out/bin/libsurvivor.*): the survivor sim run by
// unified:godot, plus the game's glue (examples/survivor/README.md, View contract): 3D scene and MultiMesh views in
// metres (frame.odin), the player view's data, the HUD's session data (hud.odin), the constants (this file), and how
// the InputMap becomes an Input (input.odin). Built by `uni build survivor`.
package survivor_extension

import "base:runtime"
import "core:fmt"
import "unified:eos"
import "unified:godot"

import g "../survivor"

@(export, link_name = "survivor_init")
survivor_init :: proc "c" (
	get_proc_address: godot.Get_Proc_Address,
	library: godot.Class_Library,
	initialization: ^godot.Initialization,
) -> godot.Init_Result {
	// online play: EOS lobbies and P2P
	return godot.init(&g.GAME, GLUE, get_proc_address, library, initialization, eos.lobby({}), constants = constants)
}

// ---- the view contract

// Scene views (the view index: a scene per kind, with a UnifiedView marker): players, crates and barrels (the
// player's data: Player_View).
View :: enum u8 {
	Player,
	Crate,
	Barrel,
}

// MultiMesh views (MultiMeshInstance3D, 3D transforms + custom data: r = hit flash 0..1, g = age in s, no
// colours): one per Enemy_Kind, in its order, then projectiles and gems. Positions are on the floor plane (y = 0):
// the shaders lift the meshes.
MultiView :: enum u8 {
	Grunt,
	Runner,
	Brute,
	Projectile,
	Gem,
}

#assert(int(MultiView.Grunt) == int(g.Enemy_Kind.Grunt))
#assert(int(MultiView.Runner) == int(g.Enemy_Kind.Runner))
#assert(int(MultiView.Brute) == int(g.Enemy_Kind.Brute))

Frame :: godot.Frame(g.Game, View, MultiView)

// The player view's data: set as its properties when it changes.
Player_View :: struct {
	hp:      i32,
	dashing: bool, // the dash's speed-up is on (the view's after-image trail)
	_pad:    [3]u8,
}

// Events reach views by the host's default routing: a player's events (`player`) its player view, a barrel's
// explosion (`entity`: sim.entity of the item's index) the barrel's view (keyed by that index); enemies and gems are
// MultiMesh instances, so their events (by handle) reach no view.
GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame = fill_frame,
	data = Data,
	view_data = #partial{.Player = Player_View},
}

// ---- constants for the scripts (Unified.constants, class UnifiedConstants), from the sim's own definitions

// What the scripts read: the start circle and blast sizes and the level-up cards.
Data_Constants :: struct {
	start_radius: f32,
	blast_radius: f32, // a barrel's explosion reaches this far (m): the effect's size
	upgrades:     [len(g.Upgrade)]Upgrade_Card, // in g.Upgrade order: the HUD's cards
}

// A level-up card: its Pick's `upgrade` (an EnumUpgrade value), name and detail.
Upgrade_Card :: struct {
	upgrade: g.Upgrade,
	name:    string,
	detail:  string,
}

// godot.init calls it once: the sizes and the cards (their details with the sim's numbers). Their strings live as
// long as the process.
constants :: proc() -> (constants: Data_Constants) {
	constants = {
		start_radius = g.START_RADIUS,
		blast_radius = g.BLAST_RADIUS,
		upgrades     = {
			{upgrade = .Fire_Rate, name = "Fire rate", detail = "Shoot more often"},
			{upgrade = .Damage, name = "Damage"},
			{upgrade = .Move_Speed, name = "Move speed"},
		},
	}
	constants.upgrades[g.Upgrade.Damage].detail = fmt.aprintf(
		"+%d damage per shot",
		g.DAMAGE_LEVELUP,
		allocator = runtime.heap_allocator(),
	)
	constants.upgrades[g.Upgrade.Move_Speed].detail = fmt.aprintf(
		"+%.1f m/s",
		g.SPEED_LEVELUP,
		allocator = runtime.heap_allocator(),
	)
	return
}
