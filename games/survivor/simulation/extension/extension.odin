// The survivor's GDExtension (game/g.gdextension -> .out/bin/libsurvivor.*): the survivor sim run by
// unified:godot, plus the game's glue (games/survivor/SPEC.md "Client"): 3D scene and MultiMesh views in metres,
// the player view's data, the HUD's session data (hud.odin), the constants, and how the InputMap becomes an Input.
// Built by `uni build survivor`.
package survivor_extension

import "base:runtime"
import "core:fmt"
import "unified:dmath"
import "unified:eos"
import "unified:godot"
import "unified:physics"
import "unified:sim"

import g "../survivor"


@(export, link_name = "survivor_init")
survivor_init :: proc "c" (
	gpa: godot.Get_Proc_Address,
	lib: godot.Class_Library,
	init: ^godot.Initialization,
) -> godot.Init_Result {
	// online play: EOS lobbies and P2P
	return godot.init(&g.GAME, GLUE, gpa, lib, init, eos.lobby({}), constants = constants)
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
}

// Events reach views by the host's default routing: a player's events (`player`) its player view, a barrel's
// explosion (`entity`: sim.entity of the item's index) the barrel's view (keyed by that index); enemies and gems are
// MultiMesh instances, so their events (by handle) reach no view.
GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame   = fill_frame,
	data         = Data,
}

// ---- input (main thread, the one local player)

// Movement and the dash from the InputMap. The level-up pick is a command: the HUD sends it (a Pick).
sample_input :: proc(input: ^g.Input) {
	move := godot.action_vector("move_left", "move_right", "move_forward", "move_back") // +y = move_back = +Z
	input.move_x, input.move_z = dmath.axis_i8(move.x), dmath.axis_i8(move.y)
	// the sim dashes on the press (sim.buttons); a tap shorter than a frame still counts
	input.buttons = godot.buttons(g.Buttons, {.Dash = "dash"})
}

// ---- the frame (session thread)

// Keys (unique within a kind): a player's view is their sim.player_key (the view lives while they are present,
// dead too, whatever slot they hold), an item's its index (a destroyed barrel's view goes; the one respawned 10 s
// later is a new view).
fill_frame :: proc(f: ^Frame) {
	players := sim.iterate_present(&f.state.players)
	for character, player in sim.next(&players) {
		godot.push_view(f, {
			kind   = .Player,
			player = player,
			pos    = sim.Position(character.pos),
		}, Player_View{hp = max(character.hp, 0), dashing = character.dash_ticks > 0})
	}
	for i in 0 ..< g.ITEM_COUNT {
		item := &f.state.items[i]
		if !item.alive do continue
		godot.push_view(f, {
			key  = u64(i),
			kind = item.kind == .Barrel ? .Barrel : .Crate,
			pos  = sim.Position(physics.body_position(f.world.phys, item.body)),
			rot  = physics.body_rotation(f.world.phys, item.body),
		})
	}
	enemies := sim.iterate(&f.state.enemies)
	for enemy, handle in sim.next(&enemies) {
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = MultiView(enemy.kind),
			pos    = {enemy.pos.x, 0, enemy.pos.y},
			rot    = facing(enemy.vel),
			custom = {hit_flash(f.tick, enemy.hit_tick), age_s(f.tick, enemy.spawn_tick), 0, 0},
		})
	}
	projectiles := sim.iterate(&f.state.projectiles)
	for projectile, handle in sim.next(&projectiles) {
		godot.push_multi_view(f, {
			key  = sim.handle_key(handle),
			kind = .Projectile,
			pos  = {projectile.pos.x, 0, projectile.pos.z},
			rot  = facing(projectile.vel.xz),
		})
	}
	gems := sim.iterate(&f.state.gems)
	for gem, handle in sim.next(&gems) {
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = .Gem,
			pos    = {gem.pos.x, 0, gem.pos.y},
			custom = {0, age_s(f.tick, gem.spawn_tick), 0, 0},
		})
	}
	godot.push_data(f, hud_of(f.state, f.tick))
}

HIT_FLASH_S :: 0.15

// The rotation about +Y that turns +Z towards `dir` (x, z on the floor, any length; zero: the identity).
facing :: proc(dir: [2]f32) -> [4]f32 {
	unit := dmath.normalize(dir, 0)
	return unit == {} ? {} : dmath.quat_yaw(unit)
}

// MultiMesh custom data (the game's shaders): r = hit flash 1 -> 0 over HIT_FLASH_S, g = age in seconds.
hit_flash :: proc(tick, hit_tick: u32) -> f32 {
	if hit_tick == 0 || tick < hit_tick do return 0
	return max(0, 1 - sim.seconds(tick - hit_tick, g.TICK_HZ) / HIT_FLASH_S)
}

age_s :: proc(tick, spawn_tick: u32) -> f32 {
	return tick > spawn_tick ? sim.seconds(tick - spawn_tick, g.TICK_HZ) : 0
}

// ---- constants for the scripts (Unified.constants, class UnifiedConstants), from the sim's own definitions

// What the scripts read: the "over" hold, the start circle and blast sizes, the level-up cards and the item grid.
Data_Constants :: struct {
	over_hold_s:  f32,
	start_radius: f32,
	blast_radius: f32, // a barrel's explosion reaches this far (m): the effect's size
	upgrades:     [len(g.Upgrade)]Upgrade_Card, // in g.Upgrade order: the HUD's cards
	items:        [g.ITEM_COUNT]Item_Spot, // the item grid at rest (the menu backdrop shows it)
}

// A level-up card: its Pick's `upgrade` (an EnumUpgrade value), name and detail.
Upgrade_Card :: struct {
	upgrade: g.Upgrade,
	name:    string,
	detail:  string,
}

Item_Spot :: struct {
	position: [3]f32, // the body's centre resting on the floor at its grid spot (it spawns higher and drops)
	kind:     g.Item_Kind, // an EnumItemKind value
}

// godot.init calls it once: the sizes, the cards (their details with the sim's numbers) and the item grid. Their
// strings live as long as the process.
constants :: proc() -> (constants: Data_Constants) {
	constants = {
		over_hold_s  = g.OVER_HOLD_S,
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
	for &spot, i in constants.items {
		spot.kind = g.item_kind(i)
		spot.position = g.item_position(i)
		spot.position.y = spot.kind == .Barrel ? g.BARREL_RADIUS + g.BARREL_HALF_HEIGHT : g.CRATE_HALF
	}
	return
}
