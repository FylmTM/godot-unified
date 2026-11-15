// The survivor's GDExtension (game/survivor.gdextension -> .out/bin/libsurvivor.*): the survivor sim run by
// unified:godot, plus the game's glue (games/survivor/SPEC.md "Client"): 3D scene and MultiMesh views in metres,
// the player view's data, the HUD view (hud.odin), constants, and how the InputMap becomes an Input. Built by
// `uni build survivor`.
package survivor_extension

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "unified:b3"
import "unified:eos"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:godot"
import "unified:netcode"
import "unified:physics"
import "unified:sim"
import "unified:view"

import "../survivor"


@(export, link_name = "survivor_init")
survivor_init :: proc "c" (
	gpa: gdi.InterfaceGetProcAddress,
	lib: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	godot.install(&survivor.GAME, GLUE)
	godot.set_transport(&EOS_TRANSPORT)
	return godot.entry(gpa, lib, init)
}

// ---- online play: EOS (lobby codes, P2P with Epic relays), through unified:godot's transport interface

// Game + net protocol version: lobby search only finds lobbies of the same bucket, so a build with another
// protocol says "no game with that code" instead of failing to connect.
SURVIVOR_BUCKET :: "survivor/7"
#assert(netcode.PROTOCOL_VERSION == 9, "netcode protocol changed: bump SURVIVOR_BUCKET with it")

@(private)
eos_init :: proc(events: ^godot.Transport_Events) -> bool {
	if eos.init({product_name = "survivor", product_version = godot.app_version}) do return true
	events.fail(events.ctx, eos.status().detail)
	return false
}

EOS_TRANSPORT := godot.Transport {
	name = "EOS",
	open_host = proc(_: rawptr, events: ^godot.Transport_Events) -> (netcode.Link, bool) {
		if !eos_init(events) do return {}, false
		link, ok := eos.open_host(SURVIVOR_BUCKET)
		if !ok do events.fail(events.ctx, eos.status().detail)
		return link, ok
	},
	open_join = proc(_: rawptr, code: string, events: ^godot.Transport_Events) -> (netcode.Link, bool) {
		if !eos_init(events) do return {}, false
		link, ok := eos.open_join(SURVIVOR_BUCKET, code)
		if !ok do events.fail(events.ctx, eos.status().detail)
		return link, ok
	},
	pump = proc(_: rawptr, events: ^godot.Transport_Events) {
		result := eos.pump()
		if result.code != "" do events.code(events.ctx, result.code)
		if result.failed != "" do events.fail(events.ctx, result.failed)
	},
	close = proc(_: rawptr) {eos.close()},
	// EOS's HTTP completes through the macOS main run loop, which headless Godot doesn't pump.
	main_frame = proc(_: rawptr) {eos.pump_main_run_loop()},
	// EOS left initialized at exit crashed in its own threads during process teardown (macOS, ~1 in 2 exits).
	shutdown = proc(_: rawptr) {eos.shutdown()},
}

// ---- the view contract

