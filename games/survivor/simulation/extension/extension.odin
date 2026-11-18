// The survivor's GDExtension (game/survivor.gdextension -> .out/bin/libsurvivor.*): the survivor sim run by
// unified:godot, plus the game's glue (games/survivor/SPEC.md "Client"): 3D scene and MultiMesh views in metres,
// the player view's data, the HUD's session data (hud.odin), the constants, and how the InputMap becomes an Input.
// Built by `uni build survivor`.
package survivor_extension

import "base:runtime"
import "core:fmt"
import "core:math"
import "unified:dmath"
import "unified:eos"
import "unified:gdext/gdi"
import "unified:godot"
import "unified:physics"
import "unified:sim"

import "../survivor"


@(export, link_name = "survivor_init")
survivor_init :: proc "c" (
	gpa: gdi.InterfaceGetProcAddress,
	lib: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	constants_fill(&CONSTANTS)
	return godot.init(&survivor.GAME, GLUE, gpa, lib, init, eos.lobby({})) // online play: EOS lobbies and P2P
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

#assert(int(MultiView.Grunt) == int(survivor.Enemy_Kind.Grunt))
#assert(int(MultiView.Runner) == int(survivor.Enemy_Kind.Runner))
#assert(int(MultiView.Brute) == int(survivor.Enemy_Kind.Brute))

Frame :: godot.Frame(survivor.Game, View, MultiView)

// The player view's data: set as its properties when it changes.
Player_View :: struct {
	hp: i32,
}

// Events reach views by the host's default routing: a player's events (`player`) its player view, a barrel's
// explosion (`entity` = item index + 1) the barrel's view (View_Item.entity); enemies and gems are MultiMesh
// instances, so their events (by handle) reach no view.
GLUE := godot.Glue(survivor.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame   = fill_frame,
	data         = Data,
	constants    = CONSTANTS,
	bench        = survivor.bench_prepare,
}

// ---- input (main thread, the one local player)

// Movement and the dash from the InputMap. The level-up pick is a command: the HUD sends it (a Pick).
sample_input :: proc(input: ^survivor.Input) {
	move := godot.action_vector("move_left", "move_right", "move_forward", "move_back") // +y = move_back = +Z
	input.move_x, input.move_z = dmath.axis_i8(move.x), dmath.axis_i8(move.y)
	// the sim dashes on the press (sim.buttons); a tap shorter than a frame still counts
	input.buttons = godot.buttons(survivor.Buttons, {.Dash = "dash"})
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
			pos    = character.pos,
		}, Player_View{hp = max(character.hp, 0)})
	}
	for i in 0 ..< survivor.ITEM_COUNT {
		item := &f.state.items[i]
		if !item.alive do continue
		body_pos := physics.body_position(f.world.phys, item.body)
		godot.push_view(
			f,
			{
				key    = u64(i),
				kind   = item.kind == .Barrel ? .Barrel : .Crate,
				entity = u64(i + 1), // barrel_exploded's entity: item index + 1 (an entity of 0 routes nowhere)
				pos    = {body_pos.x, body_pos.y, body_pos.z},
				rot    = physics.body_rotation(f.world.phys, item.body),
			},
		)
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

// The rotation about +Y that turns +Z towards `dir` (x, z on the floor; zero: the identity): the half-way
// quaternion (0, sin, 0, 1 + cos) normalized, no trigonometry.
facing :: proc(dir: [2]f32) -> [4]f32 {
	length := math.sqrt(dir.x * dir.x + dir.y * dir.y)
	if length == 0 do return {}
	cos_yaw, sin_yaw := dir.y / length, dir.x / length
	if cos_yaw < -0.9999 do return {0, 1, 0, 0} // straight back: half a turn
	return godot.qnormalize({0, sin_yaw, 0, 1 + cos_yaw})
}

// MultiMesh custom data (the game's shaders): r = hit flash 1 -> 0 over HIT_FLASH_S, g = age in seconds.
hit_flash :: proc(tick, hit_tick: u32) -> f32 {
	if hit_tick == 0 || tick < hit_tick do return 0
	return max(0, 1 - sim.seconds(tick - hit_tick, survivor.TICK_HZ) / HIT_FLASH_S)
}

age_s :: proc(tick, spawn_tick: u32) -> f32 {
	return tick > spawn_tick ? sim.seconds(tick - spawn_tick, survivor.TICK_HZ) : 0
}

// ---- constants for the scripts (Unified.constants, class UnifiedConstants), from the sim's own definitions

// What the scripts read: the "over" hold, the arena and start circle sizes, the level-up cards and the item grid.
Data_Constants :: struct {
	over_hold_s:  f32,
	arena_half:   f32,
	start_radius: f32,
	upgrades:     [len(survivor.Upgrade)]Upgrade_Card, // in survivor.Upgrade order: the HUD's cards
	items:        [survivor.ITEM_COUNT]Item_Spot, // the item grid as the match starts (the menu backdrop shows it)
}

// A level-up card: its Pick's `upgrade` (an EnumUpgrade value), name and detail.
Upgrade_Card :: struct {
	upgrade: survivor.Upgrade,
	name:    string,
	detail:  string,
}

Item_Spot :: struct {
	position: [3]f32, // the body's centre at spawn
	kind:     survivor.Item_Kind, // an EnumItemKind value
}

CONSTANTS := Data_Constants {
	over_hold_s  = survivor.OVER_HOLD_S,
	arena_half   = survivor.ARENA_HALF,
	start_radius = survivor.START_RADIUS,
	upgrades     = {
		{upgrade = .Fire_Rate, name = "Fire rate", detail = "Shoot more often"},
		{upgrade = .Damage, name = "Damage"},
		{upgrade = .Move_Speed, name = "Move speed"},
	},
}

// The constants computed from the sim (the item grid, the details with its numbers), before install copies them.
// Their strings live as long as the process.
constants_fill :: proc(constants: ^Data_Constants) {
	constants.upgrades[survivor.Upgrade.Damage].detail = fmt.aprintf(
		"+%d damage per shot",
		survivor.DAMAGE_LEVELUP,
		allocator = runtime.heap_allocator(),
	)
	constants.upgrades[survivor.Upgrade.Move_Speed].detail = fmt.aprintf(
		"+%.1f m/s",
		survivor.SPEED_LEVELUP,
		allocator = runtime.heap_allocator(),
	)
	for &spot, i in constants.items {
		spot = {survivor.item_position(i), survivor.item_kind(i)}
	}
}