// Scene views (the view index: a scene per kind, with a UnifiedView marker): players, crates and barrels (the
// player's data: Player_View), and the HUD (game/views/hud.tscn; its data, Hud, is Game.hud).
View :: enum u8 {
	Player,
	Crate,
	Barrel,
	Hud,
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

Frame :: godot.Frame(survivor.State, survivor.World, View, MultiView)

// Spawn keys: players 1..4 (a player's view lives for the whole session), items 0x100 + index (a destroyed
// barrel's view goes; the one respawned 10 s later is a new view), the HUD 0x200.
PLAYER_KEY :: 1
ITEM_KEY :: 0x100
HUD_KEY :: 0x200

// The player view's data: set as its properties when it changes.
Player_View :: struct {
	hp: i32,
}

// Events reach views by the host's default routing: a player's events (`player`) its player view, a barrel's
// explosion (`entity` = item index + 1) the barrel's view (View_Item.entity); enemies and gems are MultiMesh
// instances, so their events (by handle) reach no view.
GLUE := godot.Glue(survivor.State, survivor.Input, survivor.World, View, MultiView) {
	sample_input      = sample_input,
	fill_frame        = fill_frame,
	scripted_input    = survivor.scripted_input,
	scripted_commands = survivor.scripted_commands,
	constants         = constants,
	bench             = survivor.bench_prepare,
}

// ---- input (main thread, the one local player)

// Movement and the dash from the InputMap. The level-up pick is a command: the HUD sends it (a Pick).
sample_input :: proc(input: ^survivor.Input) {
	move := godot.action_vector("move_left", "move_right", "move_forward", "move_back") // +y = move_back = +Z
	input.move_x, input.move_z = godot.axis_i8(move.x), godot.axis_i8(move.y)
	// the sim dashes on the press edge; a tap shorter than a tick still counts (action_pressed)
	if godot.action_held("dash") || godot.action_pressed("dash") do input.buttons |= survivor.BUTTON_DASH
}

// ---- the frame (session thread)

fill_frame :: proc(frame: ^Frame) {
	state, world, tick := frame.state, frame.world, frame.tick
	for player in 0 ..< survivor.PLAYERS {
		character := &state.players[player]
		if !character.active do continue
		godot.push_view(
			frame,
			{key = view.Key(PLAYER_KEY + player), kind = .Player, player = player, pos = character.pos},
			Player_View{hp = max(character.hp, 0)},
		)
	}
	for i in 0 ..< survivor.ITEM_COUNT {
		item := &state.items[i]
		if !item.alive do continue
		body := physics.body_id(world.phys, item.body)
		body_pos := b3.body_get_position(body)
		godot.push_view(
			frame,
			{
				key    = view.Key(ITEM_KEY + i),
				kind   = item.kind == .Barrel ? .Barrel : .Crate,
				entity = u64(i + 1), // barrel_exploded's entity: item index + 1
				pos    = {body_pos.x, body_pos.y, body_pos.z},
				rot    = b3.body_get_rotation(body),
			},
		)
	}
	enemies := sim.iterate(&state.enemies)
	for enemy, handle in sim.next(&enemies) {
		godot.push_multi(
			frame,
			{
				key = sim.handle_key(handle),
				kind = MultiView(enemy.kind),
				pos = {enemy.pos.x, 0, enemy.pos.y},
				yaw = enemy_yaw(enemy.vel),
				custom = {hit_flash(tick, enemy.hit_tick), age_s(tick, enemy.spawn_tick), 0, 0},
			},
		) or_break
	}
	projectiles := sim.iterate(&state.projectiles)
	for projectile, handle in sim.next(&projectiles) {
		godot.push_multi(
			frame,
			{
				key = sim.handle_key(handle),
				kind = .Projectile,
				pos = {projectile.pos.x, 0, projectile.pos.z},
				yaw = math.atan2(projectile.vel.x, projectile.vel.z),
			},
		) or_break
	}
	gems := sim.iterate(&state.gems)
	for gem, handle in sim.next(&gems) {
		godot.push_multi(
			frame,
			{
				key = sim.handle_key(handle),
				kind = .Gem,
				pos = {gem.pos.x, 0, gem.pos.y},
				custom = {0, age_s(tick, gem.spawn_tick), 0, 0},
			},
		) or_break
	}
	godot.push_view(frame, {key = HUD_KEY, kind = .Hud}, hud_of(state, tick))
}

HIT_FLASH_S :: 0.15

enemy_yaw :: proc(vel: [2]f32) -> f32 {
	return (vel.x != 0 || vel.y != 0) ? math.atan2(vel.x, vel.y) : 0
}

// MultiMesh custom data (the game's shaders): r = hit flash 1 -> 0 over HIT_FLASH_S, g = age in seconds.
hit_flash :: proc(tick, hit_tick: u32) -> f32 {
	if hit_tick == 0 || tick < hit_tick do return 0
	return max(0, 1 - f32(tick - hit_tick) * survivor.DT / HIT_FLASH_S)
}

age_s :: proc(tick, spawn_tick: u32) -> f32 {
	return tick > spawn_tick ? f32(tick - spawn_tick) * survivor.DT : 0
}

// ---- constants for the scripts (UnifiedSession.constants()), from the sim's own definitions

UPGRADE_NAMES := [survivor.Upgrade]string {
	.Fire_Rate  = "Fire rate",
	.Damage     = "Damage",
	.Move_Speed = "Move speed",
}

constants :: proc(dict: ^gd.Dictionary) {
	gd.dict_set(dict, "over_hold_s", f64(survivor.OVER_HOLD_S))
	gd.dict_set(dict, "arena_half", f64(survivor.ARENA_HALF))
	gd.dict_set(dict, "start_radius", f64(survivor.START_RADIUS))
	gd.dict_set(dict, "dash_cooldown_s", f64(survivor.DASH_COOLDOWN_S))
	gd.dict_set(dict, "player_respawn_s", f64(survivor.PLAYER_RESPAWN_S))
	gd.dict_set(dict, "max_enemies", i64(survivor.MAX_ENEMIES))
	// the level-up cards in survivor.Upgrade order: the HUD's card sends a Pick with `upgrade` = its id
	upgrades := gd.array_new()
	details := [survivor.Upgrade]string {
		.Fire_Rate  = "Shoot more often",
		.Damage     = fmt.tprintf("+%d damage per shot", survivor.DAMAGE_LEVELUP),
		.Move_Speed = fmt.tprintf("+%.1f m/s", survivor.SPEED_LEVELUP),
	}
	for name, upgrade in UPGRADE_NAMES {
		entry := gd.dict_new()
		gd.dict_set(&entry, "id", strings.to_lower(fmt.tprint(upgrade), context.temp_allocator)) // fire_rate, ...
		gd.dict_set(&entry, "name", name)
		gd.dict_set(&entry, "detail", details[upgrade])
		gd.array_push_move(&upgrades, &entry)
	}
	gd.dict_set_move(dict, "upgrades", &upgrades)
	// the item grid as the match starts (crates and barrels; the menu backdrop shows it)
	items := gd.array_new()
	for i in 0 ..< survivor.ITEM_COUNT {
		spot := survivor.item_position(i)
		item := gd.dict_new()
		gd.dict_set(&item, "position", gd.Vector3{spot.x, spot.y, spot.z})
		gd.dict_set(&item, "kind", survivor.item_kind(i) == .Barrel ? "barrel" : "crate")
		gd.array_push_move(&items, &item)
	}
	gd.dict_set_move(dict, "items", &items)
}
